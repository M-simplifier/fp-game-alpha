{-# LANGUAGE BangPatterns #-}
module S01PlayerTests(main,s01PlayerTests,Harness(..),step,accepted,commands,untilState,constructionJob,physical,sourceWith,newPlan,buildRoad,stateOf,milestone) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import qualified Colony.Construction as C
import Colony.M1State
import Colony.Needs
import Colony.S01Fixture
import Colony.Scheduler
import qualified Colony.Space as Space
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import Control.Monad(foldM,forM_,unless)
import qualified Data.ByteString as BS
import Data.IORef
import Data.List(sortOn)
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)
import System.Directory(createDirectoryIfMissing)
import System.IO(Handle,IOMode(WriteMode),withFile,hPutStrLn,hFlush,stdout)

assert :: String -> Bool -> IO()
assert label value=unless value(ioError(userError("S01 player: "++label)))
must :: Show e => String -> Either e a -> IO a
must label=either(ioError . userError . ((label++": ")++) . show)pure
physical :: World -> Owner -> Resource -> Integer
physical world owner resource=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory world)),lotOwner lot==owner,lotResource lot==resource]
freeAt :: World -> Owner -> Resource -> Integer
freeAt world owner resource=physical world owner resource-sum[qtyValue(quantityAmount claim)|claim<-M.elems(invQuantity inventory),Just lot<-[M.lookup(quantityLot claim)(invLots inventory)],lotOwner lot==owner,lotResource lot==resource]
  where inventory=worldInventory world
stateOf :: World -> M1State
stateOf world=maybe(error "test expected M1")id(worldM1 world)
constructionJob :: World -> EntityId -> C.ConstructionJob
constructionJob world ident=C.constructionJobs(m1Construction(stateOf world))M.!ident
sourceWith :: S01Descriptor -> World -> Resource -> Integer -> IO Owner
sourceWith descriptor world resource amount=case[owner|owner<-s01Warehouses descriptor,freeAt world owner resource>=amount]of
  owner:_->pure owner
  _->ioError(userError("S01 missing warehouse material "++show(resource,amount)))

data Harness=Harness !Handle !(IORef(Maybe(World,Integer))) !(IORef Integer)
step :: Harness -> Bool -> [Command] -> [ManagementEvent] -> World -> IO(World,ColonyOutput)
step(Harness handle shadowRef countRef) advance bodies management world=do
  let epoch=participantEpoch(worldParticipants world M.!1)
      highest=M.findWithDefault 0(1,epoch)(worldHighWater world)
      ordered=[OrderedCommand ordinal(CommandId(worldId world)1 epoch(highest+ordinal+1))body|(ordinal,body)<-zip[0..]bodies]
      header=BoundaryHeader(worldId world)(branchId world)(boundarySeq world)advance(worldAuthority world)(worldRuleset world)
      native=Boundary header ordered management
      direct=pureStep native world
  actual<-must "real Arena admission"(play Colony(RecordedBoundary header(map commandId ordered)management)(singleton 1(OrderedBatch ordered))world)
  assert "pureStep/Arena exact"(actual==direct)
  let (next,out)=actual
  assert("no kernel diagnostics "++show outputContext++" "++show(outputDiagnostics out))(null(outputDiagnostics out))
  hPutStrLn handle(show native++" => "++show out)
  modifyIORef' countRef(+1)
  shadow<-readIORef shadowRef
  case shadow of
    Nothing->pure()
    Just(saved,n)->do
      let replayed=pureStep native saved
      assert("saved suffix exact boundary "++show n)(replayed==actual)
      writeIORef shadowRef(Just(fst replayed,n+if advance then 1 else 0))
  pure(next,out)
  where outputContext=(simTick world,bodies)
accepted :: Harness -> Bool -> [Command] -> [ManagementEvent] -> World -> IO(World,[Maybe EntityId])
accepted harness advance bodies management world=do
  (next,out)<-step harness advance bodies management world
  assert("accepted command receipts "++show(outputReceipts out))(all isAccepted(outputReceipts out))
  pure(next,[ident|receipt<-outputReceipts out,Applied ident<-[receiptOutcome receipt]])
  where isAccepted receipt=case receiptOutcome receipt of Applied _->True;_->False
