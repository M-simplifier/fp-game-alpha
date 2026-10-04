{-# LANGUAGE BangPatterns #-}
module TransportTests (transportTests) where

import Colony.Codec
import Colony.World
import Colony.Content
import Colony.Inventory
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Control.Monad (foldM, forM_, unless, void)
import Control.Monad.State.Strict (modify')
import Data.Bits (testBit)
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import Text.Read (readMaybe)

assert :: String -> Bool -> IO ()
assert label pass=unless pass(ioError(userError("Transport assertion: "++label)))
must :: Show e => String -> Either e a -> IO a
must label=either(ioError.userError.((label++": ")++).show)pure
node :: Integer -> Integer -> RoadNode
node x y=either(error.show)id(roadNode x y)
eid :: Word64 -> EntityId
eid=EntityId
at :: Word64 -> SimTick
at=SimTick
tx :: Word64 -> TxId
tx n=TxId 1 1(BoundarySeq n)P7 4096
source,destination,other :: Owner
source=Owner Warehouse(eid 101)
destination=Owner Warehouse(eid 102)
other=Owner Warehouse(eid 103)

fixture :: Content -> VehicleKind -> Integer -> Maybe SimTick -> Resource -> Integer -> IO (EntityId,EntityId,TransportState,Inventory)
fixture content kind quantity expires resource destinationCapacity=do
  topology<-must "line roads"(foldM(\t(a,b)->setRoad(BoundarySeq 0)a b 10 True t)emptyTopology[(node 10 10,node 11 10),(node 11 10,node 12 10)])
  ((vid,rid,state),inventory)<-must "fixture inventory"$runInventory(do
    addStorage source(Storage 2000000 Nothing(eid 1))
    addStorage destination(Storage destinationCapacity Nothing(eid 2))
    addStorage other(Storage 2000000 Nothing(eid 1))
    void(mintLot(tx 0)InitialGrant Nothing resource quantity source(at 0)expires "cargo")
    void(mintLot(tx 0)InitialGrant Nothing Fuel 20000 source(at 0)Nothing "engine fuel")
    ports<-foldM(\s(o,n)->addTransportPort o n s)(emptyTransport {transportTopology=topology})[(source,node 10 10),(destination,node 12 10),(other,node 11 10)]
    (vid,vehicles)<-addTransportVehicle kind(eid 1)source source(node 10 10)(at 0)ports
    (rid,requested)<-planDelivery(at 0)source destination resource quantity 2 vehicles
    pure(vid,rid,requested))(emptyInventory content)
  must "initial transport validation"(validateTransport state inventory)
  pure(vid,rid,state,inventory)

step :: Word64 -> (TransportState,Inventory) -> IO (TransportState,Inventory)
step tick(before,inventory)=do
  (after,next)<-must("tick "++show tick)$runInventory(do
    void(expireInventory(tx tick)(at tick))
    expired<-phaseTransportExpiry(at tick)before
    paths<-either throwTx pure(phaseTransportPaths(at tick)expired)
    arrived<-phaseTransportArrival(at tick)paths
    assigned<-phaseTransportAssign(at tick)arrived
    phaseTransportEnter(tx tick)(at tick)assigned)inventory
  must("validate tick "++show tick)(validateTransport after next)
  pure(after,next)
runTicks :: Word64 -> Word64 -> (TransportState,Inventory) -> IO (TransportState,Inventory)
runTicks from through initial=foldM(flip step)initial[from..through]

physical :: Owner -> Resource -> Inventory -> Integer
physical owner resource inventory=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots inventory),lotOwner lot==owner,lotResource lot==resource]
parent :: EntityId -> TransportState -> DeliveryRequest
parent ident state=transportRequests state M.!ident
vehicle :: EntityId -> TransportState -> TransportVehicle
vehicle ident state=transportVehicles state M.!ident

-- Independent Integer all-pairs relaxation. No production path function,
-- neighbor enumeration, search frontier or path-reconstruction helper is used.
oracleRoute :: [(RoadNode,RoadNode,Integer)] -> RoadNode -> RoadNode -> PathResult
oracleRoute edges src dst=case M.lookup dst distances of
  Nothing->PathUnavailable
  Just cost->PathFound(build dst [])cost
  where
    arcs=concat[[(a,b,c),(b,a,c)]|(a,b,c)<-edges]
    relax costs=foldl(\m(a,b,c)->case M.lookup a costs of Nothing->m;Just n->M.insertWith min b(n+c)m)costs arcs
    settle costs=let next=relax costs in if next==costs then costs else settle next
    distances=settle(M.singleton src 0)
    build n suffix|n==src=src:suffix
                  |otherwise=let candidates=[a|(a,b,c)<-arcs,b==n,Just x<-[M.lookup a distances],Just y<-[M.lookup n distances],x+c==y]
                             in build(minimum candidates)(n:suffix)

