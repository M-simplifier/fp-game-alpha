module M1PickupTests(main,m1PickupTests) where
import Colony.Codec
import Colony.Content
import Colony.Inventory
import Colony.M1State
import Colony.M1Commands(reconcileM1Infrastructure)
import Colony.Pickup
import Colony.S01Fixture
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import qualified Colony.Workforce as W
import qualified Colony.Space as S
import M1DriverTests(step,accept,assert,must,m1)
import M1IntegrityTests(rejectMalformedWorld)
import Control.Monad(foldM,forM_)
import Control.Monad.State.Strict(modify')
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import System.Directory(createDirectoryIfMissing)

physical :: World -> Owner -> Resource -> Integer
physical world owner resource=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory world)),lotOwner lot==owner,lotResource lot==resource]
waitFor :: String -> Integer -> (World->Bool) -> World -> IO World
waitFor label limit predicate=go limit
  where go remaining world|predicate world=pure world
                          |remaining==0=ioError(userError("Pickup timeout "++label++" "++show(simTick world)++" "++show(worldTransport world)))
                          |otherwise=accept True[][]world >>= go(remaining-1)
truckFixture :: Content -> IO(S01Descriptor,World,EntityId,Owner)
truckFixture content=do
  (descriptor,base)<-must "S01 layout"(s01Fixture content)
  let truck=head(s01Carts descriptor)
      initial=base{worldInventory=(worldInventory base){invStorage=M.adjust(\s->s{storageCapacity=300000})(Owner Vehicle truck)(invStorage(worldInventory base))}
        ,worldTransport=(worldTransport base){transportVehicles=M.adjust(\v->v{vehicleKind=Truck})truck(transportVehicles(worldTransport base))}}
      home=head(s01Warehouses descriptor)
  source<-case[owner|owner<-s01Warehouses descriptor,owner/=home,physical initial owner Water>=2000]of
    owner:_->pure owner
    _->ioError(userError "fixture has no remote water source")
  must "isolated pickup truck fixture"(validateWorld initial)
  pure(descriptor,initial,truck,source)

