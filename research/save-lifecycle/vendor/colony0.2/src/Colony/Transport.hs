{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
-- | Real road-edge transport. InventoryTx makes each request, split, load,
-- unload and cancellation atomic with the authoritative physical inventory.
module Colony.Transport where

import Colony.Inventory
import Colony.Topology
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (foldM, forM_, unless, when)
import Control.Monad.State.Strict (get, gets, put, modify', runStateT)
import Data.List (groupBy, sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import GHC.Generics (Generic)

data VehicleKind = CarrierCart | Truck deriving (Eq,Ord,Show,Read,Generic,NFData)
data VehiclePosition = AtRoadNode !RoadNode | Traversing !RoadNode !RoadNode !Integer !Word64
  deriving (Eq,Show,Read,Generic,NFData)
data TransportBlock = Searching | NoRoute | Congested | WaitingFuel | NoReturnCapacity
  | RemovedEdge | StaleRoute | WaitingVehicle | ExpiredCargo | DestinationCapacityLost
  | NoDriver | WaitingSourcePort
  deriving (Eq,Ord,Show,Read,Generic,NFData)
data TransportVehicle = TransportVehicle
  { vehicleId :: !EntityId, vehicleKind :: !VehicleKind, vehicleColony :: !EntityId
  , vehicleHome :: !Owner, vehicleFuelSource :: !Owner, vehiclePosition :: !VehiclePosition
  , vehicleRoute :: ![RoadNode], vehicleRouteRevision :: !Word64
  , vehicleJob :: !(Maybe EntityId), vehiclePriority :: !Integer, vehicleWaitingSince :: !SimTick
  , vehicleBlock :: !(Maybe TransportBlock), vehicleHasDriver :: !Bool }
  deriving (Eq,Show,Read,Generic,NFData)
data RequestStatus = RequestOpen | RequestCompleted | RequestCancelled | RequestFailed
  deriving (Eq,Ord,Show,Read,Generic,NFData)
data DeliveryRequest = DeliveryRequest
  { requestId :: !EntityId, requestSource :: !Owner, requestDestination :: !Owner
  , requestResource :: !Resource, requestQuantity :: !Integer, requestRemaining :: !Integer
  , requestChildren :: ![EntityId], requestStatus :: !RequestStatus
  , requestPriority :: !Integer, requestReadySince :: !SimTick, requestBlock :: !(Maybe TransportBlock)
  , requestPathResult :: !PathResult, requestRouteRevision :: !Word64 }
  deriving (Eq,Show,Read,Generic,NFData)
data ShipmentKind = DeliveryChild !EntityId | ReturnShipment !EntityId
  deriving (Eq,Show,Read,Generic,NFData)
data ShipmentStatus = ShipmentReserved | ShipmentCarrying | ShipmentDelivered | ShipmentCancelled
  | ShipmentReturned | ShipmentTransferred !EntityId | ShipmentFailed
  deriving (Eq,Show,Read,Generic,NFData)
data Shipment = Shipment
  { shipmentId :: !EntityId, shipmentKind :: !ShipmentKind, shipmentSource :: !Owner
  , shipmentDestination :: !(Maybe Owner), shipmentResource :: !Resource, shipmentQuantity :: !Integer
  , shipmentVehicle :: !EntityId, shipmentStatus :: !ShipmentStatus, shipmentLots :: ![EntityId]
  , shipmentBlock :: !(Maybe TransportBlock) }
  deriving (Eq,Show,Read,Generic,NFData)
data RecoveryStatus = RecoveryWorking | RecoveryCompleted | RecoveryCancelled
  deriving (Eq,Ord,Show,Read,Generic,NFData)
data VehicleRecovery = VehicleRecovery
  { recoveryId :: !EntityId, recoveryVehicle :: !EntityId, recoveryTarget :: !RoadNode
  , recoveryEscrow :: !Owner, recoveryFuelSource :: !Owner, recoveryProgress :: !Integer
  , recoveryStatus :: !RecoveryStatus, recoveryHasCrew :: !Bool }
  deriving (Eq,Show,Read,Generic,NFData)
data TransportState = TransportState
  { transportTopology :: !RoadTopology, transportPaths :: !PathQueue
  , transportPorts :: !(M.Map Owner RoadNode), transportGroundCaches :: !(M.Map RoadNode Owner)
  , transportRemovedPorts :: !(M.Map Owner BoundarySeq), transportRecoveries :: !(M.Map EntityId VehicleRecovery)
  , transportVehicles :: !(M.Map EntityId TransportVehicle)
  , transportRequests :: !(M.Map EntityId DeliveryRequest), transportShipments :: !(M.Map EntityId Shipment)
  , transportAssignCursor :: !(Maybe EntityId), transportLastAssignments :: !Word64
  , transportMatchCursors :: !(M.Map EntityId EntityId), transportLastMatches :: !Word64 }
  deriving (Eq,Show,Read,Generic,NFData)

emptyTransport :: TransportState
emptyTransport=TransportState emptyTopology emptyPathQueue M.empty M.empty M.empty M.empty M.empty M.empty M.empty Nothing 0 M.empty 0
vehicleCapacity :: VehicleKind -> Integer
vehicleCapacity CarrierCart=50000
vehicleCapacity Truck=300000
vehicleOwner :: TransportVehicle -> Owner
vehicleOwner=Owner Vehicle . vehicleId
shipmentTerminal :: Shipment -> Bool
shipmentTerminal shipment=case shipmentStatus shipment of ShipmentReserved->False;ShipmentCarrying->False;_->True

addTransportPort :: Owner -> RoadNode -> TransportState -> InventoryTx TransportState
addTransportPort owner node state=do
  exists<-gets(M.member owner.invStorage)
  require exists MissingOwner
  require(S.member node(roadNodes(transportTopology state)))(InvalidReference "Port is not on a road node")
  pure state {transportPorts=M.insert owner node(transportPorts state)}

-- Vehicle construction costs/work are handled by construction. This constructor
-- registers an already granted or actually completed vehicle and its storage.
addTransportVehicle :: VehicleKind -> EntityId -> Owner -> Owner -> RoadNode -> SimTick -> TransportState -> InventoryTx (EntityId,TransportState)
addTransportVehicle kind colony home fuelSource node tick state=do
  require(M.lookup home(transportPorts state)==Just node)(InvalidReference "Vehicle home port mismatch")
  require(M.lookup fuelSource(transportPorts state)==Just node)(InvalidReference "Fuel must be at vehicle's physical home node")
  ident<-freshId
  addStorage(Owner Vehicle ident)(Storage(vehicleCapacity kind)Nothing colony)
  let vehicle=TransportVehicle ident kind colony home fuelSource(AtRoadNode node)[](topologyRevision(transportTopology state))Nothing 2 tick Nothing True
  pure(ident,state {transportVehicles=M.insert ident vehicle(transportVehicles state)})

planDelivery :: SimTick -> Owner -> Owner -> Resource -> Integer -> Integer -> TransportState -> InventoryTx (EntityId,TransportState)
planDelivery tick src dst resource quantity priority state=do
  require(src/=dst && quantity>0 && priority>=0 && priority<=3)InvalidQuantity
  require(length(filter((==RequestOpen).requestStatus)(M.elems(transportRequests state)))<8192)TransportRequestFull
  source<-port src state
  destination<-port dst state
  ident<-freshId
  reserveDelivery tick ident src dst resource quantity
  queue<-either throwTx pure(requestPath(transportTopology state)ident source destination priority tick(transportPaths state))
  let request=DeliveryRequest ident src dst resource quantity quantity [] RequestOpen priority tick(Just Searching)PathSearching(topologyRevision(transportTopology state))
  pure(ident,state {transportRequests=M.insert ident request(transportRequests state),transportPaths=queue})

port :: Owner -> TransportState -> InventoryTx RoadNode
port owner state=maybe(throwTx(InvalidReference "MissingRoadPort"))pure(M.lookup owner(transportPorts state))
lookupVehicle :: EntityId -> TransportState -> InventoryTx TransportVehicle
lookupVehicle ident state=maybe(throwTx TargetGone)pure(M.lookup ident(transportVehicles state))
lookupShipment :: EntityId -> TransportState -> InventoryTx Shipment
lookupShipment ident state=maybe(throwTx TargetGone)pure(M.lookup ident(transportShipments state))

quantityFor :: EntityId -> Inventory -> Integer
quantityFor ident inventory=sum[qtyValue(quantityAmount reservation)|reservation<-M.elems(invQuantity inventory),quantityJob reservation==ident]
capacityFor :: EntityId -> Owner -> Inventory -> Integer
capacityFor ident owner inventory=sum[capacityWeight reservation|reservation<-M.elems(invCapacity inventory),capacityJob reservation==ident,capacityOwner reservation==owner]

-- Move reservation ownership; a split never reserves the physical stock twice.
transferQuantityClaim :: EntityId -> EntityId -> Integer -> InventoryTx ()
transferQuantityClaim parent child quantity=do
  inventory<-get
  let reservations=sortOn(\r->(maybe (True,Nothing,SimTick 0,quantityLot r) fefo(M.lookup(quantityLot r)(invLots inventory)),quantityReservationId r))
        [r|r<-M.elems(invQuantity inventory),quantityJob r==parent]
  require(sum(map(qtyValue.quantityAmount)reservations)>=quantity)MissingReservation
  go quantity reservations
  where
    go 0 _=pure()
    go _ []=throwTx MissingReservation
    go remaining(reservation:rest)=do
      let takeQty=min remaining(qtyValue(quantityAmount reservation))
      if takeQty==qtyValue(quantityAmount reservation)
      then modify' $ \s->s {invQuantity=M.adjust(\r->r {quantityJob=child})(quantityReservationId reservation)(invQuantity s)}
      else do
        kept<-checked(qtyValue(quantityAmount reservation)-takeQty)
        moved<-checked takeQty
        ident<-freshId
        modify' $ \s->s {invQuantity=M.insert ident(QuantityReservation ident child(quantityLot reservation)moved)
          (M.adjust(\r->r {quantityAmount=kept})(quantityReservationId reservation)(invQuantity s))}
      go(remaining-takeQty)rest
transferCapacityClaim :: EntityId -> EntityId -> Owner -> Integer -> InventoryTx ()
transferCapacityClaim parent child owner weight=do
  inventory<-get
  let reservations=[r|r<-M.elems(invCapacity inventory),capacityJob r==parent,capacityOwner r==owner]
  require(sum(map capacityWeight reservations)>=weight)MissingReservation
  go weight reservations
  where
    go 0 _=pure()
    go _ []=throwTx MissingReservation
    go remaining(reservation:rest)=do
      let takeWeight=min remaining(capacityWeight reservation)
      if takeWeight==capacityWeight reservation
      then modify' $ \s->s {invCapacity=M.adjust(\r->r {capacityJob=child})(capacityReservationId reservation)(invCapacity s)}
      else do
        ident<-freshId
        modify' $ \s->s {invCapacity=M.insert ident(CapacityReservation ident child owner takeWeight)
          (M.adjust(\r->r {capacityWeight=capacityWeight r-takeWeight})(capacityReservationId reservation)(invCapacity s))}
      go(remaining-takeWeight)rest

-- Source-to-vehicle transfer preserves per-lot age, expiry and provenance.
-- Cargo claims in the vehicle also keep delivery fuel separate from engine fuel.
loadShipment :: SimTick -> Shipment -> TransportState -> InventoryTx (Shipment,TransportState)
loadShipment tick shipment state=do
  require(shipmentStatus shipment==ShipmentReserved)(InvalidReference "Shipment already loaded")
  vehicle<-lookupVehicle(shipmentVehicle shipment)state
  sourceNode<-port(shipmentSource shipment)state
  require(vehiclePosition vehicle==AtRoadNode sourceNode)(InvalidReference "Vehicle is not physically at source")
  inventory<-get
  let claims=[r|r<-M.elems(invQuantity inventory),quantityJob r==shipmentId shipment]
      sourceLots=[lot|r<-claims,Just lot<-[M.lookup(quantityLot r)(invLots inventory)]]
  require(sum(map(qtyValue.quantityAmount)claims)==shipmentQuantity shipment)MissingReservation
  require(all(\lot->lotOwner lot==shipmentSource shipment&&usable tick lot)sourceLots)ExpiredInput
  before<-gets(M.keysSet.invLots)
  moveReserved(shipmentId shipment)(shipmentSource shipment)(vehicleOwner vehicle)
  moved<-gets(filter(\lot->not(S.member(lotId lot)before)&&lotOwner lot==vehicleOwner vehicle).M.elems.invLots)
  forM_ moved $ \lot->do
    ident<-freshId
    modify' $ \s->s {invQuantity=M.insert ident(QuantityReservation ident(shipmentId shipment)(lotId lot)(lotQty lot))(invQuantity s)}
  let loaded=shipment {shipmentStatus=ShipmentCarrying,shipmentLots=map lotId moved,shipmentBlock=Nothing}
  pure(loaded,state {transportShipments=M.insert(shipmentId loaded)loaded(transportShipments state)})

-- Execute a recoverable job transaction against a private inventory snapshot.
-- Expected shortages keep a typed wait state, never half of a load or unload.
tryInventory :: InventoryTx a -> InventoryTx (Either Failure a)
tryInventory action=do
  before<-get
  case runStateT action before of
    Left err->case err of InvariantViolation _->throwTx err;CounterOverflow->throwTx err;_->pure(Left err)
    Right(result,after)->put after>>pure(Right result)

phaseTransportPaths :: SimTick -> TransportState -> Either Failure TransportState
phaseTransportPaths tick state=do
  -- Completed parent searches leave the bounded work queue. Their immutable
  -- route is retained by the request while split shipments still need it.
  -- Otherwise4096 partially-filled parents could block every return-home path.
  prepared<-foldM prepare(transportPaths state)pending
  queue<-advancePaths tick topology prepared
  let completed=[search|search<-M.elems(pathSearches queue),M.member(pathId search)(transportRequests state),pathResult search/=PathSearching]
      applied=foldl apply(transportRequests state)completed
  pure state {transportPaths=foldr(dropPath.pathId)queue completed,transportRequests=applied}
  where
    topology=transportTopology state
    pending=sortOn(\r->(effectiveRequest tick r,requestReadySince r,requestId r))
      [r|r<-M.elems(transportRequests state),requestStatus r==RequestOpen,requestRemaining r>0,
         requestRouteRevision r/=topologyRevision topology||requestPathResult r==PathSearching]
    prepare queue request
      | M.member(requestId request)(pathSearches queue)=Right queue
      | otherwise=case(M.lookup(requestSource request)(transportPorts state),M.lookup(requestDestination request)(transportPorts state))of
          (Just src,Just dst)->case requestPath topology(requestId request)src dst(requestPriority request)(requestReadySince request)queue of
            Left PathQueueFull->Right queue
            otherResult->otherResult
          _->Right queue
    apply requests search=M.adjust(\r->r {requestPathResult=pathResult search,requestRouteRevision=pathRevision search,requestBlock=case pathResult search of PathFound{}->Nothing;PathUnavailable->Just NoRoute;PathSearching->Just Searching})(pathId search)requests

phaseTransportAssign :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportAssign=phaseTransportAssignBudget 256

phaseTransportAssignBudget :: Word64 -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportAssignBudget budget tick original=do
  require(budget<=256)InvalidQuantity
  foldM assign reset candidates
  where
    reset=original {transportLastAssignments=0,transportLastMatches=0}
    ordered=sortOn(\r->(effectiveRequest tick r,requestReadySince r,requestId r)) [r|r<-M.elems(transportRequests original),requestStatus r==RequestOpen,requestRemaining r>0]
    rotate peers=case transportAssignCursor original of
      Nothing->peers
      Just ident->case break((==ident).requestId)peers of (_,[])->peers;(before,current:after)->after++before++[current]
    rotated=concatMap rotate(groupBy(\a b->effectiveRequest tick a==effectiveRequest tick b)ordered)
    candidates=take(fromIntegral budget)rotated
    assign state request=do
      let counted=state {transportLastAssignments=transportLastAssignments state+1,transportAssignCursor=Just(requestId request)}
      if requestRouteRevision request/=topologyRevision(transportTopology state)then pure(setRequestBlock(requestId request)Searching counted)
      else case requestPathResult request of
        PathFound route _->assignReady tick request route counted
        PathUnavailable->pure(setRequestBlock(requestId request)NoRoute counted)
        PathSearching->pure(setRequestBlock(requestId request)Searching counted)

effectiveRequest :: SimTick -> DeliveryRequest -> Integer
effectiveRequest(SimTick now) request=let SimTick ready=requestReadySince request in max 0(requestPriority request-max 0(toInteger now-toInteger ready) `div` 1200)
setRequestBlock :: EntityId -> TransportBlock -> TransportState -> TransportState
setRequestBlock ident block state=state {transportRequests=M.adjust(\r->r {requestBlock=Just block})ident(transportRequests state)}

assignReady :: SimTick -> DeliveryRequest -> [RoadNode] -> TransportState -> InventoryTx TransportState
assignReady tick request route state=do
  sourceNode<-port(requestSource request)state
  inventory<-get
  let colony=storageColony <$> M.lookup(requestSource request)(invStorage inventory)
      eligible=[v|v<-M.elems(transportVehicles state),vehicleJob v==Nothing,vehiclePosition v==AtRoadNode sourceNode,Just(vehicleColony v)==colony,vehicleHasDriver v]
      ordered=case M.lookup(requestId request)(transportMatchCursors state)of
        Nothing->eligible
        Just cursor->let(after,before)=span((<=cursor).vehicleId)eligible in before++after
      budget=min 32(512-transportLastMatches state)
  tryVehicles budget ordered Nothing state
  where
    tryVehicles _ [] problem current=pure(setRequestBlock(requestId request)(maybe WaitingVehicle id problem)current)
    tryVehicles 0 _ problem current=pure(setRequestBlock(requestId request)(maybe WaitingVehicle id problem)current)
    tryVehicles remaining(vehicle:rest) problem current=do
      let counted=current {transportLastMatches=transportLastMatches current+1,transportMatchCursors=M.insert(requestId request)(vehicleId vehicle)(transportMatchCursors current)}
      outcome<-tryInventory(makeChild vehicle)
      case outcome of
        Right next->pure next {transportLastMatches=transportLastMatches counted,transportMatchCursors=M.delete(requestId request)(transportMatchCursors counted)}
        Left MissingStock->tryVehicles(remaining-1)rest(Just WaitingFuel)counted
        Left NoCapacity->tryVehicles(remaining-1)rest problem counted
        Left err->throwTx err
    makeChild vehicle=do
      inventory<-get
      let owner=vehicleOwner vehicle
          routeEdges=toInteger(length route)-1
          -- Full outward and reverse journey plus an exact 20 percent reserve.
          fuelRequired=if vehicleKind vehicle==Truck then routeEdges*240 else 0
          existingFuel=sum[qtyValue(lotQty lot)-lotReserved inventory(lotId lot)|lot<-M.elems(invLots inventory),lotOwner lot==owner,lotResource lot==Fuel]
          addedFuel=max 0(fuelRequired-existingFuel)
          freeLoad=vehicleCapacity(vehicleKind vehicle)-heldWeight inventory owner-weightOf inventory Fuel addedFuel
          unitWeight=weightOf inventory(requestResource request)1
          childQuantity=min(requestRemaining request)(freeLoad `div` unitWeight)
      require(childQuantity>0)NoCapacity
      -- No remote stock access: the garage's port must be this exact node.
      when(addedFuel>0)$do
        fuelPort<-port(vehicleFuelSource vehicle)state
        require(vehiclePosition vehicle==AtRoadNode fuelPort)(InvalidReference "Fuel is not at vehicle node")
        moveFree tick(vehicleFuelSource vehicle)owner Fuel addedFuel
      ident<-freshId
      transferQuantityClaim(requestId request)ident childQuantity
      transferCapacityClaim(requestId request)ident(requestDestination request)(unitWeight*childQuantity)
      let shipment=Shipment ident(DeliveryChild(requestId request))(requestSource request)(Just(requestDestination request))(requestResource request)childQuantity(vehicleId vehicle)ShipmentReserved [] Nothing
          parent=request {requestRemaining=requestRemaining request-childQuantity,requestChildren=requestChildren request++[ident],requestBlock=Nothing,requestPathResult=if childQuantity==requestRemaining request then PathSearching else requestPathResult request}
          assigned=vehicle {vehicleJob=Just ident,vehicleRoute=drop 1 route,vehicleRouteRevision=topologyRevision(transportTopology state),vehiclePriority=requestPriority request,vehicleWaitingSince=tick,vehicleBlock=Nothing}
          staged=state {transportRequests=M.insert(requestId request)parent(transportRequests state),transportVehicles=M.insert(vehicleId vehicle)assigned(transportVehicles state),transportShipments=M.insert ident shipment(transportShipments state)}
      (_,loaded)<-loadShipment tick shipment staged
      pure(if requestRemaining parent==0 then loaded {transportPaths=dropPath(requestId parent)(transportPaths loaded)}else loaded)

-- Cancellation is applied by P1 before this boundary's P4 arrivals. Shipped
-- cargo moves to a new independent job, never to an inventory owner in place.
cancelDelivery :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
cancelDelivery tick ident state=case M.lookup ident(transportShipments state)of
  Just shipment|ReturnShipment _<-shipmentKind shipment->throwTx CannotCancelRecovery
  _->do
    request<-maybe(throwTx TargetGone)pure(M.lookup ident(transportRequests state))
    require(requestStatus request==RequestOpen)AlreadyTerminal
    terminateRequest tick RequestCancelled request state

terminateRequest :: SimTick -> RequestStatus -> DeliveryRequest -> TransportState -> InventoryTx TransportState
terminateRequest tick status request state=do
  releaseJob(requestId request)
  let parent=request {requestRemaining=0,requestStatus=status,requestBlock=Nothing,requestPathResult=PathSearching}
      staged=state {transportRequests=M.insert(requestId request)parent(transportRequests state),transportPaths=dropPath(requestId request)(transportPaths state)}
  foldM cancelChild staged(requestChildren request)
  where
    cancelChild current ident=do
      shipment<-lookupShipment ident current
      case shipmentStatus shipment of
        ShipmentReserved->do
          releaseJob ident
          pure current {transportShipments=M.insert ident(shipment {shipmentStatus=ShipmentCancelled})(transportShipments current),transportVehicles=M.adjust(\v->v {vehicleJob=Nothing,vehicleRoute=[],vehicleBlock=Nothing})(shipmentVehicle shipment)(transportVehicles current)}
        ShipmentCarrying->createReturn tick shipment current
        _->pure current

createReturn :: SimTick -> Shipment -> TransportState -> InventoryTx TransportState
createReturn tick original state=do
  ident<-freshId
  -- Transfer cargo claims before releasing obsolete destination capacity.
  modify' $ \s->s {invQuantity=M.map(\r->if quantityJob r==shipmentId original then r {quantityJob=ident}else r)(invQuantity s),invCapacity=M.filter((/=shipmentId original).capacityJob)(invCapacity s)}
  let returning=original {shipmentId=ident,shipmentKind=ReturnShipment(shipmentId original),shipmentDestination=Nothing,shipmentStatus=ShipmentCarrying,shipmentBlock=Nothing}
      transferred=original {shipmentStatus=ShipmentTransferred ident,shipmentLots=[]}
      staged=state {transportShipments=M.insert ident returning(M.insert(shipmentId original)transferred(transportShipments state)),transportVehicles=M.adjust(\v->v {vehicleJob=Just ident,vehicleRoute=[],vehicleBlock=Nothing,vehicleWaitingSince=tick})(shipmentVehicle original)(transportVehicles state),transportPaths=dropPath(shipmentVehicle original)(transportPaths state)}
  chooseReturnDestination tick ident staged

cargoLots :: Shipment -> Inventory -> [Lot]
cargoLots shipment inventory=[lot|reservation<-M.elems(invQuantity inventory),quantityJob reservation==shipmentId shipment,Just lot<-[M.lookup(quantityLot reservation)(invLots inventory)]]

-- Return destination selection is local and capacity-reserved. A full vehicle
-- stays its unique owner; RecoveryHold is never used by voluntary cancellation.
chooseReturnDestination :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
chooseReturnDestination tick ident state=do
  shipment<-lookupShipment ident state
  vehicle<-lookupVehicle(shipmentVehicle shipment)state
  inventory<-get
  let lots=cargoLots shipment inventory
      weight=sum[weightOf inventory(lotResource lot)(qtyValue(lotQty lot))|lot<-lots]
      resources=map lotResource lots
      allows owner=case M.lookup owner(invStorage inventory)of
        Nothing->False
        Just storage->all(\r->maybe True(==r)(storageResource storage))resources && freeWeight inventory owner>=weight && M.member owner(transportPorts state)
      source=shipmentSource shipment
      sourceExists=M.member source(invStorage inventory)
      warehouses=[owner|owner@(Owner Warehouse _)<-M.keys(invStorage inventory),maybe False((==vehicleColony vehicle).storageColony)(M.lookup owner(invStorage inventory)),allows owner]
      candidates=if sourceExists then [source|allows source]else warehouses
  if null lots then finishEmptyReturn shipment state else case candidates of
    destination:_->reserveDestination tick shipment destination state
    []|sourceExists->pure(blockReturn shipment state)
      |otherwise->case vehiclePosition vehicle of
        Traversing{}->pure(blockReturn shipment state)
        AtRoadNode node->case M.lookup node(transportGroundCaches state)of
          Just cache|allows cache->reserveDestination tick shipment cache state
                    |otherwise->pure(blockReturn shipment state)
          Nothing|weight<=2000000->do
            cacheId<-freshId
            let cache=Owner GroundCache cacheId
            addStorage cache(Storage 2000000 Nothing(vehicleColony vehicle))
            reserveDestination tick shipment cache state {transportGroundCaches=M.insert node cache(transportGroundCaches state),transportPorts=M.insert cache node(transportPorts state)}
          _->pure(blockReturn shipment state)
  where
    blockReturn shipment current=current {transportShipments=M.insert(shipmentId shipment)(shipment {shipmentBlock=Just NoReturnCapacity})(transportShipments current),transportVehicles=M.adjust(\v->v {vehicleBlock=Just NoReturnCapacity})(shipmentVehicle shipment)(transportVehicles current)}

reserveDestination :: SimTick -> Shipment -> Owner -> TransportState -> InventoryTx TransportState
reserveDestination tick shipment destination state=do
  inventory<-get
  let groups=M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-cargoLots shipment inventory]
  forM_(M.toList groups)$ \(resource,quantity)->reserveCapacity(shipmentId shipment)destination resource quantity
  let next=shipment {shipmentDestination=Just destination,shipmentBlock=Nothing}
  ensureVehicleRoute tick(shipmentVehicle shipment)state {transportShipments=M.insert(shipmentId shipment)next(transportShipments state)}