commands :: Harness -> [Command] -> World -> IO World
commands harness bodies world=fst <$> accepted harness False bodies[]world
untilState :: Harness -> String -> Integer -> (World->Bool) -> World -> IO World
untilState harness label limit predicate initial=go limit initial
  where
    go remaining !world
      |predicate world=pure world
      |remaining==0=ioError(userError("S01 timeout "++label++" tick="++show(simTick world)++" jobs="++show(M.elems(worldJobs world))++" construction="++show(C.constructionJobs(m1Construction(stateOf world)))++" vehicles="++show(M.elems(transportVehicles(worldTransport world)))))
      |otherwise=do
        (next,_)<-step harness True[][]world
        go(remaining-1)next
milestone :: String -> World -> IO()
milestone label world=do
  digest<-must "milestone hash"(canonicalStateHash world)
  putStrLn("S01 "++label++" tick="++show(simTick world)++" boundary="++show(boundarySeq world)++" state="++hex digest)
  hFlush stdout
  where hex=concatMap(\byte->let digits="0123456789abcdef";n=fromIntegral byte in[digits!!(n `div`16),digits!!(n `mod`16)]) . BS.unpack
newPlan :: Harness -> S01Descriptor -> Space.PlacementShape -> World -> IO(World,EntityId)
newPlan harness descriptor shape world=do
  (next,result)<-accepted harness False[PlaceConstructionPlan(s01Colony descriptor)shape 2 Nothing][]world
  case result of [Just ident]->pure(next,ident);_->ioError(userError "plan result")
buildRoad :: Harness -> S01Descriptor -> Space.Tile -> World -> IO World
buildRoad harness descriptor tile world=do
  (planned,site)<-newPlan harness descriptor(Space.RoadShape tile)world
  source<-sourceWith descriptor planned Stone 2000
  supplied<-commands harness[AssignWorkers(W.ConstructSite site)1(s01Builders descriptor),RequestDelivery source(Owner MachineInput site)Stone 2000 2]planned
  complete<-untilState harness("road complete "++show tile)5000((==C.ConstructionCompleted).C.constructionPhase . (`constructionJob`site))supplied
  assert "road consumed exactly once"(C.constructionTerminalCount(constructionJob complete site)==1)
  milestone("road "++show tile)complete
  pure complete


-- A batch is tracked by metadata that real lot splits/transfers preserve. The
-- witness observes specific ownership, not just any earlier Ration request or
-- a positive lifetime consumption counter. This is a test oracle, not game code.
type BatchKey=(SimTick,Maybe SimTick,String)
batchKey :: Lot -> BatchKey
batchKey lot=(lotBorn lot,lotExpires lot,lotProvenance lot)
batchOwners :: BatchKey -> World -> M.Map Owner Integer
batchOwners key world=M.fromListWith(+)[(lotOwner lot,qtyValue(lotQty lot))|lot<-M.elems(invLots(worldInventory world)),lotResource lot==Ration,batchKey lot==key]
batchTotal :: BatchKey -> World -> Integer
batchTotal key=sum . M.elems . batchOwners key
rationLedger :: Reason -> World -> Integer
rationLedger reason=M.findWithDefault 0(Ration,reason) . invLedger . worldInventory

-- Independent FEFO walk over the real pre-consumption pantry. It does not call
-- Needs.consumePool, Inventory.fefo/selectFree, or any production return oracle.
expectedBatchConsumed :: BatchKey -> Owner -> Integer -> World -> Integer
expectedBatchConsumed key pantry amount world=go amount sorted
  where
    inventory=worldInventory world
    sorted=sortOn(\lot->(case lotExpires lot of Nothing->(1::Integer,0);Just(SimTick tick)->(0,toInteger tick),lotBorn lot,lotId lot))
      [lot|lot<-M.elems(invLots inventory),lotResource lot==Ration,lotOwner lot==pantry,maybe True(>simTick world)(lotExpires lot)]
    free lot=qtyValue(lotQty lot)-sum[qtyValue(quantityAmount claim)|claim<-M.elems(invQuantity inventory),quantityLot claim==lotId lot]
    go _ []=0
    go 0 _=0
    go remaining(lot:rest)=let taken=min remaining(free lot) in (if batchKey lot==key then taken else 0)+go(remaining-taken)rest