m1PickupTests :: Content -> IO()
m1PickupTests content=do
  createDirectoryIfMissing True "evidence/m1-pickup-0.6"
  (descriptor,initial,truck,source)<-truckFixture content
  initialBytes<-must "pickup initial checkpoint"(encodeCheckpoint(CheckpointMeta 1 Nothing "truck-pickup-isolated")initial)
  BS.writeFile "evidence/m1-pickup-0.6/initial.cbor"initialBytes
  staffed<-accept False(s01RosterCommands descriptor)[]initial
  (ordered,out)<-step False[RequestDelivery source(s01Pantry descriptor)Water 2000 2][ResumeWorld]staffed
  request<-case[ident|receipt<-outputReceipts out,Applied(Just ident)<-[receiptOutcome receipt]]of [ident]->pure ident;_->ioError(userError "pickup request receipt")
  dispatched<-accept True[][]ordered
  assert "pickup claimed without inventing cargo"(M.member truck(m1Pickups(m1 dispatched))&&physical dispatched(Owner Vehicle truck)Water==0)
  assert "parent quantity and capacity stay reserved until real load"(quantityFor request(worldInventory dispatched)==2000&&capacityFor request(s01Pantry descriptor)(worldInventory dispatched)==2000)
  departed<-accept True[][]dispatched
  claim<-maybe(ioError(userError "pickup absent after departure"))pure(M.lookup truck(m1Pickups(m1 departed)))
  let vehicle world=transportVehicles(worldTransport world)M.!truck
      spent world=M.findWithDefault 0(Fuel,FuelBurned)(invLedger(worldInventory world))
      fuelHeld world=physical world(Owner Vehicle truck)Fuel
      travelEdges=pickupFuelRouteEdges claim
      samePaidEdge a b=case(vehiclePosition(vehicle a),vehiclePosition(vehicle b))of
        (Traversing x y n r,Traversing u v m s)->(x,y,r)==(u,v,s)&&m==n-1
        _->False
  assert "empty truck really enters paid road edge"(case vehiclePosition(vehicle departed)of Traversing _ _ 10 _->True;_->False)
  assert "pickup reserves all outbound+delivery+legal return legs"(pickupFuelReady claim&&travelEdges>0&&fuelHeld departed+spent departed==travelEdges*120&&spent departed==100)
  assert "source untouched while empty vehicle is moving"(physical departed source Water==physical initial source Water&&physical departed(Owner Vehicle truck)Water==0)
  snapshot<-must "save empty pickup in flight"(encodeCheckpoint(CheckpointMeta 2 Nothing "pickup-inflight")departed)
  BS.writeFile "evidence/m1-pickup-0.6/inflight.cbor"snapshot
  (_,loaded)<-must "reload empty pickup"(decodeCheckpoint snapshot)
  assert "pickup route/fuel/claim reload exact"(loaded==departed)
  progressed<-accept True[][]departed
  replayed<-accept True[][]loaded
  assert "one actual restored suffix tick"(progressed==replayed&&samePaidEdge departed progressed&&spent progressed==100)
  carrying<-waitFor "remote source pickup"500(\world->vehicleJob(vehicle world)/=Nothing)progressed
  assert "load occurs only at real source node"(vehiclePosition(vehicle carrying)==AtRoadNode(M.findWithDefault(RoadNode 0)source(transportPorts(worldTransport carrying)))||case vehiclePosition(vehicle carrying)of Traversing from _ _ _->Just from==M.lookup source(transportPorts(worldTransport carrying));_->False)
  assert "same parent reservation transfers once to cargo child"(physical carrying source Water==physical initial source Water-2000&&physical carrying(Owner Vehicle truck)Water==2000&&not(M.member truck(m1Pickups(m1 carrying))))
  internalCargoEndpointTest descriptor truck request carrying
  delivered<-waitFor "remote loaded delivery"1000(\world->maybe False((==RequestCompleted).requestStatus)(M.lookup request(transportRequests(worldTransport world))))carrying
  returned<-waitFor "ordinary paid home return"1000(\world->vehicleJob(vehicle world)==Nothing&&vehiclePosition(vehicle world)==AtRoadNode(transportPorts(worldTransport world)M.!vehicleHome(vehicle world)))delivered
  assert "fuel conservation includes empty trip and return"(sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory returned)),lotResource lot==Fuel]+spent returned==M.findWithDefault 0 Fuel s01Grants)
  assert "round-trip reserve was sufficient, no remote refuelling"(fuelHeld returned+spent returned==travelEdges*120&&spent returned>100)
  assert "load capacity includes remaining reserved fuel"(heldWeight(worldInventory carrying)(Owner Vehicle truck)<=300000)
  fuelCertificateTest descriptor truck request departed
  cancelled<-accept False[CancelDelivery request][]departed
  assert "pickup cancellation releases stock/capacity, preserves paid edge/fuel"(M.null(m1Pickups(m1 cancelled))&&quantityFor request(worldInventory cancelled)==0&&capacityFor request(s01Pantry descriptor)(worldInventory cancelled)==0&&vehiclePosition(vehicle cancelled)==vehiclePosition(vehicle departed)&&fuelHeld cancelled==fuelHeld departed)
  cancellationReturn<-waitFor "cancelled empty pickup returns home"500(\world->vehiclePosition(vehicle world)==AtRoadNode(transportPorts(worldTransport world)M.!vehicleHome(vehicle world)))cancelled
  assert "cancelled empty pickup never loaded or created Return cargo"(physical cancellationReturn source Water==physical initial source Water&&null(requestChildren(transportRequests(worldTransport cancellationReturn)M.!request)))
  expiryTest content
  predepartureCancelTest content
  remoteReassignmentTest content
  putStrLn("M1_PICKUP physical remote source + paid empty trip + full four-leg fuel reserve + load/capacity/return + in-flight V4 save + cancel + expiry + physical fuel certificate + closed-road save/reload/replan PASS reservedEdges="++show travelEdges)