finishEmptyReturn :: Shipment -> TransportState -> InventoryTx TransportState
finishEmptyReturn shipment state=do
  releaseJob(shipmentId shipment)
  pure state {transportShipments=M.insert(shipmentId shipment)(shipment {shipmentStatus=ShipmentReturned,shipmentLots=[],shipmentBlock=Nothing})(transportShipments state),transportVehicles=M.adjust(\v->v {vehicleJob=Nothing,vehicleRoute=[],vehicleBlock=Nothing})(shipmentVehicle shipment)(transportVehicles state),transportPaths=dropPath(shipmentVehicle shipment)(transportPaths state)}

-- A topology change never rewrites an in-flight edge. Its remaining integer
-- duration is held while that exact edge tombstone is closed.
phaseTransportArrival :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportArrival tick original=do
  moved<-foldM advance original(M.keys(transportVehicles original))
  returned<-foldM retryReturn moved[shipmentId s|s<-M.elems(transportShipments moved),shipmentStatus s==ShipmentCarrying,ReturnShipment _<-[shipmentKind s],shipmentDestination s==Nothing]
  delivered<-foldM arrive returned(M.keys(transportVehicles returned))
  foldM(\s ident->ensureVehicleRoute tick ident s)delivered(M.keys(transportVehicles delivered))
  where
    advance state ident=do
      vehicle<-lookupVehicle ident state
      let replace v=state {transportVehicles=M.insert ident v(transportVehicles state)}
      if any(\r->recoveryVehicle r==ident&&recoveryStatus r==RecoveryWorking)(M.elems(transportRecoveries state))then pure state else case vehiclePosition vehicle of
        AtRoadNode _->pure state
        Traversing from to remaining revision->case openEdge(transportTopology state)from to of
          Nothing->pure(replace vehicle {vehicleBlock=Just RemovedEdge})
          Just _|remaining>1->pure(replace vehicle {vehiclePosition=Traversing from to(remaining-1)revision,vehicleBlock=Nothing})
                |otherwise->pure(replace vehicle {vehiclePosition=AtRoadNode to,vehicleWaitingSince=tick,vehicleBlock=Nothing})
    retryReturn state ident=chooseReturnDestination tick ident state
    arrive state ident=do
      vehicle<-lookupVehicle ident state
      case(vehiclePosition vehicle,vehicleJob vehicle)of
        (AtRoadNode node,Just sid)->do
          shipment<-lookupShipment sid state
          case shipmentDestination shipment >>= (`M.lookup` transportPorts state)of
            Just destination|destination==node->deliverAtNode tick shipment state
            _->pure state
        _->pure state

