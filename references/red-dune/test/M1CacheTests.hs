module M1CacheTests(main,m1CacheTests) where
import Colony.Codec
import Colony.Content
import qualified Colony.Construction as C
import Colony.Inventory
import Colony.M1Infrastructure
import Colony.M1State
import Colony.S01Fixture
import qualified Colony.Space as Space
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import M1DriverTests(assert,must)
import qualified S01PlayerTests as P
import Control.Monad(foldM)
import qualified Data.ByteString as BS
import Data.IORef
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Directory(createDirectoryIfMissing)
import System.IO(withFile,IOMode(WriteMode))

capacityFixture :: Content -> IO(S01Descriptor,World)
capacityFixture content=do
  (descriptor,initial)<-must "base geometry"(s01Fixture content)
  let inventory=worldInventory initial
      -- Explicit bounded-capacity acceptance fixture, not normative S01. It
      -- changes no stock/ledger/people. Normal commands do every subsequent step.
      limited=inventory{invStorage=M.mapWithKey(\owner store->case owner of Owner Warehouse _->store{storageCapacity=heldWeight inventory owner};_->store)(invStorage inventory)}
      state=P.stateOf initial
      space=(m1Space state){Space.spatialRoads=S.union(Space.spatialRoads(m1Space state))(S.fromList[Space.Tile 61 64,Space.Tile 62 64,Space.Tile 62 63,Space.Tile 62 62])}
  (mapped,transport)<-must "frozen additional starting access roads"(syncInfrastructure content limited(boundarySeq initial)(m1Construction state)space(worldTransport initial))
  let fixture=initial{worldInventory=limited,worldTransport=transport,worldM1=Just state{m1Space=mapped}}
  must "capacity fixture validity"(validateWorld fixture)
  pure(descriptor,fixture)