-- Both a fully loaded child and a Return must target a real public endpoint.
-- Their capacity rights cannot turn an internal recipe escrow into a road port.
internalCargoEndpointTest :: S01Descriptor -> EntityId -> EntityId -> World -> IO()
internalCargoEndpointTest descriptor truck request carrying=do
  planned<-accept False[OrderProduction(s01Farm descriptor)][]carrying
  let job=head(M.keys(worldJobs planned));wip=Owner MachineInput job
      transport=worldTransport planned;inventory=worldInventory planned
      child=maybe(error "carrying child missing")id(vehicleJob(transportVehicles transport M.!truck))
      rerouteCargo ident inv=inv{invCapacity=M.map(\claim->if capacityJob claim==ident then claim{capacityOwner=wip}else claim)(invCapacity inv)}
      badChild=planned{worldTransport=transport{transportRequests=M.adjust(\r->r{requestDestination=wip})request(transportRequests transport)
          ,transportShipments=M.adjust(\shipment->shipment{shipmentDestination=Just wip})child(transportShipments transport)}
        ,worldInventory=rerouteCargo child inventory}
  rejectMalformedWorld "loaded child plus parent/capacity cannot target internal WIP"planned badChild
  returning<-accept False[CancelDelivery request][]planned
  let returnTransport=worldTransport returning
      returnId=maybe(error "real Return missing")id(vehicleJob(transportVehicles returnTransport M.!truck))
      badReturn=returning{worldTransport=returnTransport{transportShipments=M.adjust(\shipment->shipment{shipmentDestination=Just wip})returnId(transportShipments returnTransport)}
        ,worldInventory=rerouteCargo returnId(worldInventory returning)}
  assert "negative control has actual live Return"(case shipmentKind(transportShipments returnTransport M.!returnId)of ReturnShipment _->True;_->False)
  rejectMalformedWorld "live Return with matching capacity cannot target internal WIP"returning badReturn

-- Current-generation route certificates are structural witnesses, not trusted
-- counters. A recorded test-only road closure/reopen exercises the existing
-- invalidation contract; no public road-closure command is claimed implemented.
fuelCertificateTest :: S01Descriptor -> EntityId -> EntityId -> World -> IO()
fuelCertificateTest descriptor truck request moving=do
  let state=m1 moving;claim=m1Pickups state M.!truck
      vehicle world=transportVehicles(worldTransport world)M.!truck
      mutate f=moving{worldM1=Just state{m1Pickups=M.adjust f truck(m1Pickups state)}}
      witness=pickupReturnPath claim
      fuelBurned world=M.findWithDefault 0(Fuel,FuelBurned)(invLedger(worldInventory world))
  assert "real saved path certifies remote home"(length witness>1&&head witness/=last witness&&pickupReturnToHomeEdges claim==toInteger(length witness)-1)
  rejectMalformedWorld "zero numerical return certificate"moving(mutate(\c->c{pickupFuelRouteEdges=0,pickupReturnToHomeEdges=0}))
  rejectMalformedWorld "missing physical return witness"moving(mutate(\c->c{pickupReturnPath=[]}))
  rejectMalformedWorld "teleporting return witness"moving(mutate(\c->c{pickupReturnPath=[head witness,last witness],pickupReturnToHomeEdges=1,pickupFuelRouteEdges=pickupFuelRouteEdges c-2*(pickupReturnToHomeEdges c-1)}))
  (_,lessFuel)<-must "isolated conserving reserve shortfall"(runInventory(consumeFreeDetailed(TxId 1 1(boundarySeq moving)P7 99)FuelBurned(Just VehicleEdge)Nothing(simTick moving)(Owner Vehicle truck)Fuel 1)(worldInventory moving))
  rejectMalformedWorld "physical fuel short of certified20percent reserve"moving moving{worldInventory=lessFuel}
  (from,to)<-case vehiclePosition(vehicle moving)of Traversing a b _ _->pure(a,b);_->ioError(userError "closure witness requires paid in-flight edge")
  let intervention active world=do
        let transport=worldTransport world
        topology<-(if active then reopenRoad else closeRoad)(boundarySeq world)from to(transportTopology transport)
        reconcileM1Infrastructure world{worldTransport=transport{transportTopology=topology}}
  closed<-must "recorded test-only closure and generation invalidation"(intervention False moving)
  assert "closure retires obsolete certificate without losing parent rights/paid edge"(M.null(m1Pickups(m1 closed))&&quantityFor request(worldInventory closed)==2000&&capacityFor request(s01Pantry descriptor)(worldInventory closed)==2000&&vehiclePosition(vehicle closed)==vehiclePosition(vehicle moving)&&fuelBurned closed==fuelBurned moving)
  snapshot<-must "closed edge state stays saveable"(encodeCheckpoint(CheckpointMeta 5 Nothing "recorded-closure-test-only")closed)
  BS.writeFile "evidence/m1-pickup-0.6/closed-edge-waiting.cbor"snapshot
  (_,restored)<-must "closed edge state reload"(decodeCheckpoint snapshot)
  (waited,replayed)<-foldM(\(a,b)_->do x<-accept True[][]a;y<-accept True[][]b;assert "closed road restore suffix"(x==y);pure(x,y))(closed,restored)[1..25::Int]
  assert "legitimate closed-edge waiting never pretends route validity or burns again"(waited==replayed&&vehiclePosition(vehicle waited)==vehiclePosition(vehicle moving)&&vehicleBlock(vehicle waited)==Just RemovedEdge&&fuelBurned waited==fuelBurned moving)
  reopened<-must "recorded test-only reopen"(intervention True waited)
  reopenedCopy<-must "replay same intervention"(intervention True replayed)
  assert "environment event replay exact"(reopened==reopenedCopy)
  next<-accept True[][]reopened
  assert "reopen resumes paid edge without double fuel"(fuelBurned next==fuelBurned moving&&case(vehiclePosition(vehicle moving),vehiclePosition(vehicle next))of (Traversing a b n r,Traversing x y k t)->(a,b,r)==(x,y,t)&&k==n-1;_->False)
  completed<-waitFor "replanned pickup after closure and real home return"4000(\world->requestStatus(transportRequests(worldTransport world)M.!request)==RequestCompleted)next
  assert "closure/reload/reopen completes exact parent"(requestStatus(transportRequests(worldTransport completed)M.!request)==RequestCompleted)
  writeFile "evidence/m1-pickup-0.6/road-interventions.txt"(unlines["TEST-ONLY scenario interventions; no production player command", "CloseRoad "++show(boundarySeq moving,from,to),"25 ordinary native advancing boundaries with exact restored suffix","ReopenRoad "++show(boundarySeq waited,from,to),"Exact parent completed "++show request++" at "++show(simTick completed)])