witnessFreshRation :: Harness -> S01Descriptor -> World -> IO World
witnessFreshRation harness descriptor cooked=do
  let output=Owner MachineOutput(s01Kitchen descriptor);pantry=s01Pantry descriptor
      produced=[lot|lot<-M.elems(invLots(worldInventory cooked)),lotOwner lot==output,lotResource lot==Ration]
  lot<-case produced of [one]->pure one;_->ioError(userError "one new kitchen batch expected")
  let key=batchKey lot;amount=18000
  assert "new batch quantity/birth/provenance"(qtyValue(lotQty lot)==amount&&lotBorn lot==simTick cooked&&lotProvenance lot=="recipe:cook")
  assert "P7 RecipeOutput ledger binds the newly made batch"(sum[ledgerQuantity entry|entry<-invRecentLedger(worldInventory cooked),ledgerResource entry==Ration,ledgerReason entry==RecipeOutput,ledgerTo entry==Just output,case ledgerTx entry of TxId _ _ _ P7 _->True;_->False]==amount)
  writeCheckpoint "cooked-new-batch.cbor"cooked
  (requested,ids)<-accepted harness False[RequestDelivery output pantry Ration amount 0][]cooked
  request<-case ids of [Just ident]->pure ident;_->ioError(userError "specific fresh-batch request ID missing")
  let completed world=maybe False((==RequestCompleted).requestStatus)(M.lookup request(transportRequests(worldTransport world)))
      oldLoosePredicate world=any(\r->requestResource r==Ration&&requestDestination r==pantry&&requestStatus r==RequestCompleted)(M.elems(transportRequests(worldTransport world)))
      cargo world=sum[q|(Owner Vehicle _,q)<-M.toList(batchOwners key world)]
  assert "negative control: old ration delivery cannot complete this new request"(oldLoosePredicate requested&&not(completed requested)&&batchOwners key requested==M.singleton output amount)
  seenCargo<-newIORef False
  let delivery remaining world
        |completed world=pure world
        |remaining==0=ioError(userError "fresh batch delivery timeout")
        |otherwise=do
          (next,_)<-step harness True[][]world
          assert "fresh batch conserved before pantry delivery"(batchTotal key next==amount)
          if cargo next>0 then do
            observed<-readIORef seenCargo
            unless observed $ do
              assert "actual child carries batch for exact parent"(any(\shipment->shipmentKind shipment==DeliveryChild request&&shipmentStatus shipment==ShipmentCarrying&&any(\held->lotOwner held==Owner Vehicle(shipmentVehicle shipment)&&batchKey held==key&&lotResource held==Ration)(M.elems(invLots(worldInventory next))))(M.elems(transportShipments(worldTransport next))))
              writeCheckpoint "fresh-batch-in-vehicle.cbor"next
              writeIORef seenCargo True
          else pure()
          delivery(remaining-1)next
  delivered<-delivery(4000::Integer)requested
  cargoSeen<-readIORef seenCargo
  assert "exact new request delivered all18000 via real vehicle into pantry"(cargoSeen&&batchOwners key delivered==M.singleton pantry amount&&all(\shipment->shipmentKind shipment/=DeliveryChild request||shipmentStatus shipment==ShipmentDelivered)(M.elems(transportShipments(worldTransport delivered))))
  writeCheckpoint "fresh-batch-delivered.cbor"delivered
  sawOlderConsumption<-newIORef False
  let consume remaining world
        |remaining==0=ioError(userError "fresh batch consumption timeout")
        |otherwise=do
          (next,_)<-step harness True[][]world
          let livingDelta=rationLedger LivingConsumed next-rationLedger LivingConsumed world
              batchDelta=batchTotal key world-batchTotal key next
              oracle=expectedBatchConsumed key pantry livingDelta world
          assert "fresh batch depletion equals independent FEFO LivingConsumed"(livingDelta>=0&&batchDelta==oracle&&batchDelta>=0&&batchDelta<=livingDelta)
          assert "ration batch not expired/cancelled/consumed by another recipe"(all(\reason->rationLedger reason next==rationLedger reason world)[SpoilageInput,CancelledProcessLoss,RecipeInput,RecipeOutput])
          if livingDelta>0&&batchDelta==0 then writeIORef sawOlderConsumption True else pure()
          if batchDelta>0 then do
            older<-readIORef sawOlderConsumption
            assert "negative control: consumption of mixed older stock did not complete witness"older
            assert "matching P8 pantry LivingConsumed journal"(sum[ledgerQuantity entry|entry<-invRecentLedger(worldInventory next),ledgerResource entry==Ration,ledgerReason entry==LivingConsumed,ledgerFrom entry==Just pantry,case ledgerTx entry of TxId _ _ sequenceValue P8 _->sequenceValue==boundarySeq world;_->False]==livingDelta)
            assert "batch remainder has one pantry owner and exact mass"(batchOwners key next==M.singleton pantry(amount-batchDelta))
            writeCheckpoint "fresh-batch-consumed.cbor"next
            writeFile "evidence/s01-player-0.6/fresh-batch-witness.txt"(unlines["request="++show request,"batch="++show key,"RecipeOutput="++show amount,"observedVehicleOwnership=True","deliveredToPantry="++show amount,"firstBatchLivingConsumed="++show batchDelta,"sameQuantumTotalRationLivingConsumed="++show livingDelta,"batchRemaining="++show(batchTotal key next),"mixedOldRequestAndOldConsumptionNegativeControls=True","finalTick="++show(simTick next)])
            pure next
          else consume(remaining-1)next
  consume(20000::Integer)delivered
  where
    writeCheckpoint name world=must "fresh-batch witness checkpoint"(encodeCheckpoint(CheckpointMeta 3 Nothing "fresh-ration-chain")world)>>=BS.writeFile("evidence/s01-player-0.6/"++name)