pathTests :: IO ()
pathTests=do
  assert "negative coordinate rejected"(roadNode(-1)0==Left(InvalidReference "Road coordinate outside 512x512 world"))
  assert "diagonal edge rejected"(case setRoad(BoundarySeq 0)(node 0 0)(node 1 1)10 True emptyTopology of Left _->True;_->False)
  let nodes=[node x y|y<-[0..1],x<-[0..2]]
      allEdges=[(node x y,node(x+1)y,if even(x+y)then 10 else 20)|y<-[0..1],x<-[0..1]]++[(node x 0,node x 1,10)|x<-[0..2]]
  forM_[0..127::Integer]$ \mask->do
    let edges=[edge|(index,edge)<-zip[0..]allEdges,testBit mask index]
    topology<-must "oracle topology"(foldM(\t(a,b,c)->setRoad(BoundarySeq 0)a b c True t)emptyTopology edges)
    forM_[(a,b)|a<-nodes,b<-nodes]$ \(a,b)->do
      actual<-must "reference path"(referencePath topology a b)
      assert("independent path oracle "++show(mask,a,b))(actual==oracleRoute edges a b)
  let snake=[node x y|y<-[0..19],x<-if even y then[0..511]else reverse[0..511]]
  topology<-must "large winding actual graph"(foldM(\t(a,b)->setRoad(BoundarySeq 0)a b 20 True t)emptyTopology(zip snake(drop 1 snake)))
  queue<-must "enqueue long path"(requestPath topology(eid 1)(head snake)(last snake)2(at 0)emptyPathQueue)
  partial<-must "8192 search budget"(advancePaths(at 1)topology queue)
  assert "exact8192 node expansion budget"(pathLastWork partial==8192&&pathResult(pathSearches partial M.!eid 1)==PathSearching)
  let persisted=readMaybe(show partial)::Maybe PathQueue
  assert "frontier cursor complete read suffix"(persisted==Just partial)
  done<-must "resume long search"(advancePaths(at 2)topology partial)
  assert "no fake Manhattan distance"(case pathResult(pathSearches done M.!eid 1)of PathFound route cost->route==snake&&cost==204780;_->False)
  queue2<-must "roundrobin second request"(requestPath topology(eid 2)(head snake)(last snake)2(at 0)queue)
  quantum<-must "roundrobin work"(advancePaths(at 1)topology queue2)
  assert "256 quantum fairly shares8192"(map pathExpanded(M.elems(pathSearches quantum))==[4096,4096])
  closed<-must "close route"(closeRoad(BoundarySeq 2)(snake!!100)(snake!!101)topology)
  stale<-must "stale rev restart"(advancePaths(at 3)closed done)
  assert "stale found route discarded"(pathRevision(pathSearches stale M.!eid 1)==topologyRevision closed&&pathResult(pathSearches stale M.!eid 1)==PathUnavailable)
  let full=emptyPathQueue {pathSearches=M.fromList[(eid ident,newPath topology(eid ident)(head snake)(last snake)2(at 0))|ident<-[1..4096]]}
  assert "path queue bounded"(requestPath topology(eid 4097)(head snake)(last snake)2(at 0)full==Left PathQueueFull)
  putStrLn "Transport paths: 4608 independent oracle route comparisons; 8192/256 fuel, persisted frontier/cursor, stale restart and queue limit passed"