expiryTest :: Content -> IO()
expiryTest content=do
  (descriptor,base,truck,remote)<-truckFixture content
  let home=head(s01Warehouses descriptor)
  (_,inventory)<-must "isolated old food fixture"$runInventory(do
    moveFree(simTick base)home remote Ration 2000
    modify'$ \state->state{invLots=M.map(\lot->if lotOwner lot==remote&&lotResource lot==Ration then lot{lotExpires=Just(SimTick 7203)}else lot)(invLots state)})(worldInventory base)
  let initial=base{worldInventory=inventory}
  must "old food fixture validates"(validateWorld initial)
  staffed<-accept False(s01RosterCommands descriptor)[]initial
  (ordered,out)<-step False[RequestDelivery remote(s01Pantry descriptor)Ration 2000 2][ResumeWorld]staffed
  request<-case[ident|receipt<-outputReceipts out,Applied(Just ident)<-[receiptOutcome receipt]]of [ident]->pure ident;_->ioError(userError "expiry request")
  moving<-foldM(\w _->accept True[][]w)ordered[1..2::Int]
  assert "perishable pickup was really moving"(M.member truck(m1Pickups(m1 moving)))
  expired<-accept True[][]moving
  assert "P2 expiry cancels empty pickup before movement/loading"(M.null(m1Pickups(m1 expired))&&requestStatus(transportRequests(worldTransport expired)M.!request)==RequestFailed)
  assert "expiry converts only source food, no vehicle food/waste resurrection"(physical expired remote Ration==0&&physical expired remote Waste==2000&&physical expired(Owner Vehicle truck)Ration==0&&physical expired(Owner Vehicle truck)Waste==0)
  assert "expiry releases both parent rights"(quantityFor request(worldInventory expired)==0&&capacityFor request(s01Pantry descriptor)(worldInventory expired)==0)
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1PickupTests

predepartureCancelTest :: Content -> IO()
predepartureCancelTest content=do
  (descriptor,base)<-must "ordinary S01 cancel control"(s01Fixture content)
  let cart=head(s01Carts descriptor);driver=(s01ShiftResidents descriptor M.!0)!!9;remote=(s01Warehouses descriptor)!!1
      requestBody=RequestDelivery remote(s01Pantry descriptor)Water 2000 2
  forM_ [CarrierCart,Truck]$ \kind->do
    let initial=if kind==CarrierCart then base else base
          {worldInventory=(worldInventory base){invStorage=M.adjust(\s->s{storageCapacity=300000})(Owner Vehicle cart)(invStorage(worldInventory base))}
          ,worldTransport=(worldTransport base){transportVehicles=M.adjust(\v->v{vehicleKind=Truck})cart(transportVehicles(worldTransport base))}}
    assigned<-accept False[AssignWorkers(W.DriveVehicle cart)0[driver]][]initial
    (ordered,out)<-step False[requestBody][ResumeWorld]assigned
    request<-case[ident|receipt<-outputReceipts out,Applied(Just ident)<-[receiptOutcome receipt]]of [ident]->pure ident;_->ioError(userError "predepart receipt")
    pending<-accept True[][]ordered
    assert "actual driver claim before departure"(M.lookup driver(W.workforceClaims(m1Workforce(m1 pending)))==Just(W.DriveVehicle cart)&&M.member cart(m1Pickups(m1 pending)))
    bytes<-must "pending pickup saved"(encodeCheckpoint(CheckpointMeta 3 Nothing "review-predepart-regression")pending)
    (_,saved)<-must "pending pickup reload"(decodeCheckpoint bytes)
    forM_ [False,True]$ \advance->do
      cancelled<-accept advance[CancelDelivery request][]saved
      assert "cancel-before-departure atomically releases idle driver claim"(M.null(m1Pickups(m1 cancelled))&&not(M.member driver(W.workforceClaims(m1Workforce(m1 cancelled))))&&worldMode cancelled==Active)
      assert "cancelled predepart pickup never spends fuel"(M.findWithDefault 0(Fuel,FuelBurned)(invLedger(worldInventory cancelled))==0)
    -- A normal plan admission adds a delivery port/revision. A stale empty-trip
    -- certificate is invalidated atomically, not allowed to fault P10.
    changed<-accept False[PlaceConstructionPlan(s01Colony descriptor)(S.RoadShape(S.Tile 61 64))2 Nothing][]saved
    assert "port edit invalidates pending pickup without losing parent rights"(M.null(m1Pickups(m1 changed))&&quantityFor request(worldInventory changed)==2000&&capacityFor request(s01Pantry descriptor)(worldInventory changed)==2000)

remoteReassignmentTest :: Content -> IO()
remoteReassignmentTest content=do
  (descriptor,base,truck,remote)<-truckFixture content
  let driver=(s01ShiftResidents descriptor M.!0)!!9;home=head(s01Warehouses descriptor)
  staffed<-accept False[AssignWorkers(W.DriveVehicle truck)0[driver]][]base
  first<-accept False[RequestDelivery home remote Stone 1000 2][ResumeWorld]staffed
  moving<-accept True[][]first
  (queued,out)<-step False[RequestDelivery remote(s01Pantry descriptor)Water 2000 2][]moving
  second<-case[ident|receipt<-outputReceipts out,Applied(Just ident)<-[receiptOutcome receipt]]of [ident]->pure ident;_->ioError(userError "remote reassignment receipt")
  before<-waitFor "one paid edge tick before remote arrival"200(\world->case vehiclePosition(transportVehicles(worldTransport world)M.!truck)of Traversing _ to 1 _->Just to==M.lookup remote(transportPorts(worldTransport world));_->False)queued
  snapshot<-must "remote arrival predecessor checkpoint"(encodeCheckpoint(CheckpointMeta 4 Nothing "review-remote-reassignment")before)
  (_,loaded)<-must "remote arrival predecessor reload"(decodeCheckpoint snapshot)
  arrived<-accept True[][]before
  reloaded<-accept True[][]loaded
  assert "insufficient remote refuel is a wait, not whole-world fault"(arrived==reloaded&&worldMode arrived==Active&&requestRemaining(transportRequests(worldTransport arrived)M.!second)==2000)
  let physicalFuel w=physical w(Owner Vehicle truck)Fuel
      stored=physicalFuel arrived
  homeAgain<-waitFor "truck physically returns for refuel"300(\world->vehiclePosition(transportVehicles(worldTransport world)M.!truck)==AtRoadNode(transportPorts(worldTransport world)M.!home))arrived
  assert "remote waiting never manufactured fuel"(physicalFuel homeAgain<=stored)
  completed<-waitFor "fresh four-leg plan completes queued remote order"2000(\world->requestStatus(transportRequests(worldTransport world)M.!second)==RequestCompleted)homeAgain
  assert "real queued remote request eventually completes"(worldMode completed==Active&&physical completed remote Water==physical base remote Water-2000)