-- Apply completed routes only at nodes. Searches are keyed by vehicle ID;
-- parent requests have distinct IDs from the global inventory allocator.
ensureVehicleRoute :: SimTick -> EntityId -> TransportState -> InventoryTx TransportState
ensureVehicleRoute tick ident state=do
  vehicle<-lookupVehicle ident state
  destination<-case vehicleJob vehicle of
    Just sid->do shipment<-lookupShipment sid state; pure(shipmentDestination shipment >>= (`M.lookup` transportPorts state))
    Nothing->pure(M.lookup(vehicleHome vehicle)(transportPorts state))
  case(vehiclePosition vehicle,destination)of
    (AtRoadNode node,Just target)
      | node==target->pure state
      | vehicleRouteRevision vehicle==topologyRevision(transportTopology state)&&not(null(vehicleRoute vehicle))->pure state
      | otherwise->case M.lookup ident(pathSearches(transportPaths state))of
          Just search|pathSource search==node&&pathDestination search==target&&pathRevision search==topologyRevision(transportTopology state)->case pathResult search of
            PathFound route _->pure state {transportPaths=dropPath ident(transportPaths state),transportVehicles=M.insert ident(vehicle {vehicleRoute=drop 1 route,vehicleRouteRevision=pathRevision search,vehicleBlock=Nothing})(transportVehicles state)}
            PathUnavailable->pure(mark NoRoute state)
            PathSearching->pure(mark Searching state)
          _->case requestPath(transportTopology state)ident node target(vehiclePriority vehicle)tick(dropPath ident(transportPaths state))of
            Left PathQueueFull->pure(mark Searching state)
            Left err->throwTx err
            Right queue->pure(mark Searching state {transportPaths=queue})
    _->pure state
  where
    mark block current=current {transportVehicles=M.adjust(\v->v {vehicleRoute=[],vehicleBlock=Just block})ident(transportVehicles current)}