splitFuelTests :: Content -> IO ()
splitFuelTests content=do
  (vid,rid,start,inventory)<-fixture content Truck 350000 Nothing Water 1000000
  (loaded,carrying)<-step 1(start,inventory)
  let request=parent rid loaded
      child=transportShipments loaded M.!head(requestChildren request)
      own=Owner Vehicle vid
  assert "fuel contributes to payload"(shipmentQuantity child==299520&&physical own Fuel carrying==380&&heldWeight carrying own==299900)
  assert "parent+child source reservation once"(requestRemaining request==50480&&quantityFor rid carrying==50480&&quantityFor(shipmentId child)carrying==299520)
  assert "capacity ownership split once"(capacityFor rid destination carrying+capacityFor(shipmentId child)destination carrying==350000)
  assert "no teleport on assignment"(physical destination Water carrying==0&&vehiclePosition(vehicle vid loaded)==Traversing(node 10 10)(node 11 10)10(topologyRevision(transportTopology loaded)))
  (arrived,delivered)<-runTicks 2 21(loaded,carrying)
  assert "actual twoedge delivery"(physical destination Water delivered==299520&&requestStatus(parent rid arrived)==RequestOpen)
  (finished,finalInventory)<-runTicks 22 85(arrived,delivered)
  assert "multi-shipment finite completion and drive home"(requestStatus(parent rid finished)==RequestCompleted&&physical destination Water finalInventory==350000&&vehiclePosition(vehicle vid finished)==AtRoadNode(node 10 10))
  assert "physical fuel per enterededge"(M.findWithDefault 0(Fuel,FuelBurned)(invLedger finalInventory)==800)
  let edgeBurns=[entry|entry<-invRecentLedger finalInventory,ledgerReason entry==FuelBurned]
  assert "VehicleEdge ledger detail golden"(length edgeBurns==8&&all(\entry->ledgerSubreason entry==Just VehicleEdge&&ledgerQuantity entry==100)edgeBurns)
  assert "ordinary no capacity request rolls back"(case runInventory(planDelivery(at 85)source destination Water 1 2 finished)finalInventory of Left MissingStock->True;_->False)
  putStrLn "Transport split/fuel: parent-child ownership, 300000g including fuel, eight physical edges, two atomic shipments and depot return passed"