m1CacheTests :: Content -> IO()
m1CacheTests content=do
  createDirectoryIfMissing True "evidence/m1-cache-0.6"
  (descriptor,initial)<-capacityFixture content
  initialBytes<-must "capacity fixture checkpoint"(encodeCheckpoint(CheckpointMeta 1 Nothing "capacity-isolated-not-campaign")initial)
  BS.writeFile "evidence/m1-cache-0.6/initial.cbor"initialBytes
  withFile "evidence/m1-cache-0.6/native.log" WriteMode$ \handle->do
    shadow<-newIORef Nothing;count<-newIORef 0
    let harness=P.Harness handle shadow count
        initialPump=s01Pump descriptor;home=head(s01Warehouses descriptor)
    staffed<-P.commands harness(s01RosterCommands descriptor++[OrderProduction initialPump])initial
    (planned,site)<-P.newPlan harness descriptor(Space.BuildingShape "hand_pump"(Space.Tile 62 60)Space.R0)staffed
    stone<-P.sourceWith descriptor planned Stone 10000;metal<-P.sourceWith descriptor planned Metal 10000
    supplied<-P.commands harness[RequestDelivery stone(Owner MachineInput site)Stone 10000 2,RequestDelivery metal(Owner MachineInput site)Metal 10000 2]planned
    active<-fst <$> P.accepted harness False[][ResumeWorld]supplied
    ready<-P.untilState harness "materials arrived and real water extracted"3000(\w->P.physical w(Owner MachineInput site)Stone==10000&&P.physical w(Owner MachineInput site)Metal==10000&&P.physical w(Owner MachineOutput initialPump)Water==60000)active
    assert "no phantom crew begins work"(C.constructionProgress(P.constructionJob ready site)==0)
    refilled<-P.commands harness[RequestDelivery(Owner MachineOutput initialPump)home Water 20000 1]ready
    full<-P.untilState harness "actual refill occupies cancellation return room"3000(\w->all(\owner->freeWeight(worldInventory w)owner==0)(s01Warehouses descriptor))refilled
    let builders=take 2(drop 11(s01ShiftResidents descriptor M.!0))
    assigned<-P.commands harness[AssignWorkers(W.ConstructSite site)0 builders]full
    progressed<-P.untilState harness "positive actual construction work"1500((>=1000).C.constructionProgress . (`P.constructionJob`site))assigned
    let beforeJob=P.constructionJob progressed site
    cancelled<-P.commands harness[CancelConstructionPlan site(C.constructionRevision beforeJob)]progressed
    (tile,cacheRecord)<-case M.toAscList(Space.spatialCaches(m1Space(P.stateOf cancelled)))of [entry]->pure entry;_->ioError(userError "one finite real cache expected")
    let owner=Space.cacheOwner cacheRecord
        quantity resource=P.physical cancelled owner resource
    assert "finite spatial cache owns exact physical survivors"(tile==Space.Tile 62 60&&heldWeight(worldInventory cancelled)owner>0&&heldWeight(worldInventory cancelled)owner<=2000000)
    assert "new cache has no imaginary road connection"(M.lookup owner(transportPorts(worldTransport cancelled))==Nothing)
    (notConnected,out)<-P.step harness False[RequestDelivery owner home Stone 1 2][]cancelled
    assert "unconnected cache cannot teleport stock"(worldInventory notConnected==worldInventory cancelled&&all(\r->case receiptOutcome r of CommandFailed _->True;_->False)(outputReceipts out))
    checkpoint<-must "cache snapshot"(encodeCheckpoint(CheckpointMeta 2 Nothing "cache-unconnected")notConnected)
    BS.writeFile "evidence/m1-cache-0.6/cache.cbor"checkpoint
    (_,loaded)<-must "actual cache reload"(decodeCheckpoint checkpoint)
    writeIORef shadow(Just(loaded,0))
    connected<-foldM(\w t->P.buildRoad harness descriptor t w)notConnected[Space.Tile 63 62,Space.Tile 63 61,Space.Tile 63 60]
    assert "real road extension creates cache pickup port"(M.member owner(transportPorts(worldTransport connected)))
    ration<-P.sourceWith descriptor connected Ration 20000
    movedFood<-P.commands harness[RequestDelivery ration(s01Pantry descriptor)Ration 20000 0]connected
    room<-P.untilState harness "physical household resupply frees warehouse room"3000(\w->freeWeight(worldInventory w)home>=quantity Stone+quantity Metal)movedFood
    recovery<-P.commands harness[RequestDelivery owner home Stone(quantity Stone)0,RequestDelivery owner home Metal(quantity Metal)0,RequestDelivery home owner Water 1 3]room
    emptyReserved<-P.untilState harness "empty cache retained by one capacity reservation"3000(\w->heldWeight(worldInventory w)owner==0&&reservedWeight(worldInventory w)owner==1)recovery
    assert "one reservation prevents retirement"(M.member tile(Space.spatialCaches(m1Space(P.stateOf emptyReserved)))&&M.member owner(invStorage(worldInventory emptyReserved)))
    incoming<-case[requestId request|request<-M.elems(transportRequests(worldTransport emptyReserved)),requestDestination request==owner,requestResource request==Water,requestStatus request==RequestOpen]of [ident]->pure ident;_->ioError(userError "one pending incoming reservation")
    released<-P.commands harness[CancelDelivery incoming]emptyReserved
    assert "cancel boundary alone does not run P8 cleanup"(M.member owner(invStorage(worldInventory released)))
    (retired,retirement)<-P.step harness True[][]released
    assert "P8 retires now-empty cache with observable event"(not(M.member owner(invStorage(worldInventory retired)))&&not(M.member tile(Space.spatialCaches(m1Space(P.stateOf retired))))&&M.member owner(transportRemovedPorts(worldTransport retired))&&any(\event->case event of GroundCacheRetired _ old whereTile->old==owner&&whereTile==tile;_->False)(outputEvents retirement))
    -- Separate pure replay branch from the real retired-source checkpoint:
    -- cancelling still-carried outbound stock must use a real Return fallback,
    -- never recreate the deleted cache or refund the same material twice.
    retiredBytes<-must "retired source checkpoint"(encodeCheckpoint(CheckpointMeta 3 Nothing "retired-source-return")retired)
    BS.writeFile "evidence/m1-cache-0.6/retired-source.cbor"retiredBytes
    let outstanding=[requestId request|request<-M.elems(transportRequests(worldTransport retired)),requestSource request==owner,requestStatus request==RequestOpen]
    case outstanding of
      ident:_->withFile "evidence/m1-cache-0.6/return-after-source-retired.log" WriteMode$ \returnHandle->do
        branchShadow<-newIORef Nothing;branchCount<-newIORef 0
        let branchHarness=P.Harness returnHandle branchShadow branchCount
        (_,branchStart)<-must "reload missing-source predecessor"(decodeCheckpoint retiredBytes)
        returnedIntent<-P.commands branchHarness[CancelDelivery ident]branchStart
        returnedCargo<-P.untilState branchHarness "deleted source real Return fallback"3000(\w->all shipmentTerminal(M.elems(transportShipments(worldTransport w))))returnedIntent
        assert "return after source deletion never resurrects cache"(not(M.member owner(invStorage(worldInventory returnedCargo)))&&requestStatus(transportRequests(worldTransport returnedCargo)M.!ident)==RequestCancelled&&any(\shipment->case shipmentKind shipment of ReturnShipment _->shipmentStatus shipment==ShipmentReturned;_->False)(M.elems(transportShipments(worldTransport returnedCargo))))
      []->ioError(userError "missing-source cancellation witness did not occur")
    let oldCounter=invNextId(worldInventory retired)
    (reused,newPlan)<-P.newPlan harness descriptor(Space.RoadShape tile)retired
    assert "next boundary reuses tile with fresh identity"(let EntityId ident=newPlan in ident>=oldCounter&&Owner GroundCache newPlan/=owner)
    final<-P.untilState harness "actual recovered cargo arrives after source retirement"4000(\w->all(\request->requestStatus request/=RequestOpen)[request|request<-M.elems(transportRequests(worldTransport w)),requestSource request==owner])reused
    assert "source retirement never recreates or double-refunds cargo"(all(\request->requestStatus request==RequestCompleted)[request|request<-M.elems(transportRequests(worldTransport final)),requestSource request==owner])
    assert "removed cache ID allocator bound persists"(case owner of Owner _ (EntityId ident)->ident<invNextId(worldInventory final))
    P.milestone "finite cache road recovery reservation tombstone tile reuse"final
    putStrLn "M1_CACHE real cancel→cache→road construction→remote pickup→one-capacity-claim retention→P8 retirement→fresh tile reuse→cargo completion PASS; isolated capacity fixture, not normative S01"
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1CacheTests