deliverAtNode :: SimTick -> Shipment -> TransportState -> InventoryTx TransportState
deliverAtNode tick shipment state=do
  let accepting=case shipmentKind shipment of
        ReturnShipment _->True
        DeliveryChild parent->maybe False((==RequestOpen).requestStatus)(M.lookup parent(transportRequests state))
  if not accepting then createReturn tick shipment state else do
    outcome<-tryInventory(unloadShipment shipment state)
    case outcome of
      Right next->pure(summarizeRequests next)
      Left err|err `elem` [MissingReservation,NoCapacity,MissingOwner,TargetGone]->case shipmentKind shipment of
        DeliveryChild _->pure state {transportShipments=M.insert(shipmentId shipment)(shipment {shipmentBlock=Just DestinationCapacityLost})(transportShipments state),transportVehicles=M.adjust(\v->v {vehicleBlock=Just DestinationCapacityLost})(shipmentVehicle shipment)(transportVehicles state)}
        ReturnShipment _->pure state {transportShipments=M.insert(shipmentId shipment)(shipment {shipmentBlock=Just NoReturnCapacity})(transportShipments state),transportVehicles=M.adjust(\v->v {vehicleBlock=Just NoReturnCapacity})(shipmentVehicle shipment)(transportVehicles state)}
      Left err->throwTx err