cancelArrivalTests :: Content -> IO ()
cancelArrivalTests content=do
  (vid,rid,start,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (near,carrying)<-runTicks 1 20(start,inventory)
  assert "arrival fixture is actual finaledge remaining1"(case vehiclePosition(vehicle vid near)of Traversing a b 1 _->a==node 11 10&&b==node 12 10;_->False)
  (cancelled,cancelInventory)<-must "P1 sameboundary cancellation"(runInventory(cancelDelivery(at 21)rid near)carrying)
  let returns=[s|s<-M.elems(transportShipments cancelled),ReturnShipment _<-[shipmentKind s]]
  assert "separate return ID"(length returns==1&&shipmentId(head returns)/=head(requestChildren(parent rid cancelled)))
  assert "Return cannot be cancelled"(case runInventory(cancelDelivery(at 21)(shipmentId(head returns))cancelled)cancelInventory of Left CannotCancelRecovery->True;_->False)
  (atCancelled,afterArrival)<-step 21(cancelled,cancelInventory)
  assert "P1cancel/P4arrival never delivers"(physical destination Water afterArrival==0&&physical(Owner Vehicle vid)Water afterArrival==10000&&requestStatus(parent rid atCancelled)==RequestCancelled)
  (returned,restored)<-runTicks 22 45(atCancelled,afterArrival)
  assert "Return real route restores source"(physical source Water restored==10000&&all((==ShipmentReturned).shipmentStatus)[s|s<-M.elems(transportShipments returned),ReturnShipment _<-[shipmentKind s]])
  assert "Return completion cannot overwrite cancelled parent"(requestStatus(parent rid returned)==RequestCancelled)
  putStrLn "Transport cancellation: actual P1cancel/P4arrival boundary, independent un-cancellable Return and retained cancelled parent passed"

expiryTests :: Content -> IO ()
expiryTests content=do
  (vid,rid,start,inventory)<-fixture content CarrierCart 10000(Just(at 6))Crops 1000000
  (expired,afterExpiry)<-runTicks 1 6(start,inventory)
  assert "invehicle expiry no food resurrection"(physical(Owner Vehicle vid)Crops afterExpiry==0&&physical(Owner Vehicle vid)Waste afterExpiry==10000)
  assert "expired delivery parent fails"(requestStatus(parent rid expired)==RequestFailed&&capacityFor rid destination afterExpiry==0)
  assert "expired child destination capacity released"(all((/=destination).capacityOwner)(M.elems(invCapacity afterExpiry)))
  (returned,afterReturn)<-runTicks 7 35(expired,afterExpiry)
  assert "waste is physically returned"(physical source Waste afterReturn==10000&&physical destination Crops afterReturn==0&&physical destination Waste afterReturn==0)
  assert "spoilage ledger exact"(M.findWithDefault 0(Crops,SpoilageInput)(invLedger afterReturn)==10000&&M.findWithDefault 0(Waste,SpoilageOutput)(invLedger afterReturn)==10000)
  assert "failed parent not rewritten"(requestStatus(parent rid returned)==RequestFailed)
  putStrLn "Transport expiry: cargo spoilage ledger, surviving waste ownership, Return path and no false delivery passed"

closureCapacityTests :: Content -> IO ()
closureCapacityTests content=do
  (vid,rid,start,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (moving,loaded)<-step 1(start,inventory)
  closed<-must "edge closure"(closeRoad(BoundarySeq 2)(node 10 10)(node 11 10)(transportTopology moving))
  let shut=moving {transportTopology=closed}
  (stalled,stillOwned)<-runTicks 2 12(shut,loaded)
  assert "closededge freezes remaining duration"(vehiclePosition(vehicle vid stalled)==vehiclePosition(vehicle vid moving)&&vehicleBlock(vehicle vid stalled)==Just RemovedEdge)
  assert "closededge retains physical cargo"(physical(Owner Vehicle vid)Water stillOwned==10000)
  checkpoint<-must "closededge canonical checkpoint"(encodeCheckpoint defaultCheckpointMeta(initialWorld content) {worldInventory=stillOwned,worldTransport=stalled,simTick=at 12,boundarySeq=BoundarySeq 12})
  (_,reloaded)<-must "closededge canonical reload"(decodeCheckpoint checkpoint)
  let persisted=(worldTransport reloaded,worldInventory reloaded)
  assert "canonical closededge payload preserves authoritative state"(persisted==(stalled,stillOwned))
  reopened<-must "reopen exact tombstone"(reopenRoad(BoundarySeq 13)(node 10 10)(node 11 10)(transportTopology stalled))
  let resume(s,i)=(s {transportTopology=reopened},i)
  outcomeA<-runTicks 13 45(resume(stalled,stillOwned))
  outcomeB<-runTicks 13 45(resume persisted)
  assert "closure save/reload suffix identical"(outcomeA==outcomeB&&requestStatus(parent rid(fst outcomeA))==RequestCompleted)
  (v2,r2,s2,i2)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (near,invNear)<-runTicks 1 20(s2,i2)
  let sid=head(requestChildren(parent r2 near))
  (_,missing)<-must "remove destination reservation adversarially"(runInventory(modify'(\i->i {invCapacity=M.filter((/=sid).capacityJob)(invCapacity i)}))invNear)
  (blocked,unchanged)<-step 21(near,missing)
  assert "missing capacity cannot discard load"(physical(Owner Vehicle v2)Water unchanged==10000&&physical destination Water unchanged==0&&vehicleBlock(vehicle v2 blocked)==Just DestinationCapacityLost)
  (_,repaired)<-must "repair capacity"(runInventory(reserveCapacity sid destination Water 10000)unchanged)
  (accepted,acceptedInventory)<-step 22(blocked,repaired)
  assert "capacity repair atomically accepts all"(requestStatus(parent r2 accepted)==RequestCompleted&&physical destination Water acceptedInventory==10000)
  putStrLn "Transport closure/capacity: tombstone pause/resume, saved suffix and missing-reservation no-loss repair passed"

congestionTests :: Content -> IO ()
congestionTests content=do
  (_,rid,start,inventory)<-fixture content CarrierCart 300000 Nothing Water 1000000
  (fleet,withFleet)<-must "five additional real carts"$runInventory(foldM(\s _->snd <$> addTransportVehicle CarrierCart(eid 1)source source(node 10 10)(at 0)s)start[1..5::Integer])inventory
  (jam,loaded)<-runTicks 1 6(fleet,withFleet)
  let entered=[v|v<-M.elems(transportVehicles jam),Traversing a b _ _<-[vehiclePosition v],a==node 10 10,b==node 11 10]
      waiting=[v|v<-M.elems(transportVehicles jam),vehicleBlock v==Just Congested]
  assert "four directional slots only"(length entered==4&&length waiting==2)
  assert "queue ordering stable ids"(map vehicleId entered<map vehicleId waiting)
  (flow,afterFlow)<-runTicks 7 40(jam,loaded)
  assert "congested queue drains"(requestStatus(parent rid flow)==RequestCompleted&&physical destination Water afterFlow==300000)
  putStrLn "Transport congestion: six carts, directed capacity four, stable queue and finite drain passed"

recoveryTests :: Content -> IO ()
recoveryTests content=do
  (vid,_,start,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (moving,carrying)<-step 1(start,inventory)
  closed<-must "recovery road closure"(closeRoad(BoundarySeq 2)(node 10 10)(node 11 10)(transportTopology moving))
  let stalled=moving {transportTopology=closed}
  ((recoveryId',recovering),escrowed)<-must "start real recovery"(runInventory(startVehicleRecovery(at 2)vid source True stalled)carrying)
  assert "rescue fuel enters escrow before work"(physical(Owner ConstructionEscrow recoveryId')Fuel escrowed==1000)
  (working,workInventory)<-runTicks 2 600(recovering,escrowed)
  assert "599ticks no teleport"(vehiclePosition(vehicle vid working)==vehiclePosition(vehicle vid stalled)&&recoveryProgress(transportRecoveries working M.!recoveryId')==59900)
  (done,after)<-step 601(working,workInventory)
  assert "600ticks exact rescue completion"(recoveryStatus(transportRecoveries done M.!recoveryId')==RecoveryCompleted&&vehiclePosition(vehicle vid done)==AtRoadNode(node 11 10))
  assert "rescue moves cargo without source/sink"(physical(Owner Vehicle vid)Water after==10000&&M.findWithDefault 0(Fuel,RescueFuelConsumed)(invLedger after)==1000)
  ((rescue,cancelling),escrow2)<-must "start cancellable recovery"(runInventory(startVehicleRecovery(at 2)vid source True stalled)carrying)
  (half,halfInventory)<-runTicks 2 301(cancelling,escrow2)
  (cancelled,restored)<-must "cancel half rescue"(runInventory(cancelVehicleRecovery(tx 302)(at 302)rescue half)halfInventory)
  assert "halfwork recovery cancellation exact loss"(recoveryStatus(transportRecoveries cancelled M.!rescue)==RecoveryCancelled&&M.findWithDefault 0(Fuel,CancelledProcessLoss)(invLedger restored)==500&&physical(Owner ConstructionEscrow rescue)Fuel restored==0)
  putStrLn "Transport recovery: nearest active road, real600 work,1000g escrow/sink, no asset remint, proportional cancel passed"

returnCapacityTests :: Content -> IO ()
returnCapacityTests content=do
  (vid,rid,start,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (moving,loaded)<-step 1(start,inventory)
  (_,full)<-must "fill source after cargo departed"(runInventory(void(mintLot(tx 2)InitialGrant Nothing Stone 1980000 source(at 2)Nothing "test source full"))loaded)
  (cancelled,held)<-must "cancel keeps cargo without return capacity"(runInventory(cancelDelivery(at 2)rid moving)full)
  (blocked,stillHeld)<-runTicks 2 15(cancelled,held)
  assert "NoReturnCapacity preserves vehicle cargo"(physical(Owner Vehicle vid)Water stillHeld==10000&&vehicleBlock(vehicle vid blocked)==Just NoReturnCapacity)
  assert "ordinary cancel never hides cargo in RecoveryHold"(all(\lot->let Owner kind _=lotOwner lot in kind/=RecoveryHold)(M.elems(invLots stillHeld)))
  let returnId=head[shipmentId shipment|shipment<-M.elems(transportShipments blocked),ReturnShipment _<-[shipmentKind shipment]]
  (retargeted,newCapacity)<-must "explicit Return warehouse change"(runInventory(changeReturnDestination(at 16)returnId other blocked)stillHeld)
  (retargetDone,retargetStock)<-step 16(retargeted,newCapacity)
  assert "Return may retarget, cannot cancel"(physical other Water retargetStock==10000&&requestStatus(parent rid retargetDone)==RequestCancelled&&physical source Water retargetStock==0)
  (_,space)<-must "make return space"(runInventory(consumeFree(tx 16)ConstructionConsumed Nothing(at 16)source Stone 10000)stillHeld)
  (returned,restored)<-runTicks 16 40(blocked,space)
  assert "NoReturnCapacity repairs without loss"(physical source Water restored==10000&&requestStatus(parent rid returned)==RequestCancelled)
  -- Remove a now-empty source storage through its typed removed-port API.
  -- Its unrelated fuel is left in a cache on the identical source tile.
  (v2,r2,s2,i2)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (moving2,loaded2)<-step 1(s2,i2)
  (removed,deleted)<-must "source owner removed, assets cached at same tile"$runInventory(do
    cacheId<-freshId
    let cache=Owner GroundCache cacheId
    addStorage cache(Storage 2000000 Nothing(eid 1))
    moveFree(at 2)source cache Fuel 20000
    modify'(\i->i {invStorage=M.delete source(invStorage i)})
    retired<-retireTransportPort(BoundarySeq 2)source moving2
    let cached=retired {transportPorts=M.insert cache(node 10 10)(transportPorts retired),transportGroundCaches=M.insert(node 10 10)cache(transportGroundCaches retired)}
    cancelDelivery(at 2)r2 cached)loaded2
  (fallback,received)<-runTicks 2 15(removed,deleted)
  assert "deleted source Return picks samecolony minimum warehouse"(physical other Water received==10000&&physical(Owner Vehicle v2)Water received==0&&requestStatus(parent r2 fallback)==RequestCancelled)
  -- With no warehouse room, a Return waits until an arrival node exists and
  -- creates the node's bounded GroundCache, never an unbounded RecoveryHold.
  (v3,r3,s3,i3)<-fixture content CarrierCart 10000 Nothing Water 1000000
  (moving3,loaded3)<-step 1(s3,i3)
  (removed3,deleted3)<-must "source removed and warehouse full"$runInventory(do
    cacheId<-freshId
    let cache=Owner GroundCache cacheId
    addStorage cache(Storage 2000000 Nothing(eid 1))
    moveFree(at 2)source cache Fuel 20000
    void(mintLot(tx 2)InitialGrant Nothing Stone 2000000 other(at 2)Nothing "warehouse full")
    modify'(\i->i {invStorage=M.delete source(invStorage i)})
    retired<-retireTransportPort(BoundarySeq 2)source moving3
    let cached=retired {transportPorts=M.insert cache(node 10 10)(transportPorts retired),transportGroundCaches=M.insert(node 10 10)cache(transportGroundCaches retired)}
    cancelDelivery(at 2)r3 cached)loaded3
  (cached,cachedInventory)<-runTicks 2 15(removed3,deleted3)
  assert "Return GroundCache is at actual arrival node"(case M.lookup(node 11 10)(transportGroundCaches cached)of Just cache->physical cache Water cachedInventory==10000&&physical(Owner Vehicle v3)Water cachedInventory==0;_->False)
  putStrLn "Transport Return capacity: full-source hold/repair, deleted-source warehouse selection and bounded arrival-node cache passed"

waitingRepairTests :: Content -> IO ()
waitingRepairTests content=do
  (vid,rid,start,inventory)<-fixture content Truck 10000 Nothing Water 1000000
  (_,fuelAtMiddle)<-must "local emergency fuel supply"(runInventory(void(mintLot(tx 0)InitialGrant Nothing Fuel 1000 other(at 0)Nothing "middle port fuel"))inventory)
  (moving,loaded)<-step 1(start,fuelAtMiddle)
  (_,drained)<-must "fault injection exhaust engine fuel only"(runInventory(consumeFree(tx 2)FuelBurned Nothing(at 2)(Owner Vehicle vid)Fuel 380)loaded)
  (waiting,held)<-runTicks 2 12(moving,drained)
  assert "WaitingFuel is at node and keeps cargo"(vehiclePosition(vehicle vid waiting)==AtRoadNode(node 11 10)&&vehicleBlock(vehicle vid waiting)==Just WaitingFuel&&physical(Owner Vehicle vid)Water held==10000)
  assert "remote refuel cannot teleport fuel"(case runInventory(refuelTransportVehicle(at 13)vid source 100 waiting)held of Left(InvalidReference _)->True;_->False)
  (refuelled,supplied)<-must "sameport physical refuel"(runInventory(refuelTransportVehicle(at 13)vid other 400 waiting)held)
  (delivered,after)<-runTicks 13 35(refuelled,supplied)
  assert "fuel repair resumes real edge"(requestStatus(parent rid delivered)==RequestCompleted&&physical destination Water after==10000)
  (_,r2,s2,i2)<-fixture content CarrierCart 10000 Nothing Water 1000000
  closed<-must "remove only route"(closeRoad(BoundarySeq 1)(node 10 10)(node 11 10)(transportTopology s2))
  (unreachable,reserved)<-runTicks 1 5(s2 {transportTopology=closed},i2)
  assert "NoRoute search terminates without consuming stock"(requestBlock(parent r2 unreachable)==Just NoRoute&&physical source Water reserved==10000)
  reopened<-must "reopen route for waiting request"(reopenRoad(BoundarySeq 6)(node 10 10)(node 11 10)closed)
  (available,completed)<-runTicks 6 30(unreachable {transportTopology=reopened},reserved)
  assert "topology repair restarts stale request"(requestStatus(parent r2 available)==RequestCompleted&&physical destination Water completed==10000)
  let allClosed=closed {roadEdges=M.map(\edge->edge {roadOpen=False,roadClosedAt=Just(BoundarySeq 6)})(roadEdges closed)}
      noNodes=s2 {transportTopology=allClosed}
  assert "no recovery node is explicit and unchanged"(case runInventory(startVehicleRecovery(at 1)(head(M.keys(transportVehicles noNodes)))source True noNodes)i2 of Left NoRecoveryNode->True;_->False)
  putStrLn "Transport repair: typed WaitingFuel/NoRoute, local-only refuel, closure reopen and no recovery-node rejection passed"

canonicalFrontierTests :: Content -> IO ()
canonicalFrontierTests content=do
  (vid,rid,base,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
  let snake=[node x y|y<-[0..19],x<-if even y then[0..511]else reverse[0..511]]
  topology<-must "canonical frontier graph"(foldM(\t(a,b)->setRoad(BoundarySeq 0)a b 20 True t)emptyTopology(zip snake(drop 1 snake)))
  queue<-must "canonical frontier request"(requestPath topology rid(head snake)(last snake)2(at 0)emptyPathQueue)
  partial<-must "canonical frontier partial8192"(advancePaths(at 1)topology queue)
  let state=base {transportTopology=topology,transportPaths=partial,transportPorts=M.fromList[(source,head snake),(destination,last snake),(other,head snake)],transportVehicles=M.adjust(\v->v {vehiclePosition=AtRoadNode(head snake),vehicleRouteRevision=topologyRevision topology})vid(transportVehicles base)}
      world=(initialWorld content) {worldTransport=state,worldInventory=inventory,simTick=at 1,boundarySeq=BoundarySeq 1}
  bytes<-must "frontier canonical save"(encodeCheckpoint defaultCheckpointMeta world)
  (_,loaded)<-must "frontier canonical load"(decodeCheckpoint bytes)
  direct<-must "frontier direct suffix"(phaseTransportPaths(at 2)state)
  replayed<-must "frontier saved suffix"(phaseTransportPaths(at 2)(worldTransport loaded))
  assert "canonical frontier costs/parents/open/closed/cursor retained"(world==loaded&&direct==replayed)
  putStrLn "Transport canonical persistence: partial8192-node frontier/cursor and full resumed suffix passed"

matchingBudgetTests :: Content -> IO ()
matchingBudgetTests content=do
  (_,_,base,inventory)<-fixture content CarrierCart 1 Nothing Water 1000000
  (many,stocks)<-must "bounded matching fixture"$runInventory(do
    carts<-foldM(\s _->snd <$> addTransportVehicle CarrierCart(eid 1)source source(node 10 10)(at 0)s)base[1..32::Integer]
    forM_(M.elems(transportVehicles carts))$ \v->void(mintLot(tx 0)InitialGrant Nothing Fuel 50000(vehicleOwner v)(at 0)Nothing "existing payload")
    void(mintLot(tx 0)InitialGrant Nothing Water 100 source(at 0)Nothing "unreserved demand stock")
    foldM(\s _->snd <$> planDelivery(at 0)source destination Water 1 2 s)carts[1..16::Integer])inventory
  (limited,next)<-step 1(many,stocks)
  assert "matching exact512 global fuel"(transportLastMatches limited==512&&transportLastAssignments limited==17)
  let cursorIds=M.elems(transportMatchCursors limited)
  assert "each request at most32 comparisons"(length cursorIds==16&&all(==M.keys(transportVehicles limited)!!31)cursorIds)
  (continued,_)<-step 2(limited,next)
  assert "matching saved cursor advances beyond first32"(transportLastMatches continued==512&&transportMatchCursors continued/=transportMatchCursors limited)
  putStrLn "Transport matching: 33 full carts/17 requests,512 global/32 quantum and saved cursor advance passed"

fuelCargoTests :: Content -> IO ()
fuelCargoTests content=do
  (_,rid,start,inventory)<-fixture content Truck 350000 Nothing Fuel 1000000
  (done,delivered)<-runTicks 1 85(start,inventory)
  assert "engine cannot burn reserved fuel shipment"(requestStatus(parent rid done)==RequestCompleted&&physical destination Fuel delivered==350000&&M.findWithDefault 0(Fuel,FuelBurned)(invLedger delivered)==800)
  putStrLn "Transport fuel cargo: fuel-as-delivery protected from engine consumption passed"

-- Independent minimal delivery protocol model. This model has no lot IDs,
-- reservations, path search or production inventory/transport helper calls.
-- The physical reference fixture has two10-tick edges. A cancelled outbound
-- edge must finish, then one search boundary precedes the reverse journey.
data LowDelivery = LowDelivery !Integer !Integer !Integer !Integer !Integer !RequestStatus
  deriving (Eq,Show)
lowDelivery :: Maybe Word64 -> Word64 -> LowDelivery
lowDelivery cancellation tick
  | cancellation==Just 1=LowDelivery 10000 0 0 0 0 RequestCancelled
  | Just whenCancelled<-cancellation,whenCancelled<=21=
      let returnAt=if whenCancelled<=11 then 22 else 42
          returned=tick>=returnAt
          cancelled=tick>=whenCancelled
      in LowDelivery(if returned then 10000 else 0)(if returned then 0 else 10000)0
           (if cancelled then 0 else 10000)(if cancelled&&not returned then 10000 else 0)
           (if cancelled then RequestCancelled else RequestOpen)
  | otherwise=let delivered=tick>=21 in LowDelivery 0(if delivered then 0 else 10000)(if delivered then 10000 else 0)
               (if delivered then 0 else 10000)0(if delivered then RequestCompleted else RequestOpen)

lowModelTests :: Content -> IO ()
lowModelTests content=do
  forM_(Nothing:map Just[1..22])$ \cancelAt->do
    (vid,rid,start,inventory)<-fixture content CarrierCart 10000 Nothing Water 1000000
    void$foldM(\pair tick->do
      before<-if cancelAt==Just tick then case runInventory(cancelDelivery(at tick)rid(fst pair))(snd pair)of
        Left AlreadyTerminal->pure pair
        Left err->ioError(userError("low model cancellation failed: "++show err))
        Right committed->pure committed
        else pure pair
      after@(state,stocks)<-step tick before
      let actual=LowDelivery(physical source Water stocks)(physical(Owner Vehicle vid)Water stocks)(physical destination Water stocks)
            (sum[capacityWeight c|c<-M.elems(invCapacity stocks),capacityOwner c==destination])
            (sum[capacityWeight c|c<-M.elems(invCapacity stocks),capacityOwner c==source])
            (requestStatus(parent rid state))
      assert("independent delivery model "++show(cancelAt,tick,actual))(actual==lowDelivery cancelAt tick)
      pure after)(start,inventory)[1..50]
  putStrLn "Transport low model:1150 per-boundary independent quantity/capacity/terminal comparisons over all22 cancellation boundaries passed"

completedPathQueueTests :: Content -> IO ()
completedPathQueueTests content=do
  (_,first,start,inventory)<-fixture content CarrierCart 60000 Nothing Water 1000000
  (requests,stock)<-must "partially filled parent path requests"$runInventory(do
    void(mintLot(tx 0)InitialGrant Nothing Water 180000 source(at 0)Nothing "more parent stock")
    foldM(\s _->snd <$> planDelivery(at 0)source destination Water 60000 2 s)start[1..3::Integer])inventory
  (loaded,carrying)<-step 1(requests,stock)
  assert "completed parent search frees bounded queue immediately"(M.null(pathSearches(transportPaths loaded))&&requestRemaining(parent first loaded)==10000)
  assert "remaining parent owns cached real route"(case requestPathResult(parent first loaded)of PathFound route 20->route==[node 10 10,node 11 10,node 12 10];_->False)
  (completed,delivered)<-runTicks 2 345(loaded,carrying)
  assert "partial requests cannot starve vehicle home search"(all((==RequestCompleted).requestStatus)(M.elems(transportRequests completed))&&physical destination Water delivered==240000)
  putStrLn "Transport queue release: completed routes leave path slots while partial parents keep cached routes; home searches remain live"

transportTests :: Content -> IO ()
transportTests content=do
  pathTests
  splitFuelTests content
  cancelArrivalTests content
  expiryTests content
  closureCapacityTests content
  congestionTests content
  recoveryTests content
  returnCapacityTests content
  waitingRepairTests content
  canonicalFrontierTests content
  matchingBudgetTests content
  fuelCargoTests content
  lowModelTests content
  completedPathQueueTests content
  putStrLn "Transport tests passed (actual four-neighbour roads; no teleport/distancefake fixture)"
