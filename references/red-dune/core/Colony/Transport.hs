-- | Real road-edge transport. Dispatch commits a loaded shipment; this module
-- advances its physical journey, delivery, cancellation and recovery.
module Colony.Transport
  ( module Colony.Transport.State,
    module Colony.Transport.Dispatch,
    cancelDelivery,
    terminateRequest,
    createReturn,
    cargoLots,
    chooseReturnDestination,
    reserveDestination,
    finishEmptyReturn,
    phaseTransportArrival,
    phaseTransportArrivalWithDrivers,
    phaseTransportArrivalWithPolicy,
    ensureVehicleRoute,
    ensureVehicleRouteWithTargets,
    deliverAtNode,
    unloadShipment,
    summarizeRequests,
    phaseTransportEnter,
    phaseTransportEnterWithFuelGate,
    phaseTransportExpiry,
    validateTransport,
    retireTransportPort,
    recoveryAnchor,
    startVehicleRecovery,
    phaseVehicleRecovery,
    cancelVehicleRecovery,
    refuelTransportVehicle,
    changeReturnDestination,
    incomingDeliveryQuantity,
  )
where

import Colony.Inventory
import Colony.Topology
import Colony.Transport.Dispatch
import Colony.Transport.State
import Colony.Types
import Colony.Units
import Control.Monad (foldM, forM_, unless, when)
import Control.Monad.State.Strict (get, gets, modify')
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S

-- Cancellation is applied by P1 before this boundary's P4 arrivals. Shipped
-- cargo moves to a new independent job, never to an inventory owner in place.
cancelDelivery :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
cancelDelivery tick ident state = case M.lookup ident (transportShipments state) of
  Just shipment | ReturnShipment _ <- shipmentKind shipment -> throwTx CannotCancelRecovery
  _ -> do
    request <- maybe (throwTx TargetGone) pure (M.lookup ident (transportRequests state))
    require (requestStatus request == RequestOpen) AlreadyTerminal
    terminateRequest tick RequestCancelled request state

terminateRequest :: SimTick -> RequestStatus -> DeliveryRequest -> TransportState -> InventoryTx TransportState
terminateRequest tick status request state = do
  releaseJob (requestId request)
  let parent = request {requestRemaining = 0, requestStatus = status, requestBlock = Nothing, requestPathResult = PathSearching}
      staged = state {transportRequests = M.insert (requestId request) parent (transportRequests state), transportPaths = dropPath (requestId request) (transportPaths state)}
  foldM cancelChild staged (requestChildren request)
  where
    cancelChild current ident = do
      shipment <- lookupShipment ident current
      case shipmentStatus shipment of
        ShipmentReserved -> do
          releaseJob ident
          pure current {transportShipments = M.insert ident (shipment {shipmentStatus = ShipmentCancelled}) (transportShipments current), transportVehicles = M.adjust (\v -> v {vehicleJob = Nothing, vehicleRoute = [], vehicleBlock = Nothing}) (shipmentVehicle shipment) (transportVehicles current)}
        ShipmentCarrying -> createReturn tick shipment current
        _ -> pure current

createReturn :: SimTick -> Shipment -> TransportState -> InventoryTx TransportState
createReturn tick original state = do
  ident <- freshId
  -- Transfer cargo claims before releasing obsolete destination capacity.
  modify' $ \s -> s {invQuantity = M.map (\r -> if quantityJob r == shipmentId original then r {quantityJob = ident} else r) (invQuantity s), invCapacity = M.filter ((/= shipmentId original) . capacityJob) (invCapacity s)}
  let returning = original {shipmentId = ident, shipmentKind = ReturnShipment (shipmentId original), shipmentDestination = Nothing, shipmentStatus = ShipmentCarrying, shipmentBlock = Nothing}
      transferred = original {shipmentStatus = ShipmentTransferred ident, shipmentLots = []}
      staged = state {transportShipments = M.insert ident returning (M.insert (shipmentId original) transferred (transportShipments state)), transportVehicles = M.adjust (\v -> v {vehicleJob = Just ident, vehicleRoute = [], vehicleBlock = Nothing, vehicleWaitingSince = tick}) (shipmentVehicle original) (transportVehicles state), transportPaths = dropPath (shipmentVehicle original) (transportPaths state)}
  chooseReturnDestination tick ident staged

cargoLots :: Shipment -> Inventory -> [Lot]
cargoLots shipment inventory = [lot | reservation <- M.elems (invQuantity inventory), quantityJob reservation == shipmentId shipment, Just lot <- [M.lookup (quantityLot reservation) (invLots inventory)]]

-- Return destination selection is local and capacity-reserved. A full vehicle
-- stays its unique owner; RecoveryHold is never used by voluntary cancellation.
chooseReturnDestination :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
chooseReturnDestination tick ident state = do
  shipment <- lookupShipment ident state
  vehicle <- lookupVehicle (shipmentVehicle shipment) state
  inventory <- get
  let lots = cargoLots shipment inventory
      weight = sum [weightOf inventory (lotResource lot) (qtyValue (lotQty lot)) | lot <- lots]
      resources = map lotResource lots
      allows owner = case M.lookup owner (invStorage inventory) of
        Nothing -> False
        Just storage -> all (\r -> maybe True (== r) (storageResource storage)) resources && freeWeight inventory owner >= weight && M.member owner (transportPorts state)
      source = shipmentSource shipment
      sourceExists = M.member source (invStorage inventory)
      warehouses = [owner | owner@(Owner Warehouse _) <- M.keys (invStorage inventory), maybe False ((== vehicleColony vehicle) . storageColony) (M.lookup owner (invStorage inventory)), allows owner]
      candidates = if sourceExists then [source | allows source] else warehouses
  if null lots
    then finishEmptyReturn shipment state
    else case candidates of
      destination : _ -> reserveDestination tick shipment destination state
      []
        | sourceExists -> pure (blockReturn shipment state)
        | otherwise -> case vehiclePosition vehicle of
            Traversing {} -> pure (blockReturn shipment state)
            AtRoadNode node -> case M.lookup node (transportGroundCaches state) of
              Just cache
                | allows cache -> reserveDestination tick shipment cache state
                | otherwise -> pure (blockReturn shipment state)
              Nothing | weight <= 2000000 -> do
                cacheId <- freshId
                let cache = Owner GroundCache cacheId
                addStorage cache (Storage 2000000 Nothing (vehicleColony vehicle))
                reserveDestination tick shipment cache state {transportGroundCaches = M.insert node cache (transportGroundCaches state), transportPorts = M.insert cache node (transportPorts state)}
              _ -> pure (blockReturn shipment state)
  where
    blockReturn shipment current = current {transportShipments = M.insert (shipmentId shipment) (shipment {shipmentBlock = Just NoReturnCapacity}) (transportShipments current), transportVehicles = M.adjust (\v -> v {vehicleBlock = Just NoReturnCapacity}) (shipmentVehicle shipment) (transportVehicles current)}

reserveDestination :: SimTick -> Shipment -> Owner -> TransportState -> InventoryTx TransportState
reserveDestination tick shipment destination state = do
  inventory <- get
  let groups = M.fromListWith (+) [(lotResource lot, qtyValue (lotQty lot)) | lot <- cargoLots shipment inventory]
  forM_ (M.toList groups) $ \(resource, quantity) -> reserveCapacity (shipmentId shipment) destination resource quantity
  let next = shipment {shipmentDestination = Just destination, shipmentBlock = Nothing}
  ensureVehicleRoute tick (shipmentVehicle shipment) state {transportShipments = M.insert (shipmentId shipment) next (transportShipments state)}

finishEmptyReturn :: Shipment -> TransportState -> InventoryTx TransportState
finishEmptyReturn shipment state = do
  releaseJob (shipmentId shipment)
  pure state {transportShipments = M.insert (shipmentId shipment) (shipment {shipmentStatus = ShipmentReturned, shipmentLots = [], shipmentBlock = Nothing}) (transportShipments state), transportVehicles = M.adjust (\v -> v {vehicleJob = Nothing, vehicleRoute = [], vehicleBlock = Nothing}) (shipmentVehicle shipment) (transportVehicles state), transportPaths = dropPath (shipmentVehicle shipment) (transportPaths state)}

-- A topology change never rewrites an in-flight edge. Its remaining integer
-- duration is held while that exact edge tombstone is closed.
phaseTransportArrival :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportArrival = phaseTransportArrivalWithDrivers False

-- Legacy traces retain historical movement; schema4 requires a currently eligible
-- real named driver even while already traversing an edge.
phaseTransportArrivalWithDrivers :: Bool -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportArrivalWithDrivers requireDriver = phaseTransportArrivalWithPolicy requireDriver M.empty

phaseTransportArrivalWithPolicy :: Bool -> M.Map EntityId RoadNode -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportArrivalWithPolicy requireDriver targets tick original = do
  moved <- foldM advance original (M.keys (transportVehicles original))
  returned <- foldM retryReturn moved [shipmentId s | s <- M.elems (transportShipments moved), shipmentStatus s == ShipmentCarrying, ReturnShipment _ <- [shipmentKind s], shipmentDestination s == Nothing]
  delivered <- foldM arrive returned (M.keys (transportVehicles returned))
  foldM (\s ident -> ensureVehicleRouteWithTargets targets tick ident s) delivered (M.keys (transportVehicles delivered))
  where
    advance state ident = do
      vehicle <- lookupVehicle ident state
      let replace v = state {transportVehicles = M.insert ident v (transportVehicles state)}
      if any (\r -> recoveryVehicle r == ident && recoveryStatus r == RecoveryWorking) (M.elems (transportRecoveries state))
        then pure state
        else case vehiclePosition vehicle of
          AtRoadNode _ -> pure state
          Traversing _ _ _ _ | requireDriver && not (vehicleHasDriver vehicle) -> pure (replace vehicle {vehicleBlock = Just NoDriver})
          Traversing from to remaining revision -> case openEdge (transportTopology state) from to of
            Nothing -> pure (replace vehicle {vehicleBlock = Just RemovedEdge})
            Just _
              | remaining > 1 -> pure (replace vehicle {vehiclePosition = Traversing from to (remaining - 1) revision, vehicleBlock = Nothing})
              | otherwise -> pure (replace vehicle {vehiclePosition = AtRoadNode to, vehicleWaitingSince = tick, vehicleBlock = Nothing})
    retryReturn state ident = chooseReturnDestination tick ident state
    arrive state ident = do
      vehicle <- lookupVehicle ident state
      case (vehiclePosition vehicle, vehicleJob vehicle) of
        (AtRoadNode node, Just sid) -> do
          shipment <- lookupShipment sid state
          case shipmentDestination shipment >>= (`M.lookup` transportPorts state) of
            Just destination | destination == node -> deliverAtNode tick shipment state
            _ -> pure state
        _ -> pure state

-- Apply completed routes only at nodes. Searches are keyed by vehicle ID;
-- parent requests have distinct IDs from the global inventory allocator.
ensureVehicleRoute :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
ensureVehicleRoute = ensureVehicleRouteWithTargets M.empty

ensureVehicleRouteWithTargets :: M.Map EntityId RoadNode -> SimTick -> EntityId -> TransportState -> InventoryTx TransportState
ensureVehicleRouteWithTargets targets tick ident state = do
  vehicle <- lookupVehicle ident state
  destination <- case vehicleJob vehicle of
    Just sid -> do shipment <- lookupShipment sid state; pure (shipmentDestination shipment >>= (`M.lookup` transportPorts state))
    Nothing -> pure (case M.lookup ident targets of Just target -> Just target; Nothing -> M.lookup (vehicleHome vehicle) (transportPorts state))
  case (vehiclePosition vehicle, destination) of
    (AtRoadNode node, Just target)
      | node == target -> pure state
      | vehicleRouteRevision vehicle == topologyRevision (transportTopology state) && not (null (vehicleRoute vehicle)) -> pure state
      | otherwise -> case M.lookup ident (pathSearches (transportPaths state)) of
          Just search | pathSource search == node && pathDestination search == target && pathRevision search == topologyRevision (transportTopology state) -> case pathResult search of
            PathFound route _ -> pure state {transportPaths = dropPath ident (transportPaths state), transportVehicles = M.insert ident (vehicle {vehicleRoute = drop 1 route, vehicleRouteRevision = pathRevision search, vehicleBlock = Nothing}) (transportVehicles state)}
            PathUnavailable -> pure (mark NoRoute state)
            PathSearching -> pure (mark Searching state)
          _ -> case requestPath (transportTopology state) ident node target (vehiclePriority vehicle) tick (dropPath ident (transportPaths state)) of
            Left PathQueueFull -> pure (mark Searching state)
            Left err -> throwTx err
            Right queue -> pure (mark Searching state {transportPaths = queue})
    _ -> pure state
  where
    mark block current = current {transportVehicles = M.adjust (\v -> v {vehicleRoute = [], vehicleBlock = Just block}) ident (transportVehicles current)}

deliverAtNode :: SimTick -> Shipment -> TransportState -> InventoryTx TransportState
deliverAtNode tick shipment state = do
  let accepting = case shipmentKind shipment of
        ReturnShipment _ -> True
        DeliveryChild parent -> maybe False ((== RequestOpen) . requestStatus) (M.lookup parent (transportRequests state))
  if not accepting
    then createReturn tick shipment state
    else do
      outcome <- tryInventory (unloadShipment shipment state)
      case outcome of
        Right next -> pure (summarizeRequests next)
        Left err | err `elem` [MissingReservation, NoCapacity, MissingOwner, TargetGone] -> case shipmentKind shipment of
          DeliveryChild _ -> pure state {transportShipments = M.insert (shipmentId shipment) (shipment {shipmentBlock = Just DestinationCapacityLost}) (transportShipments state), transportVehicles = M.adjust (\v -> v {vehicleBlock = Just DestinationCapacityLost}) (shipmentVehicle shipment) (transportVehicles state)}
          ReturnShipment _ -> pure state {transportShipments = M.insert (shipmentId shipment) (shipment {shipmentBlock = Just NoReturnCapacity}) (transportShipments state), transportVehicles = M.adjust (\v -> v {vehicleBlock = Just NoReturnCapacity}) (shipmentVehicle shipment) (transportVehicles state)}
        Left err -> throwTx err

unloadShipment :: Shipment -> TransportState -> InventoryTx TransportState
unloadShipment shipment state = do
  destination <- maybe (throwTx MissingOwner) pure (shipmentDestination shipment)
  vehicle <- lookupVehicle (shipmentVehicle shipment) state
  inventory <- get
  let claims = [r | r <- M.elems (invQuantity inventory), quantityJob r == shipmentId shipment]
      weight = sum [weightOf inventory (lotResource lot) (qtyValue (quantityAmount claim)) | claim <- claims, Just lot <- [M.lookup (quantityLot claim) (invLots inventory)]]
  require (not (null claims)) MissingReservation
  require (capacityFor (shipmentId shipment) destination inventory == weight) MissingReservation
  require (all (\r -> maybe False ((== vehicleOwner vehicle) . lotOwner) (M.lookup (quantityLot r) (invLots inventory))) claims) MissingReservation
  moveReserved (shipmentId shipment) (vehicleOwner vehicle) destination
  releaseJob (shipmentId shipment)
  let terminalStatus = case shipmentKind shipment of DeliveryChild _ -> ShipmentDelivered; ReturnShipment _ -> ShipmentReturned
      terminalShipment = shipment {shipmentStatus = terminalStatus, shipmentLots = [], shipmentBlock = Nothing}
  pure state {transportShipments = M.insert (shipmentId shipment) terminalShipment (transportShipments state), transportVehicles = M.insert (vehicleId vehicle) (vehicle {vehicleJob = Nothing, vehicleRoute = [], vehicleBlock = Nothing}) (transportVehicles state), transportPaths = dropPath (vehicleId vehicle) (transportPaths state)}

summarizeRequests :: TransportState -> TransportState
summarizeRequests state = state {transportRequests = M.map summary (transportRequests state), transportPaths = foldr dropPath (transportPaths state) [requestId r | r <- M.elems (transportRequests state), requestRemaining r == 0]}
  where
    summary request
      | requestStatus request /= RequestOpen = request
      | requestRemaining request /= 0 = request
      | otherwise =
          let children = [s | ident <- requestChildren request, Just s <- [M.lookup ident (transportShipments state)]]
           in if all ((== ShipmentDelivered) . shipmentStatus) children then request {requestStatus = RequestCompleted, requestBlock = Nothing} else request

-- All P4 arrivals have already released directional occupancy before this list
-- is sorted. A capacity slot is consumed immediately by each successful entry.
phaseTransportEnter :: TxId -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportEnter = phaseTransportEnterWithFuelGate S.empty

phaseTransportEnterWithFuelGate :: S.Set EntityId -> TxId -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportEnterWithFuelGate waitingFuel tx tick original = do
  recovered <- phaseVehicleRecovery tx tick original
  foldM enter recovered ordered
  where
    ordered = map vehicleId (sortOn (\v -> (vehiclePriority v, vehicleWaitingSince v, vehicleId v)) [v | v <- M.elems (transportVehicles original), AtRoadNode _ <- [vehiclePosition v], not (null (vehicleRoute v)), True])
    enter state ident = do
      vehicle <- lookupVehicle ident state
      let replace v = state {transportVehicles = M.insert ident v (transportVehicles state)}
          recovering = any (\r -> recoveryVehicle r == ident && recoveryStatus r == RecoveryWorking) (M.elems (transportRecoveries state))
          occupancy from to = length [() | other <- M.elems (transportVehicles state), Traversing a b _ _ <- [vehiclePosition other], a == from, b == to]
      case (vehiclePosition vehicle, vehicleRoute vehicle) of
        (AtRoadNode from, to : rest)
          | recovering -> pure state
          | not (vehicleHasDriver vehicle) -> pure (replace vehicle {vehicleBlock = Just NoDriver})
          | S.member ident waitingFuel -> pure (replace vehicle {vehicleBlock = Just WaitingFuel})
          | vehicleRouteRevision vehicle /= topologyRevision (transportTopology state) -> pure (replace vehicle {vehicleRoute = [], vehicleBlock = Just StaleRoute})
          | otherwise -> case openEdge (transportTopology state) from to of
              Nothing -> pure (replace vehicle {vehicleRoute = [], vehicleBlock = Just RemovedEdge})
              Just edge
                | occupancy from to >= 4 -> pure (replace vehicle {vehicleBlock = Just Congested})
                | otherwise -> do
                    consumed <- tryInventory (when (vehicleKind vehicle == Truck) (consumeFreeDetailed tx FuelBurned (Just VehicleEdge) (vehicleJob vehicle) tick (vehicleOwner vehicle) Fuel 100))
                    case consumed of
                      Left MissingStock -> pure (replace vehicle {vehicleBlock = Just WaitingFuel})
                      Left err -> throwTx err
                      Right () -> pure (replace vehicle {vehiclePosition = Traversing from to (roadCost edge) (topologyRevision (transportTopology state)), vehicleRoute = rest, vehicleBlock = Nothing})
        _ -> pure state

-- Called after Inventory.expireInventory in P2. A failed food delivery cannot
-- resurrect the old food or deliver newly generated waste as that food.
phaseTransportExpiry :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportExpiry tick original = do
  inventory <- get
  let brokenParents =
        S.toAscList
          ( S.fromList
              ( [requestId request | request <- M.elems (transportRequests original), requestStatus request == RequestOpen, quantityFor (requestId request) inventory < requestRemaining request]
                  ++ [parent | shipment <- M.elems (transportShipments original), shipmentStatus shipment == ShipmentCarrying, DeliveryChild parent <- [shipmentKind shipment], quantityFor (shipmentId shipment) inventory < shipmentQuantity shipment]
              )
          )
  failed <- foldM failParent original brokenParents
  foldM reconcileReturn failed [shipmentId s | s <- M.elems (transportShipments failed), shipmentStatus s == ShipmentCarrying, ReturnShipment _ <- [shipmentKind s]]
  where
    failParent state ident = case M.lookup ident (transportRequests state) of
      Just request | requestStatus request == RequestOpen -> do
        -- First attach newly generated waste to the carried shipment so the
        -- independent Return inherits every surviving gram, including waste.
        claimed <- foldM claimWaste state [shipmentId s | s <- M.elems (transportShipments state), shipmentKind s == DeliveryChild ident, shipmentStatus s == ShipmentCarrying]
        terminateRequest tick RequestFailed request claimed
      _ -> pure state
    claimWaste state ident = do
      shipment <- lookupShipment ident state
      vehicle <- lookupVehicle (shipmentVehicle shipment) state
      inventory <- get
      let waste = sum [qtyValue (lotQty lot) - lotReserved inventory (lotId lot) | lot <- M.elems (invLots inventory), lotOwner lot == vehicleOwner vehicle, lotResource lot == Waste]
      when (waste > 0) (reserveQuantity tick ident (vehicleOwner vehicle) Waste waste)
      lots <- gets (map lotId . cargoLots shipment)
      pure state {transportShipments = M.insert ident (shipment {shipmentLots = lots, shipmentBlock = if waste > 0 then Just ExpiredCargo else shipmentBlock shipment}) (transportShipments state)}
    reconcileReturn state ident = do
      claimed <- claimWaste state ident
      shipment <- lookupShipment ident claimed
      inventory <- get
      let lots = cargoLots shipment inventory
          actualWeight = sum [weightOf inventory (lotResource lot) (qtyValue (lotQty lot)) | lot <- lots]
          reserved = maybe 0 (\owner -> capacityFor ident owner inventory) (shipmentDestination shipment)
      if actualWeight == reserved && not (null lots)
        then pure claimed
        else do
          modify' $ \s -> s {invCapacity = M.filter ((/= ident) . capacityJob) (invCapacity s)}
          chooseReturnDestination tick ident claimed {transportShipments = M.insert ident (shipment {shipmentDestination = Nothing}) (transportShipments claimed)}

validateTransport :: TransportState -> Inventory -> Either Failure ()
validateTransport state inventory = do
  validateTopology (transportTopology state) (transportPaths state)
  let check ok message = unless ok (Left (InvariantViolation message))
      vehicles = transportVehicles state
      shipments = transportShipments state
      requests = transportRequests state
      known ident = M.member ident requests || M.member ident shipments || M.member ident vehicles
      allocated = M.keys vehicles ++ M.keys requests ++ M.keys shipments ++ M.keys (transportRecoveries state)
  check (S.size (S.fromList allocated) == length allocated) "Transport entity IDs overlap"
  check (all (\(EntityId ident) -> ident > 0 && ident < invNextId inventory) allocated) "Transport allocator high-water mismatch"
  check (transportLastAssignments state <= 256 && transportLastMatches state <= 512) "Transport assignment/matching fuel exceeded"
  forM_ (M.toList (transportPorts state)) $ \(owner, node) -> do
    check (M.member owner (invStorage inventory)) "Transport port refers to missing owner"
    check (S.member node (roadNodes (transportTopology state))) "Transport port refers to missing node"
  forM_ (M.toList (transportGroundCaches state)) $ \(node, owner@(Owner kind _)) -> do
    check (kind == GroundCache && M.lookup owner (transportPorts state) == Just node) "Invalid ground cache port"
  forM_ (M.toList vehicles) $ \(ident, vehicle) -> do
    check (ident == vehicleId vehicle) "Vehicle key mismatch"
    check (maybe False ((== vehicleCapacity (vehicleKind vehicle)) . storageCapacity) (M.lookup (vehicleOwner vehicle) (invStorage inventory))) "Missing/wrong vehicle storage"
    check (vehiclePriority vehicle >= 0 && vehiclePriority vehicle <= 3) "Invalid vehicle priority"
    check (M.member (vehicleHome vehicle) (transportPorts state) || M.member (vehicleHome vehicle) (transportRemovedPorts state)) "Missing vehicle home port or tombstone"
    forM_ (vehicleJob vehicle) $ \sid -> check (maybe False (\s -> shipmentVehicle s == ident && not (shipmentTerminal s)) (M.lookup sid shipments)) "Dangling vehicle job"
    case vehiclePosition vehicle of
      AtRoadNode node -> check (S.member node (roadNodes (transportTopology state))) "Vehicle outside road graph"
      Traversing from to remaining _ -> do
        check (maybe False (const True) (edgeBetween (transportTopology state) from to)) "Vehicle edge lacks live edge or tombstone"
        check (remaining > 0 && remaining <= 20) "Invalid edge progress"
    let anchor = case vehiclePosition vehicle of AtRoadNode node -> node; Traversing _ to _ _ -> to
    check (all (\(a, b) -> nodeDistance a b == 1) (zip (anchor : vehicleRoute vehicle) (vehicleRoute vehicle))) "Vehicle route contains teleport"
  let occupied = M.fromListWith (+) [((a, b), 1 :: Integer) | vehicle <- M.elems vehicles, Traversing a b _ _ <- [vehiclePosition vehicle]]
  check (all (<= 4) (M.elems occupied)) "Directed road-edge capacity exceeded"
  forM_ (M.toList requests) $ \(ident, request) -> do
    check (ident == requestId request && requestQuantity request > 0 && requestQuantity request <= quantityMax && requestRemaining request >= 0 && requestRemaining request <= requestQuantity request) "Invalid parent request quantity"
    check (length (requestChildren request) == S.size (S.fromList (requestChildren request))) "Duplicate child shipment"
    check (requestRouteRevision request <= topologyRevision (transportTopology state)) "Request route revision is from the future"
    case requestPathResult request of
      PathFound route cost -> do
        check (not (null route) && cost >= 0 && cost <= quantityMax) "Invalid request cached route"
        check (all (\(a, b) -> nodeDistance a b == 1) (zip route (drop 1 route))) "Request cached route contains teleport"
        when (requestRouteRevision request == topologyRevision (transportTopology state)) $ do
          check (case route of [] -> False; first : _ -> M.lookup (requestSource request) (transportPorts state) == Just first && M.lookup (requestDestination request) (transportPorts state) == Just (last route)) "Request cached route endpoints mismatch"
          let edges = [openEdge (transportTopology state) a b | (a, b) <- zip route (drop 1 route)]
          check (all (\edge -> case edge of Just _ -> True; _ -> False) edges && sum [roadCost edge | Just edge <- edges] == cost) "Request cached route/cost invalid"
      _ -> pure ()
    forM_ (requestChildren request) $ \sid -> check (maybe False ((== DeliveryChild ident) . shipmentKind) (M.lookup sid shipments)) "Dangling parent child"
    let active = requestStatus request == RequestOpen
        quantity = quantityFor ident inventory
        reserved = capacityFor ident (requestDestination request) inventory
    check (quantity == if active then requestRemaining request else 0) "Parent quantity reservation double-count or missing"
    check (reserved == if active then weightOf inventory (requestResource request) (requestRemaining request) else 0) "Parent destination capacity mismatch"
    when active $ check (requestRemaining request + sum [shipmentQuantity child | sid <- requestChildren request, Just child <- [M.lookup sid shipments]] == requestQuantity request) "Parent/child quantity conservation"
  forM_ (M.toList shipments) $ \(ident, shipment) -> do
    check (ident == shipmentId shipment && M.member (shipmentVehicle shipment) vehicles) "Shipment key or vehicle missing"
    case shipmentKind shipment of
      DeliveryChild parent -> check (M.member parent requests) "Shipment parent missing"
      ReturnShipment previous -> check (maybe False ((== ShipmentTransferred ident) . shipmentStatus) (M.lookup previous shipments)) "Return ownership transfer missing"
    let quantity = quantityFor ident inventory
        lots = cargoLots shipment inventory
        owned = Owner Vehicle (shipmentVehicle shipment)
    if shipmentTerminal shipment
      then do
        check (quantity == 0 && all ((/= ident) . capacityJob) (M.elems (invCapacity inventory))) "Terminal shipment retains reservations"
        case shipmentStatus shipment of
          ShipmentTransferred rid -> check (maybe False ((== ReturnShipment ident) . shipmentKind) (M.lookup rid shipments)) "Dangling Return transfer"
          _ -> pure ()
      else do
        check (maybe False ((== Just ident) . vehicleJob) (M.lookup (shipmentVehicle shipment) vehicles)) "Active shipment lost vehicle"
        case shipmentStatus shipment of
          ShipmentReserved -> check (quantity == shipmentQuantity shipment) "Unloaded child quantity mismatch"
          ShipmentCarrying -> do
            check (all ((== owned) . lotOwner) lots) "Cargo reservation points outside vehicle"
            check (S.fromList (shipmentLots shipment) == S.fromList (map lotId lots)) "Shipment cargo manifest differs from physical lots"
            case shipmentKind shipment of
              DeliveryChild _ -> check (quantity == shipmentQuantity shipment && all ((== shipmentResource shipment) . lotResource) lots) "Delivery cargo quantity/resource mismatch"
              ReturnShipment _ -> pure ()
          _ -> pure ()
  forM_ (M.keys (pathSearches (transportPaths state))) $ \ident -> check (known ident) "Path search owner missing"
  forM_ (M.toList (transportRecoveries state)) $ \(ident, recovery) -> do
    check (ident == recoveryId recovery && M.member (recoveryVehicle recovery) vehicles) "Recovery identity/vehicle missing"
    check (recoveryProgress recovery >= 0 && recoveryProgress recovery <= 60000) "Recovery work credit invalid"
    check (M.member (recoveryEscrow recovery) (invStorage inventory)) "Recovery escrow missing"
    let escrowLots = [lot | lot <- M.elems (invLots inventory), lotOwner lot == recoveryEscrow recovery]
    if recoveryStatus recovery == RecoveryWorking
      then check (sum [qtyValue (lotQty lot) | lot <- escrowLots, lotResource lot == Fuel] == 1000 && all ((== Fuel) . lotResource) escrowLots) "Recovery fuel WIP mismatch"
      else check (null escrowLots) "Terminal recovery retains fuel"
  let activeRecoveryVehicles = [recoveryVehicle r | r <- M.elems (transportRecoveries state), recoveryStatus r == RecoveryWorking]
  check (length activeRecoveryVehicles == S.size (S.fromList activeRecoveryVehicles)) "Vehicle has duplicate rescue crew"

-- Building deletion calls this after its owner/stock transaction is complete.
-- Old request/home references remain typed removed-port references, not dangling.
retireTransportPort :: BoundarySeq -> Owner -> TransportState -> InventoryTx TransportState
retireTransportPort boundary owner state = do
  exists <- gets (M.member owner . invStorage)
  require (not exists) (InvalidReference "Retire port after storage deletion")
  pure state {transportPorts = M.delete owner (transportPorts state), transportRemovedPorts = M.insert owner boundary (transportRemovedPorts state), transportGroundCaches = M.filter (/= owner) (transportGroundCaches state)}

recoveryAnchor :: VehiclePosition -> RoadNode
recoveryAnchor (AtRoadNode node) = node
recoveryAnchor (Traversing from _ _ _) = from

-- This is the explicitly specified crew recovery operation, not a pathfinding
-- shortcut. Its 600 ticks and fuel escrow remain visible/persisted throughout.
startVehicleRecovery :: SimTick -> EntityId -> Owner -> Bool -> TransportState -> InventoryTx (EntityId, TransportState)
startVehicleRecovery tick ident fuelSource crew state = do
  vehicle <- lookupVehicle ident state
  require crew (InvalidReference "NoRescueCrew")
  require (not (any (\r -> recoveryVehicle r == ident && recoveryStatus r == RecoveryWorking) (M.elems (transportRecoveries state)))) (InvalidReference "Vehicle already recovering")
  let anchor = recoveryAnchor (vehiclePosition vehicle)
      candidates =
        sortOn
          (\node -> (nodeDistance anchor node, node))
          [node | node <- S.toList (roadNodes (transportTopology state)), nodeDistance anchor node <= 16, not (null (roadNeighbours (transportTopology state) node))]
  target <- case candidates of [] -> throwTx NoRecoveryNode; node : _ -> pure node
  rid <- freshId
  let escrow = Owner ConstructionEscrow rid
  addStorage escrow (Storage 1000 (Just Fuel) (vehicleColony vehicle))
  moveFree tick fuelSource escrow Fuel 1000
  let recovery = VehicleRecovery rid ident target escrow fuelSource 0 RecoveryWorking True
  pure (rid, state {transportRecoveries = M.insert rid recovery (transportRecoveries state)})

phaseVehicleRecovery :: TxId -> SimTick -> TransportState -> InventoryTx TransportState
phaseVehicleRecovery tx tick original = foldM work original (M.keys (transportRecoveries original))
  where
    work state ident = case M.lookup ident (transportRecoveries state) of
      Just recovery | recoveryStatus recovery == RecoveryWorking && recoveryHasCrew recovery -> do
        let progress = min 60000 (recoveryProgress recovery + 100)
        if progress < 60000
          then pure state {transportRecoveries = M.insert ident (recovery {recoveryProgress = progress}) (transportRecoveries state)}
          else do
            -- If the reserved rescue node was closed meanwhile, remain in WIP.
            if null (roadNeighbours (transportTopology state) (recoveryTarget recovery))
              then pure state {transportRecoveries = M.insert ident (recovery {recoveryProgress = progress}) (transportRecoveries state)}
              else do
                consumeFree tx RescueFuelConsumed (Just ident) tick (recoveryEscrow recovery) Fuel 1000
                let completed = recovery {recoveryProgress = progress, recoveryStatus = RecoveryCompleted}
                    moved = state {transportRecoveries = M.insert ident completed (transportRecoveries state), transportVehicles = M.adjust (\v -> v {vehiclePosition = AtRoadNode (recoveryTarget recovery), vehicleRoute = [], vehicleRouteRevision = topologyRevision (transportTopology state), vehicleBlock = Nothing, vehicleWaitingSince = tick}) (recoveryVehicle recovery) (transportVehicles state), transportPaths = dropPath (recoveryVehicle recovery) (transportPaths state)}
                ensureVehicleRoute tick (recoveryVehicle recovery) moved
      _ -> pure state

cancelVehicleRecovery :: TxId -> SimTick -> EntityId -> TransportState -> InventoryTx TransportState
cancelVehicleRecovery tx tick ident state = do
  recovery <- maybe (throwTx TargetGone) pure (M.lookup ident (transportRecoveries state))
  require (recoveryStatus recovery == RecoveryWorking) AlreadyTerminal
  let lost = 1000 * recoveryProgress recovery `div` 60000
      returned = 1000 - lost
  outcome <- tryInventory $ do
    when (lost > 0) (consumeFree tx CancelledProcessLoss (Just ident) tick (recoveryEscrow recovery) Fuel lost)
    when (returned > 0) (moveFree tick (recoveryEscrow recovery) (recoveryFuelSource recovery) Fuel returned)
  case outcome of
    Left NoCapacity -> throwTx ReturnCapacityFull
    Left err -> throwTx err
    Right () -> pure state {transportRecoveries = M.insert ident (recovery {recoveryStatus = RecoveryCancelled}) (transportRecoveries state)}

-- Manual refuelling is a local physical transfer, never a remote warehouse read.
refuelTransportVehicle :: SimTick -> EntityId -> Owner -> Integer -> TransportState -> InventoryTx TransportState
refuelTransportVehicle tick ident fuelSource quantity state = do
  vehicle <- lookupVehicle ident state
  require (vehicleKind vehicle == Truck && quantity > 0) InvalidQuantity
  fuelNode <- port fuelSource state
  require (vehiclePosition vehicle == AtRoadNode fuelNode) (InvalidReference "Refuel source is not at vehicle node")
  moveFree tick fuelSource (vehicleOwner vehicle) Fuel quantity
  pure state {transportVehicles = M.insert ident (vehicle {vehicleBlock = Nothing}) (transportVehicles state)}

-- Recovery ownership is never cancelled; the user may select another actual
-- warehouse. Old and new capacity reservations change in one transaction.
changeReturnDestination :: SimTick -> EntityId -> Owner -> TransportState -> InventoryTx TransportState
changeReturnDestination tick ident destination state = do
  shipment <- lookupShipment ident state
  case shipmentKind shipment of { ReturnShipment _ -> pure (); _ -> throwTx (InvalidReference "Not a Return shipment") }
  require (shipmentStatus shipment == ShipmentCarrying) AlreadyTerminal
  let Owner kind _ = destination
  require (kind == Warehouse) (InvalidReference "Return target must be a warehouse")
  _ <- port destination state
  modify' $ \s -> s {invCapacity = M.filter ((/= ident) . capacityJob) (invCapacity s)}
  let cleared = state {transportVehicles = M.adjust (\v -> v {vehicleRoute = [], vehicleBlock = Nothing, vehicleWaitingSince = tick}) (shipmentVehicle shipment) (transportVehicles state), transportPaths = dropPath (shipmentVehicle shipment) (transportPaths state)}
  reserveDestination tick shipment destination cleared

-- Physical destination-bound promises without counting a split request twice.
incomingDeliveryQuantity :: TransportState -> Owner -> Resource -> Integer
incomingDeliveryQuantity state owner resource =
  sum [requestRemaining request | request <- M.elems (transportRequests state), requestStatus request == RequestOpen, requestDestination request == owner, requestResource request == resource]
    + sum
      [ shipmentQuantity shipment
      | shipment <- M.elems (transportShipments state),
        shipmentDestination shipment == Just owner,
        shipmentResource shipment == resource,
        shipmentStatus shipment `elem` [ShipmentReserved, ShipmentCarrying],
        DeliveryChild _ <- [shipmentKind shipment]
      ]