unloadShipment :: Shipment -> TransportState -> InventoryTx TransportState
unloadShipment shipment state=do
  destination<-maybe(throwTx MissingOwner)pure(shipmentDestination shipment)
  vehicle<-lookupVehicle(shipmentVehicle shipment)state
  inventory<-get
  let claims=[r|r<-M.elems(invQuantity inventory),quantityJob r==shipmentId shipment]
      weight=sum[weightOf inventory(lotResource lot)(qtyValue(quantityAmount claim))|claim<-claims,Just lot<-[M.lookup(quantityLot claim)(invLots inventory)]]
  require(not(null claims))MissingReservation
  require(capacityFor(shipmentId shipment)destination inventory==weight)MissingReservation
  require(all(\r->maybe False((==vehicleOwner vehicle).lotOwner)(M.lookup(quantityLot r)(invLots inventory)))claims)MissingReservation
  moveReserved(shipmentId shipment)(vehicleOwner vehicle)destination
  releaseJob(shipmentId shipment)
  let terminalStatus=case shipmentKind shipment of DeliveryChild _->ShipmentDelivered;ReturnShipment _->ShipmentReturned
      terminalShipment=shipment {shipmentStatus=terminalStatus,shipmentLots=[],shipmentBlock=Nothing}
  pure state {transportShipments=M.insert(shipmentId shipment)terminalShipment(transportShipments state),transportVehicles=M.insert(vehicleId vehicle)(vehicle {vehicleJob=Nothing,vehicleRoute=[],vehicleBlock=Nothing})(transportVehicles state),transportPaths=dropPath(vehicleId vehicle)(transportPaths state)}

