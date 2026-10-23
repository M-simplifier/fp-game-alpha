module Colony.Transport.Dispatch where

import Colony.Inventory
import Colony.Topology
import Colony.Transport.State
import Colony.Types
import Colony.Units
import Control.Monad (foldM, forM_, when)
import Control.Monad.State.Strict (get, gets, modify', put, runStateT)
import Data.List (groupBy, sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)

planDelivery :: SimTick -> Owner -> Owner -> Resource -> Integer -> Integer -> TransportState -> InventoryTx (EntityId, TransportState)
planDelivery tick src dst resource quantity priority state = do
  require (src /= dst && quantity > 0 && priority >= 0 && priority <= 3) InvalidQuantity
  require (length (filter ((== RequestOpen) . requestStatus) (M.elems (transportRequests state))) < 8192) TransportRequestFull
  source <- port src state
  destination <- port dst state
  ident <- freshId
  reserveDelivery tick ident src dst resource quantity
  queue <- either throwTx pure (requestPath (transportTopology state) ident source destination priority tick (transportPaths state))
  let request = DeliveryRequest ident src dst resource quantity quantity [] RequestOpen priority tick (Just Searching) PathSearching (topologyRevision (transportTopology state))
  pure (ident, state {transportRequests = M.insert ident request (transportRequests state), transportPaths = queue})

-- Move reservation ownership; a split never reserves the physical stock twice.
transferQuantityClaim :: EntityId -> EntityId -> Integer -> InventoryTx ()
transferQuantityClaim parent child quantity = do
  inventory <- get
  let reservations =
        sortOn
          (\r -> (maybe (True, Nothing, SimTick 0, quantityLot r) fefo (M.lookup (quantityLot r) (invLots inventory)), quantityReservationId r))
          [r | r <- M.elems (invQuantity inventory), quantityJob r == parent]
  require (sum (map (qtyValue . quantityAmount) reservations) >= quantity) MissingReservation
  go quantity reservations
  where
    go 0 _ = pure ()
    go _ [] = throwTx MissingReservation
    go remaining (reservation : rest) = do
      let takeQty = min remaining (qtyValue (quantityAmount reservation))
      if takeQty == qtyValue (quantityAmount reservation)
        then modify' $ \s -> s {invQuantity = M.adjust (\r -> r {quantityJob = child}) (quantityReservationId reservation) (invQuantity s)}
        else do
          kept <- checked (qtyValue (quantityAmount reservation) - takeQty)
          moved <- checked takeQty
          ident <- freshId
          modify' $ \s ->
            s
              { invQuantity =
                  M.insert
                    ident
                    (QuantityReservation ident child (quantityLot reservation) moved)
                    (M.adjust (\r -> r {quantityAmount = kept}) (quantityReservationId reservation) (invQuantity s))
              }
      go (remaining - takeQty) rest

transferCapacityClaim :: EntityId -> EntityId -> Owner -> Integer -> InventoryTx ()
transferCapacityClaim parent child owner weight = do
  inventory <- get
  let reservations = [r | r <- M.elems (invCapacity inventory), capacityJob r == parent, capacityOwner r == owner]
  require (sum (map capacityWeight reservations) >= weight) MissingReservation
  go weight reservations
  where
    go 0 _ = pure ()
    go _ [] = throwTx MissingReservation
    go remaining (reservation : rest) = do
      let takeWeight = min remaining (capacityWeight reservation)
      if takeWeight == capacityWeight reservation
        then modify' $ \s -> s {invCapacity = M.adjust (\r -> r {capacityJob = child}) (capacityReservationId reservation) (invCapacity s)}
        else do
          ident <- freshId
          modify' $ \s ->
            s
              { invCapacity =
                  M.insert
                    ident
                    (CapacityReservation ident child owner takeWeight)
                    (M.adjust (\r -> r {capacityWeight = capacityWeight r - takeWeight}) (capacityReservationId reservation) (invCapacity s))
              }
      go (remaining - takeWeight) rest

-- Source-to-vehicle transfer preserves per-lot age, expiry and provenance.
-- Cargo claims in the vehicle also keep delivery fuel separate from engine fuel.
loadShipment :: SimTick -> Shipment -> TransportState -> InventoryTx (Shipment, TransportState)
loadShipment tick shipment state = do
  require (shipmentStatus shipment == ShipmentReserved) (InvalidReference "Shipment already loaded")
  vehicle <- lookupVehicle (shipmentVehicle shipment) state
  sourceNode <- port (shipmentSource shipment) state
  require (vehiclePosition vehicle == AtRoadNode sourceNode) (InvalidReference "Vehicle is not physically at source")
  inventory <- get
  let claims = [r | r <- M.elems (invQuantity inventory), quantityJob r == shipmentId shipment]
      sourceLots = [lot | r <- claims, Just lot <- [M.lookup (quantityLot r) (invLots inventory)]]
  require (sum (map (qtyValue . quantityAmount) claims) == shipmentQuantity shipment) MissingReservation
  require (all (\lot -> lotOwner lot == shipmentSource shipment && usable tick lot) sourceLots) ExpiredInput
  before <- gets (M.keysSet . invLots)
  moveReserved (shipmentId shipment) (shipmentSource shipment) (vehicleOwner vehicle)
  moved <- gets (filter (\lot -> not (S.member (lotId lot) before) && lotOwner lot == vehicleOwner vehicle) . M.elems . invLots)
  forM_ moved $ \lot -> do
    ident <- freshId
    modify' $ \s -> s {invQuantity = M.insert ident (QuantityReservation ident (shipmentId shipment) (lotId lot) (lotQty lot)) (invQuantity s)}
  let loaded = shipment {shipmentStatus = ShipmentCarrying, shipmentLots = map lotId moved, shipmentBlock = Nothing}
  pure (loaded, state {transportShipments = M.insert (shipmentId loaded) loaded (transportShipments state)})

-- Execute a recoverable job transaction against a private inventory snapshot.
-- Expected shortages keep a typed wait state, never half of a load or unload.
tryInventory :: InventoryTx a -> InventoryTx (Either Failure a)
tryInventory action = do
  before <- get
  case runStateT action before of
    Left err -> case err of
      InvariantViolation _ -> throwTx err
      CounterOverflow -> throwTx err
      _ -> pure (Left err)
    Right (result, after) -> put after >> pure (Right result)

phaseTransportPaths :: SimTick -> TransportState -> Either Failure TransportState
phaseTransportPaths tick state = do
  -- Completed parent searches leave the bounded work queue. Their immutable
  -- route is retained by the request while split shipments still need it.
  -- Otherwise4096 partially-filled parents could block every return-home path.
  prepared <- foldM prepare (transportPaths state) pending
  queue <- advancePaths tick topology prepared
  let completed = [search | search <- M.elems (pathSearches queue), M.member (pathId search) (transportRequests state), pathResult search /= PathSearching]
      applied = foldl apply (transportRequests state) completed
  pure state {transportPaths = foldr (dropPath . pathId) queue completed, transportRequests = applied}
  where
    topology = transportTopology state
    pending =
      sortOn
        (\r -> (effectiveRequest tick r, requestReadySince r, requestId r))
        [ r
        | r <- M.elems (transportRequests state),
          requestStatus r == RequestOpen,
          requestRemaining r > 0,
          requestRouteRevision r /= topologyRevision topology || requestPathResult r == PathSearching
        ]
    prepare queue request
      | M.member (requestId request) (pathSearches queue) = Right queue
      | otherwise = case (M.lookup (requestSource request) (transportPorts state), M.lookup (requestDestination request) (transportPorts state)) of
          (Just src, Just dst) -> case requestPath topology (requestId request) src dst (requestPriority request) (requestReadySince request) queue of
            Left PathQueueFull -> Right queue
            otherResult -> otherResult
          _ -> Right queue
    apply requests search = M.adjust (\r -> r {requestPathResult = pathResult search, requestRouteRevision = pathRevision search, requestBlock = case pathResult search of PathFound {} -> Nothing; PathUnavailable -> Just NoRoute; PathSearching -> Just Searching}) (pathId search) requests

phaseTransportAssign :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportAssign = phaseTransportAssignBudget 256

phaseTransportAssignBudget :: Word64 -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportAssignBudget = phaseTransportAssignWithPickups M.empty

phaseTransportAssignWithPickups :: M.Map EntityId EntityId -> Word64 -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportAssignWithPickups pickups budget tick original = do
  require (budget <= 256) InvalidQuantity
  foldM assign reset candidates
  where
    reset = original {transportLastAssignments = 0, transportLastMatches = 0}
    ordered = sortOn (\r -> (effectiveRequest tick r, requestReadySince r, requestId r)) [r | r <- M.elems (transportRequests original), requestStatus r == RequestOpen, requestRemaining r > 0]
    rotate peers = case transportAssignCursor original of
      Nothing -> peers
      Just ident -> case break ((== ident) . requestId) peers of (_, []) -> peers; (before, current : after) -> after ++ before ++ [current]
    rotated = concatMap rotate (groupBy (\a b -> effectiveRequest tick a == effectiveRequest tick b) ordered)
    candidates = take (fromIntegral budget) rotated
    assign state request = do
      let counted = state {transportLastAssignments = transportLastAssignments state + 1, transportAssignCursor = Just (requestId request)}
      if requestRouteRevision request /= topologyRevision (transportTopology state)
        then pure (setRequestBlock (requestId request) Searching counted)
        else case requestPathResult request of
          PathFound route _ -> assignReadyWithPickups pickups tick request route counted
          PathUnavailable -> pure (setRequestBlock (requestId request) NoRoute counted)
          PathSearching -> pure (setRequestBlock (requestId request) Searching counted)

effectiveRequest :: SimTick -> DeliveryRequest -> Integer
effectiveRequest (SimTick now) request = let SimTick ready = requestReadySince request in max 0 (requestPriority request - max 0 (toInteger now - toInteger ready) `div` 1200)

setRequestBlock :: EntityId -> TransportBlock -> TransportState -> TransportState
setRequestBlock ident block state = state {transportRequests = M.adjust (\r -> r {requestBlock = Just block}) ident (transportRequests state)}

assignReady :: SimTick -> DeliveryRequest -> [RoadNode] -> TransportState -> InventoryTx TransportState
assignReady = assignReadyWithPickups M.empty

assignReadyWithPickups :: M.Map EntityId EntityId -> SimTick -> DeliveryRequest -> [RoadNode] -> TransportState -> InventoryTx TransportState
assignReadyWithPickups pickups = assignReadyWithFuelPolicy False pickups M.empty

-- Only the new schema4 dispatcher treats an away-from-garage refill as a
-- temporary unsuitable vehicle. Old profiles retain their exact historical path.
assignReadyWithFuelPolicy :: Bool -> M.Map EntityId EntityId -> M.Map EntityId Integer -> SimTick -> DeliveryRequest -> [RoadNode] -> TransportState -> InventoryTx TransportState
assignReadyWithFuelPolicy waitForPhysicalRefuel pickups homeReturnBounds tick request route state = do
  sourceNode <- port (requestSource request) state
  inventory <- get
  let colony = storageColony <$> M.lookup (requestSource request) (invStorage inventory)
      eligible = filter (eligibleAtSource sourceNode colony) (M.elems (transportVehicles state))
      ordered = case M.lookup (requestId request) (transportMatchCursors state) of
        Nothing -> eligible
        Just cursor -> let (after, before) = span ((<= cursor) . vehicleId) eligible in before ++ after
      budget = min 32 (512 - transportLastMatches state)
  tryVehicles budget ordered Nothing state
  where
    eligibleAtSource sourceNode colony vehicle =
      vehicleJob vehicle == Nothing
        && vehiclePosition vehicle == AtRoadNode sourceNode
        && Just (vehicleColony vehicle) == colony
        && vehicleHasDriver vehicle
        && pickupMatches vehicle
    pickupMatches vehicle = case M.lookup (vehicleId vehicle) pickups of
      Just target -> target == requestId request
      Nothing -> requestId request `notElem` M.elems pickups

    -- Failed attempts roll back inventory (including IDs/fuel/claims), but still
    -- spend a matching attempt and advance the fairness cursor in TransportState.
    tryVehicles _ [] problem current = pure (setRequestBlock (requestId request) (maybe WaitingVehicle id problem) current)
    tryVehicles 0 _ problem current = pure (setRequestBlock (requestId request) (maybe WaitingVehicle id problem) current)
    tryVehicles remaining (vehicle : rest) problem current = do
      let counted = current {transportLastMatches = transportLastMatches current + 1, transportMatchCursors = M.insert (requestId request) (vehicleId vehicle) (transportMatchCursors current)}
      outcome <- tryInventory (makeChild vehicle)
      case outcome of
        Right next -> pure next {transportLastMatches = transportLastMatches counted, transportMatchCursors = M.delete (requestId request) (transportMatchCursors counted)}
        Left MissingStock -> tryVehicles (remaining - 1) rest (Just WaitingFuel) counted
        Left NoCapacity -> tryVehicles (remaining - 1) rest problem counted
        Left err -> throwTx err
    makeChild vehicle = do
      inventory <- get
      let owner = vehicleOwner vehicle
          routeEdges = toInteger (length route) - 1
          homeEdges = M.lookup (vehicleId vehicle) homeReturnBounds
          fuelRequired = journeyFuel vehicle routeEdges homeEdges
          existingFuel = sum [qtyValue (lotQty lot) - lotReserved inventory (lotId lot) | lot <- M.elems (invLots inventory), lotOwner lot == owner, lotResource lot == Fuel]
          addedFuel = max 0 (fuelRequired - existingFuel)
          freeLoad = vehicleCapacity (vehicleKind vehicle) - heldWeight inventory owner - weightOf inventory Fuel addedFuel
          unitWeight = weightOf inventory (requestResource request) 1
          childQuantity = min (requestRemaining request) (freeLoad `div` unitWeight)
      require (childQuantity > 0) NoCapacity
      require (not waitForPhysicalRefuel || vehicleKind vehicle /= Truck || homeEdges /= Nothing) MissingStock
      -- No remote stock access: the garage's port must be this exact node.
      when (addedFuel > 0) $ do
        fuelPort <- port (vehicleFuelSource vehicle) state
        require (vehiclePosition vehicle == AtRoadNode fuelPort) (if waitForPhysicalRefuel then MissingStock else InvalidReference "Fuel is not at vehicle node")
        moveFree tick (vehicleFuelSource vehicle) owner Fuel addedFuel
      ident <- freshId
      transferQuantityClaim (requestId request) ident childQuantity
      transferCapacityClaim (requestId request) ident (requestDestination request) (unitWeight * childQuantity)
      let shipment =
            Shipment
              { shipmentId = ident,
                shipmentKind = DeliveryChild (requestId request),
                shipmentSource = requestSource request,
                shipmentDestination = Just (requestDestination request),
                shipmentResource = requestResource request,
                shipmentQuantity = childQuantity,
                shipmentVehicle = vehicleId vehicle,
                shipmentStatus = ShipmentReserved,
                shipmentLots = [],
                shipmentBlock = Nothing
              }
          parent = request {requestRemaining = requestRemaining request - childQuantity, requestChildren = requestChildren request ++ [ident], requestBlock = Nothing, requestPathResult = if childQuantity == requestRemaining request then PathSearching else requestPathResult request}
          assigned = vehicle {vehicleJob = Just ident, vehicleRoute = drop 1 route, vehicleRouteRevision = topologyRevision (transportTopology state), vehiclePriority = requestPriority request, vehicleWaitingSince = tick, vehicleBlock = Nothing}
          staged = state {transportRequests = M.insert (requestId request) parent (transportRequests state), transportVehicles = M.insert (vehicleId vehicle) assigned (transportVehicles state), transportShipments = M.insert ident shipment (transportShipments state)}
      (_, loaded) <- loadShipment tick shipment staged
      pure (if requestRemaining parent == 0 then loaded {transportPaths = dropPath (requestId parent) (transportPaths loaded)} else loaded)

    -- Fuel uses quantity units: 100 per edge plus an exact 20 percent reserve.
    -- The live profile also budgets the physical route back to the garage.
    journeyFuel vehicle routeEdges homeEdges
      | vehicleKind vehicle /= Truck = 0
      | waitForPhysicalRefuel = 120 * (2 * routeEdges + maybe 0 id homeEdges)
      | otherwise = routeEdges * 240