s01PlayerTests :: Content -> IO()
s01PlayerTests content=do
  createDirectoryIfMissing True "evidence/s01-player-0.6"
  (descriptor,initial)<-must "normative S01 initialization"(s01Fixture content)
  initialBytes<-must "initial checkpoint"(encodeCheckpoint(CheckpointMeta 1 Nothing "s01-player-0.6")initial)
  BS.writeFile "evidence/s01-player-0.6/initial.cbor" initialBytes
  assert "normative asset vector"(M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-M.elems(invLots(worldInventory initial))]==s01Grants)
  assert "40 actual beds"(M.size(m1Beds(stateOf initial))==40)
  assert "ID-mod3 initial shifts"(all(\r->let EntityId n=residentId r in residentShift r==toInteger(n `mod`3))(M.elems(needsResidents(worldNeeds initial))))
  withFile "evidence/s01-player-0.6/native.log" WriteMode$ \handle->do
    shadow<-newIORef Nothing;count<-newIORef 0
    let harness=Harness handle shadow count
    rostered<-commands harness(s01RosterCommands descriptor++[SetSiteEnabled(s01Farm descriptor)True,SetSiteEnabled(s01Kitchen descriptor)True])initial
    -- A failed assignment cannot steal a person from a different target.
    let resident=head(M.findWithDefault [] 0(s01ShiftResidents descriptor));prior=worldM1 rostered
    (rejected,denial)<-step harness False[AssignWorkers(W.OperateFacility(s01Kitchen descriptor))0[resident]][]rostered
    assert "cross-target roster rejected atomically"(worldM1 rejected==prior&&all(\r->case receiptOutcome r of CommandFailed _->True;_->False)(outputReceipts denial))
    (emptyPlanned,emptySite)<-newPlan harness descriptor(Space.RoadShape(Space.Tile 61 65))rejected
    emptyCancelled<-commands harness[CancelConstructionPlan emptySite(C.constructionRevision(constructionJob emptyPlanned emptySite))]emptyPlanned
    assert "empty plan cancellation consumes no material"(invLedger(worldInventory emptyCancelled)==invLedger(worldInventory initial))
    let pump=s01Pump descriptor
    starting<-commands harness[OrderProduction pump]emptyCancelled
    active<-fst <$> accepted harness False[][ResumeWorld]starting
    roads<-foldM(\world tile->buildRoad harness descriptor tile world)active[Space.Tile 61 64,Space.Tile 62 64,Space.Tile 62 63,Space.Tile 62 62]
    (pumpPlanned,newPump)<-newPlan harness descriptor(Space.BuildingShape "hand_pump"(Space.Tile 62 60)Space.R0)roads
    stone<-sourceWith descriptor pumpPlanned Stone 10000;metal<-sourceWith descriptor pumpPlanned Metal 10000
    delivered<-commands harness[AssignWorkers(W.ConstructSite newPump)1(s01Builders descriptor),RequestDelivery stone(Owner MachineInput newPump)Stone 10000 2,RequestDelivery metal(Owner MachineInput newPump)Metal 10000 2]pumpPlanned
    progressed<-untilState harness "pump partial work"4000((>=30000).C.constructionProgress . (`constructionJob`newPump))delivered
    checkpoint<-must "active construction V4 snapshot"(encodeCheckpoint(CheckpointMeta 2 Nothing "s01-running-construction")progressed)
    BS.writeFile "evidence/s01-player-0.6/active-construction.cbor"checkpoint
    (_,restored)<-must "actual V4 reload"(decodeCheckpoint checkpoint)
    writeIORef shadow(Just(restored,0))
    let oldJob=constructionJob progressed newPump;progress=C.constructionProgress oldJob;required=C.constructionRequired(C.constructionSnapshot oldJob)
        expectedLoss=10000-(10000*(10000-(5000*progress `div`required)) `div`10000)
        beforeLedger=invLedger(worldInventory progressed)
        beforeXP=map(W.workerSkills)(M.elems(W.workforceWorkers(m1Workforce(stateOf progressed))))
    cancelled<-commands harness[CancelConstructionPlan newPump(C.constructionRevision oldJob)]progressed
    forM_[Stone,Metal]$ \resource->assert "nested resource refund ledger"(M.findWithDefault 0(resource,ConstructionLoss)(invLedger(worldInventory cancelled))-M.findWithDefault 0(resource,ConstructionLoss)beforeLedger==expectedLoss)
    assert "cancellation preserves earned worker XP"(map W.workerSkills(M.elems(W.workforceWorkers(m1Workforce(stateOf cancelled))))==beforeXP)
    milestone "progressed pump cancelled"cancelled
    (replanned,rebuiltId)<-newPlan harness descriptor(Space.BuildingShape "hand_pump"(Space.Tile 62 60)Space.R0)cancelled
    stone2<-sourceWith descriptor replanned Stone 10000;metal2<-sourceWith descriptor replanned Metal 10000
    resupplied<-commands harness[AssignWorkers(W.ConstructSite rebuiltId)1(s01Builders descriptor),RequestDelivery stone2(Owner MachineInput rebuiltId)Stone 10000 2,RequestDelivery metal2(Owner MachineInput rebuiltId)Metal 10000 2]replanned
    rebuilt<-untilState harness "pump rebuilt"5000((==C.ConstructionCompleted).C.constructionPhase . (`constructionJob`rebuiltId))resupplied
    operated<-commands harness[AssignWorkers(W.OperateFacility rebuiltId)1(s01Builders descriptor),OrderProduction rebuiltId]rebuilt
    extracted<-untilState harness "new pump real extraction"2000(\world->physical world(Owner MachineOutput rebuiltId)Water>=60000)operated
    milestone "rebuilt pump extracted source"extracted
    let farmInput=Owner MachineInput(s01Farm descriptor);kitchenInput=Owner MachineInput(s01Kitchen descriptor)
    water<-sourceWith descriptor extracted Water 190000;rationStock<-sourceWith descriptor extracted Ration 60000;fuel<-sourceWith descriptor extracted Fuel 1000
    growing<-commands harness[RequestDelivery(Owner MachineOutput rebuiltId)farmInput Water 60000 2,RequestDelivery water kitchenInput Water 10000 2,RequestDelivery fuel kitchenInput Fuel 1000 2,RequestDelivery water(s01Pantry descriptor)Water 120000 0,RequestDelivery rationStock(s01Pantry descriptor)Ration 60000 0,OrderProduction(s01Farm descriptor)]extracted
    grown<-untilState harness "actual farm crop output"18000(\world->physical world(Owner MachineOutput(s01Farm descriptor))Crops>=60000)growing
    cooking<-commands harness[RequestDelivery(Owner MachineOutput(s01Farm descriptor))kitchenInput Crops 20000 2,OrderProduction(s01Kitchen descriptor)]grown
    cooked<-untilState harness "actual kitchen ration output"6000(\world->physical world(Owner MachineOutput(s01Kitchen descriptor))Ration>=18000)cooking
    fed<-witnessFreshRation harness descriptor cooked
    let ticksElapsed world=let SimTick n=simTick world;SimTick start=simTick progressed in toInteger(n-start)
    final<-untilState harness "10000 actual saved suffix ticks"10000((>=10000).ticksElapsed)fed
    assert "actual life consumption"(M.findWithDefault 0(Ration,LivingConsumed)(invLedger(worldInventory final))>0&&M.findWithDefault 0(Water,LivingConsumed)(invLedger(worldInventory final))>0)
    let xp skill=sum[W.skillExperience value+28800*W.skillLevel value|worker<-M.elems(W.workforceWorkers(m1Workforce(stateOf final))),Just value<-[M.lookup skill(W.workerSkills worker)]]
    assert "real construction/gather/process/transport XP"(all((>0).xp)[W.BuildSkill,W.GatherSkill,W.ProcessSkill,W.TransportSkill])
    suffix<-readIORef shadow
    assert "saved suffix10000 ticks confirmed"(maybe False((>=10000).snd)suffix)
    milestone "construction supply life save-suffix"final
    total<-readIORef count
    putStrLn("S01_PLAYER native/Arena parity boundaries="++show total++" PASS (bounded S01-short, not66h campaign/usability)")
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= s01PlayerTests