summarizeRequests :: TransportState -> TransportState
summarizeRequests state=state {transportRequests=M.map summary(transportRequests state),transportPaths=foldr dropPath(transportPaths state)[requestId r|r<-M.elems(transportRequests state),requestRemaining r==0]}
  where
    summary request|requestStatus request/=RequestOpen=request
                   |requestRemaining request/=0=request
                   |otherwise=let children=[s|ident<-requestChildren request,Just s<-[M.lookup ident(transportShipments state)]]
                              in if all((==ShipmentDelivered).shipmentStatus)children then request {requestStatus=RequestCompleted,requestBlock=Nothing}else request

-- All P4 arrivals have already released directional occupancy before this list
-- is sorted. A capacity slot is consumed immediately by each successful entry.
phaseTransportEnter :: TxId -> SimTick -> TransportState -> InventoryTx TransportState
phaseTransportEnter tx tick original=do
  recovered<-phaseVehicleRecovery tx tick original
  foldM enter recovered ordered
  where
    ordered=map vehicleId(sortOn(\v->(vehiclePriority v,vehicleWaitingSince v,vehicleId v))[v|v<-M.elems(transportVehicles original),AtRoadNode _<-[vehiclePosition v],not(null(vehicleRoute v)),True])
    enter state ident=do
      vehicle<-lookupVehicle ident state
      case(vehiclePosition vehicle,vehicleRoute vehicle)of
        (AtRoadNode from,to:rest)->do
          let replace v=state {transportVehicles=M.insert ident v(transportVehicles state)}
              occupancy=length[()|other<-M.elems(transportVehicles state),Traversing a b _ _<-[vehiclePosition other],a==from,b==to]
          if any(\r->recoveryVehicle r==ident&&recoveryStatus r==RecoveryWorking)(M.elems(transportRecoveries state))then pure state
          else if not(vehicleHasDriver vehicle)then pure(replace vehicle {vehicleBlock=Just NoDriver})
          else if vehicleRouteRevision vehicle/=topologyRevision(transportTopology state)then pure(replace vehicle {vehicleRoute=[],vehicleBlock=Just StaleRoute})
          else case openEdge(transportTopology state)from to of
            Nothing->pure(replace vehicle {vehicleRoute=[],vehicleBlock=Just RemovedEdge})
            Just edge|occupancy>=4->pure(replace vehicle {vehicleBlock=Just Congested})
                     |otherwise->do
                consumed<-tryInventory(when(vehicleKind vehicle==Truck)(consumeFreeDetailed tx FuelBurned(Just VehicleEdge)(vehicleJob vehicle)tick(vehicleOwner vehicle)Fuel 100))
                case consumed of
                  Left MissingStock->pure(replace vehicle {vehicleBlock=Just WaitingFuel})
                  Left err->throwTx err
                  Right()->pure(replace vehicle {vehiclePosition=Traversing from to(roadCost edge)(topologyRevision(transportTopology state)),vehicleRoute=rest,vehicleBlock=Nothing})
        _->pure state

-- Called after Inventory.expireInventory in P2. A failed food delivery cannot
-- resurrect the old food or deliver newly generated waste as that food.
phaseTransportExpiry :: SimTick -> TransportState -> InventoryTx TransportState
phaseTransportExpiry tick original=do
  inventory<-get
  let brokenParents=S.toAscList(S.fromList
        ([requestId request|request<-M.elems(transportRequests original),requestStatus request==RequestOpen,quantityFor(requestId request)inventory<requestRemaining request]
        ++[parent|shipment<-M.elems(transportShipments original),shipmentStatus shipment==ShipmentCarrying,DeliveryChild parent<-[shipmentKind shipment],quantityFor(shipmentId shipment)inventory<shipmentQuantity shipment]))
  failed<-foldM failParent original brokenParents
  foldM reconcileReturn failed[shipmentId s|s<-M.elems(transportShipments failed),shipmentStatus s==ShipmentCarrying,ReturnShipment _<-[shipmentKind s]]
  where
    failParent state ident=case M.lookup ident(transportRequests state)of
      Just request|requestStatus request==RequestOpen->do
        -- First attach newly generated waste to the carried shipment so the
        -- independent Return inherits every surviving gram, including waste.
        claimed<-foldM claimWaste state[shipmentId s|s<-M.elems(transportShipments state),shipmentKind s==DeliveryChild ident,shipmentStatus s==ShipmentCarrying]
        terminateRequest tick RequestFailed request claimed
      _->pure state
    claimWaste state ident=do
      shipment<-lookupShipment ident state
      vehicle<-lookupVehicle(shipmentVehicle shipment)state
      inventory<-get
      let waste=sum[qtyValue(lotQty lot)-lotReserved inventory(lotId lot)|lot<-M.elems(invLots inventory),lotOwner lot==vehicleOwner vehicle,lotResource lot==Waste]
      when(waste>0)(reserveQuantity tick ident(vehicleOwner vehicle)Waste waste)
      lots<-gets(map lotId.cargoLots shipment)
      pure state {transportShipments=M.insert ident(shipment {shipmentLots=lots,shipmentBlock=if waste>0 then Just ExpiredCargo else shipmentBlock shipment})(transportShipments state)}
    reconcileReturn state ident=do
      claimed<-claimWaste state ident
      shipment<-lookupShipment ident claimed
      inventory<-get
      let lots=cargoLots shipment inventory
          actualWeight=sum[weightOf inventory(lotResource lot)(qtyValue(lotQty lot))|lot<-lots]
          reserved=maybe 0(\owner->capacityFor ident owner inventory)(shipmentDestination shipment)
      if actualWeight==reserved && not(null lots)then pure claimed else do
        modify' $ \s->s {invCapacity=M.filter((/=ident).capacityJob)(invCapacity s)}
        chooseReturnDestination tick ident claimed {transportShipments=M.insert ident(shipment {shipmentDestination=Nothing})(transportShipments claimed)}

validateTransport :: TransportState -> Inventory -> Either Failure ()
validateTransport state inventory=do
  validateTopology(transportTopology state)(transportPaths state)
  let check ok message=unless ok(Left(InvariantViolation message))
      vehicles=transportVehicles state
      shipments=transportShipments state
      requests=transportRequests state
      known ident=M.member ident requests||M.member ident shipments||M.member ident vehicles
      allocated=M.keys vehicles++M.keys requests++M.keys shipments++M.keys(transportRecoveries state)
  check(S.size(S.fromList allocated)==length allocated)"Transport entity IDs overlap"
  check(all(\(EntityId ident)->ident>0&&ident<invNextId inventory)allocated)"Transport allocator high-water mismatch"
  check(transportLastAssignments state<=256&&transportLastMatches state<=512)"Transport assignment/matching fuel exceeded"
  forM_(M.toList(transportPorts state))$ \(owner,node)->do
    check(M.member owner(invStorage inventory))"Transport port refers to missing owner"
    check(S.member node(roadNodes(transportTopology state)))"Transport port refers to missing node"
  forM_(M.toList(transportGroundCaches state))$ \(node,owner@(Owner kind _))->do
    check(kind==GroundCache&&M.lookup owner(transportPorts state)==Just node)"Invalid ground cache port"
  forM_(M.toList vehicles)$ \(ident,vehicle)->do
    check(ident==vehicleId vehicle)"Vehicle key mismatch"
    check(maybe False((==vehicleCapacity(vehicleKind vehicle)).storageCapacity)(M.lookup(vehicleOwner vehicle)(invStorage inventory)))"Missing/wrong vehicle storage"
    check(vehiclePriority vehicle>=0&&vehiclePriority vehicle<=3)"Invalid vehicle priority"
    check(M.member(vehicleHome vehicle)(transportPorts state)||M.member(vehicleHome vehicle)(transportRemovedPorts state))"Missing vehicle home port or tombstone"
    forM_(vehicleJob vehicle)$ \sid->check(maybe False(\s->shipmentVehicle s==ident&&not(shipmentTerminal s))(M.lookup sid shipments))"Dangling vehicle job"
    case vehiclePosition vehicle of
      AtRoadNode node->check(S.member node(roadNodes(transportTopology state)))"Vehicle outside road graph"
      Traversing from to remaining _->do
        check(maybe False(const True)(edgeBetween(transportTopology state)from to))"Vehicle edge lacks live edge or tombstone"
        check(remaining>0&&remaining<=20)"Invalid edge progress"
    let anchor=case vehiclePosition vehicle of AtRoadNode node->node;Traversing _ to _ _->to
    check(all(\(a,b)->nodeDistance a b==1)(zip(anchor:vehicleRoute vehicle)(vehicleRoute vehicle)))"Vehicle route contains teleport"
  let occupied=M.fromListWith(+)[((a,b),1::Integer)|vehicle<-M.elems vehicles,Traversing a b _ _<-[vehiclePosition vehicle]]
  check(all(<=4)(M.elems occupied))"Directed road-edge capacity exceeded"
  forM_(M.toList requests)$ \(ident,request)->do
    check(ident==requestId request&&requestQuantity request>0&&requestQuantity request<=quantityMax&&requestRemaining request>=0&&requestRemaining request<=requestQuantity request)"Invalid parent request quantity"
    check(length(requestChildren request)==S.size(S.fromList(requestChildren request)))"Duplicate child shipment"
    check(requestRouteRevision request<=topologyRevision(transportTopology state))"Request route revision is from the future"
    case requestPathResult request of
      PathFound route cost->do
        check(not(null route)&&cost>=0&&cost<=quantityMax)"Invalid request cached route"
        check(all(\(a,b)->nodeDistance a b==1)(zip route(drop 1 route)))"Request cached route contains teleport"
        when(requestRouteRevision request==topologyRevision(transportTopology state))$do
          check(M.lookup(requestSource request)(transportPorts state)==Just(head route)&&M.lookup(requestDestination request)(transportPorts state)==Just(last route))"Request cached route endpoints mismatch"
          let edges=[openEdge(transportTopology state)a b|(a,b)<-zip route(drop 1 route)]
          check(all(\edge->case edge of Just _->True;_->False)edges&&sum[roadCost edge|Just edge<-edges]==cost)"Request cached route/cost invalid"
      _->pure()
    forM_(requestChildren request)$ \sid->check(maybe False((==DeliveryChild ident).shipmentKind)(M.lookup sid shipments))"Dangling parent child"
    let active=requestStatus request==RequestOpen
        quantity=quantityFor ident inventory
        reserved=capacityFor ident(requestDestination request)inventory
    check(quantity==if active then requestRemaining request else 0)"Parent quantity reservation double-count or missing"
    check(reserved==if active then weightOf inventory(requestResource request)(requestRemaining request)else 0)"Parent destination capacity mismatch"
    when active $ check(requestRemaining request+sum[shipmentQuantity child|sid<-requestChildren request,Just child<-[M.lookup sid shipments]]==requestQuantity request)"Parent/child quantity conservation"
  forM_(M.toList shipments)$ \(ident,shipment)->do
    check(ident==shipmentId shipment&&M.member(shipmentVehicle shipment)vehicles)"Shipment key or vehicle missing"
    case shipmentKind shipment of
      DeliveryChild parent->check(M.member parent requests)"Shipment parent missing"
      ReturnShipment previous->check(maybe False((==ShipmentTransferred ident).shipmentStatus)(M.lookup previous shipments))"Return ownership transfer missing"
    let quantity=quantityFor ident inventory
        lots=cargoLots shipment inventory
        owned=Owner Vehicle(shipmentVehicle shipment)
    if shipmentTerminal shipment then do
      check(quantity==0&&all((/=ident).capacityJob)(M.elems(invCapacity inventory)))"Terminal shipment retains reservations"
      case shipmentStatus shipment of
        ShipmentTransferred rid->check(maybe False((==ReturnShipment ident).shipmentKind)(M.lookup rid shipments))"Dangling Return transfer"
        _->pure()
    else do
      check(maybe False((==Just ident).vehicleJob)(M.lookup(shipmentVehicle shipment)vehicles))"Active shipment lost vehicle"
      case shipmentStatus shipment of
        ShipmentReserved->check(quantity==shipmentQuantity shipment)"Unloaded child quantity mismatch"
        ShipmentCarrying->do
          check(all((==owned).lotOwner)lots)"Cargo reservation points outside vehicle"
          check(S.fromList(shipmentLots shipment)==S.fromList(map lotId lots))"Shipment cargo manifest differs from physical lots"
          case shipmentKind shipment of
            DeliveryChild _->check(quantity==shipmentQuantity shipment&&all((==shipmentResource shipment).lotResource)lots)"Delivery cargo quantity/resource mismatch"
            ReturnShipment _->pure()
        _->pure()
  forM_(M.keys(pathSearches(transportPaths state)))$ \ident->check(known ident)"Path search owner missing"
  forM_(M.toList(transportRecoveries state))$ \(ident,recovery)->do
    check(ident==recoveryId recovery&&M.member(recoveryVehicle recovery)vehicles)"Recovery identity/vehicle missing"
    check(recoveryProgress recovery>=0&&recoveryProgress recovery<=60000)"Recovery work credit invalid"
    check(M.member(recoveryEscrow recovery)(invStorage inventory))"Recovery escrow missing"
    let escrowLots=[lot|lot<-M.elems(invLots inventory),lotOwner lot==recoveryEscrow recovery]
    if recoveryStatus recovery==RecoveryWorking
      then check(sum[qtyValue(lotQty lot)|lot<-escrowLots,lotResource lot==Fuel]==1000&&all((==Fuel).lotResource)escrowLots)"Recovery fuel WIP mismatch"
      else check(null escrowLots)"Terminal recovery retains fuel"
  let activeRecoveryVehicles=[recoveryVehicle r|r<-M.elems(transportRecoveries state),recoveryStatus r==RecoveryWorking]
  check(length activeRecoveryVehicles==S.size(S.fromList activeRecoveryVehicles))"Vehicle has duplicate rescue crew"

-- Building deletion calls this after its owner/stock transaction is complete.
-- Old request/home references remain typed removed-port references, not dangling.
retireTransportPort :: BoundarySeq -> Owner -> TransportState -> InventoryTx TransportState
retireTransportPort boundary owner state=do
  exists<-gets(M.member owner.invStorage)
  require(not exists)(InvalidReference "Retire port after storage deletion")
  pure state {transportPorts=M.delete owner(transportPorts state),transportRemovedPorts=M.insert owner boundary(transportRemovedPorts state),transportGroundCaches=M.filter(/=owner)(transportGroundCaches state)}

recoveryAnchor :: VehiclePosition -> RoadNode
recoveryAnchor(AtRoadNode node)=node
recoveryAnchor(Traversing from _ _ _)=from

-- This is the explicitly specified crew recovery operation, not a pathfinding
-- shortcut. Its 600 ticks and fuel escrow remain visible/persisted throughout.
startVehicleRecovery :: SimTick -> EntityId -> Owner -> Bool -> TransportState -> InventoryTx (EntityId,TransportState)
startVehicleRecovery tick ident fuelSource crew state=do
  vehicle<-lookupVehicle ident state
  require crew(InvalidReference "NoRescueCrew")
  require(not(any(\r->recoveryVehicle r==ident&&recoveryStatus r==RecoveryWorking)(M.elems(transportRecoveries state))))(InvalidReference "Vehicle already recovering")
  let anchor=recoveryAnchor(vehiclePosition vehicle)
      candidates=sortOn(\node->(nodeDistance anchor node,node))
        [node|node<-S.toList(roadNodes(transportTopology state)),nodeDistance anchor node<=16,not(null(roadNeighbours(transportTopology state)node))]
  target<-case candidates of []->throwTx NoRecoveryNode;node:_->pure node
  rid<-freshId
  let escrow=Owner ConstructionEscrow rid
  addStorage escrow(Storage 1000(Just Fuel)(vehicleColony vehicle))
  moveFree tick fuelSource escrow Fuel 1000
  let recovery=VehicleRecovery rid ident target escrow fuelSource 0 RecoveryWorking True
  pure(rid,state {transportRecoveries=M.insert rid recovery(transportRecoveries state)})

phaseVehicleRecovery :: TxId -> SimTick -> TransportState -> InventoryTx TransportState
phaseVehicleRecovery tx tick original=foldM work original(M.keys(transportRecoveries original))
  where
    work state ident=case M.lookup ident(transportRecoveries state)of
      Just recovery|recoveryStatus recovery==RecoveryWorking&&recoveryHasCrew recovery->do
        let progress=min 60000(recoveryProgress recovery+100)
        if progress<60000 then pure state {transportRecoveries=M.insert ident(recovery {recoveryProgress=progress})(transportRecoveries state)}else do
          -- If the reserved rescue node was closed meanwhile, remain in WIP.
          if null(roadNeighbours(transportTopology state)(recoveryTarget recovery))then pure state {transportRecoveries=M.insert ident(recovery {recoveryProgress=progress})(transportRecoveries state)}else do
            consumeFree tx RescueFuelConsumed(Just ident)tick(recoveryEscrow recovery)Fuel 1000
            let completed=recovery {recoveryProgress=progress,recoveryStatus=RecoveryCompleted}
                moved=state {transportRecoveries=M.insert ident completed(transportRecoveries state),transportVehicles=M.adjust(\v->v {vehiclePosition=AtRoadNode(recoveryTarget recovery),vehicleRoute=[],vehicleRouteRevision=topologyRevision(transportTopology state),vehicleBlock=Nothing,vehicleWaitingSince=tick})(recoveryVehicle recovery)(transportVehicles state),transportPaths=dropPath(recoveryVehicle recovery)(transportPaths state)}
            ensureVehicleRoute tick(recoveryVehicle recovery)moved
      _->pure state

cancelVehicleRecovery :: TxId -> SimTick -> EntityId -> TransportState -> InventoryTx TransportState
cancelVehicleRecovery tx tick ident state=do
  recovery<-maybe(throwTx TargetGone)pure(M.lookup ident(transportRecoveries state))
  require(recoveryStatus recovery==RecoveryWorking)AlreadyTerminal
  let lost=1000*recoveryProgress recovery `div` 60000
      returned=1000-lost
  outcome<-tryInventory $ do
    when(lost>0)(consumeFree tx CancelledProcessLoss(Just ident)tick(recoveryEscrow recovery)Fuel lost)
    when(returned>0)(moveFree tick(recoveryEscrow recovery)(recoveryFuelSource recovery)Fuel returned)
  case outcome of
    Left NoCapacity->throwTx ReturnCapacityFull
    Left err->throwTx err
    Right()->pure state {transportRecoveries=M.insert ident(recovery {recoveryStatus=RecoveryCancelled})(transportRecoveries state)}

-- Manual refuelling is a local physical transfer, never a remote warehouse read.
refuelTransportVehicle :: SimTick -> EntityId -> Owner -> Integer -> TransportState -> InventoryTx TransportState
refuelTransportVehicle tick ident fuelSource quantity state=do
  vehicle<-lookupVehicle ident state
  require(vehicleKind vehicle==Truck&&quantity>0)InvalidQuantity
  fuelNode<-port fuelSource state
  require(vehiclePosition vehicle==AtRoadNode fuelNode)(InvalidReference "Refuel source is not at vehicle node")
  moveFree tick fuelSource(vehicleOwner vehicle)Fuel quantity
  pure state {transportVehicles=M.insert ident(vehicle {vehicleBlock=Nothing})(transportVehicles state)}

-- Recovery ownership is never cancelled; the user may select another actual
-- warehouse. Old and new capacity reservations change in one transaction.
changeReturnDestination :: SimTick -> EntityId -> Owner -> TransportState -> InventoryTx TransportState
changeReturnDestination tick ident destination state=do
  shipment<-lookupShipment ident state
  case shipmentKind shipment of ReturnShipment _->pure();_->throwTx(InvalidReference "Not a Return shipment")
  require(shipmentStatus shipment==ShipmentCarrying)AlreadyTerminal
  let Owner kind _=destination
  require(kind==Warehouse)(InvalidReference "Return target must be a warehouse")
  _<-port destination state
  modify' $ \s->s {invCapacity=M.filter((/=ident).capacityJob)(invCapacity s)}
  let cleared=state {transportVehicles=M.adjust(\v->v {vehicleRoute=[],vehicleBlock=Nothing,vehicleWaitingSince=tick})(shipmentVehicle shipment)(transportVehicles state),transportPaths=dropPath(shipmentVehicle shipment)(transportPaths state)}
  reserveDestination tick shipment destination cleared
