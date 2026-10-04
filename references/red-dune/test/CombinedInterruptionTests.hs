{-# LANGUAGE BangPatterns, DeriveGeneric #-}
module CombinedInterruptionTests(combinedInterruptionTests) where
import Colony.Arena
import Colony.Codec
import Colony.Codec.Value(ValueCodec,encodeValue,decodeValue)
import Colony.CombinedFixture
import Colony.Content
import Colony.ContentCodec(knownV1ContentId,knownV2ContentId)
import Colony.Jobs
import Colony.Migrate
import Colony.Save
import Colony.Scheduler
import Colony.SupplyChainFixture
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.Concurrent(forkFinally,newEmptyMVar,takeMVar,putMVar)
import Control.DeepSeq(force)
import Control.Exception(evaluate)
import Control.Monad(unless,foldM)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.Word(Word64)
import Game.Arena(play,singleton,observe)
import GHC.Clock(getMonotonicTimeNSec)
import GHC.Generics(Generic)
import System.Directory(createDirectoryIfMissing)
import System.IO(Handle,IOMode(WriteMode),withFile,hPutStrLn,hFlush,stdout)

assert :: String -> Bool -> IO()
assert label condition=unless condition(fail("B01 combined: "++label))
right :: Show e => Either e a -> IO a
right=either(fail.show)pure

-- External content migration is an explicit typed trace action between native
-- replay segments, not a disguised World edit or an invented player command.
data B01Transition = CookBalanceTransition
  { transitionWorld :: !Word64, transitionFromBranch :: !Word64, transitionToBranch :: !Word64
  , transitionFromProfile :: !String, transitionToProfile :: !String
  , transitionBeforeHash :: !BS.ByteString, transitionAfterHash :: !BS.ByteString
  , transitionOldContent :: !BS.ByteString, transitionNewContent :: !BS.ByteString }
  deriving(Eq,Show,Generic)
instance ValueCodec B01Transition

captureTransition :: FilePath -> Content -> World -> World -> IO B01Transition
captureTransition directory nextContent before after=do
  beforeHash<-right(canonicalStateHash before)
  afterHash<-right(canonicalStateHash after)
  oldContent<-right(contentHash(worldContent before))
  newContent<-right(contentHash nextContent)
  let transition=CookBalanceTransition(worldId before)(branchId before)(branchId after)(worldRuleset before)(worldRuleset after)beforeHash afterHash oldContent newContent
  bytes<-right(encodeValue transition)
  BS.writeFile(directory++"/content-transition.cbor")bytes
  stored<-right(decodeValue bytes)
  replayed<-replayTransition nextContent stored before
  assert "recorded migration action independently decodes/replays"(replayed==after&&stored==transition)
  writeFile(directory++"/content-transition.txt")(show transition++"\n")
  pure stored

replayTransition :: Content -> B01Transition -> World -> IO World
replayTransition nextContent transition before=do
  beforeHash<-right(canonicalStateHash before)
  oldContent<-right(contentHash(worldContent before))
  newContent<-right(contentHash nextContent)
  assert "content-transition source hash/world/branch/profile"(beforeHash==transitionBeforeHash transition&&worldId before==transitionWorld transition&&branchId before==transitionFromBranch transition&&worldRuleset before==transitionFromProfile transition)
  assert "content-transition catalog fingerprints"(oldContent==transitionOldContent transition&&newContent==transitionNewContent transition)
  after<-right(applyCookBalanceV2(transitionToBranch transition)nextContent before)
  afterHash<-right(canonicalStateHash after)
  assert "content-transition target hash/branch/profile"(afterHash==transitionAfterHash transition&&worldRuleset after==transitionToProfile transition)
  pure after

-- Only strict inputs/outputs/digests are retained. No list of historical Worlds.
data Run = Run {live :: !World, reverseFrames :: ![ReplayFrame]}

data Context = Context { traceHandle :: !Handle, milestoneHandle :: !Handle }

mark :: Context -> String -> World -> IO()
mark context label world=do
  let text=show(simTick world)++" boundary="++show(boundarySeq world)++" branch="++show(branchId world)++" profile="++worldRuleset world++" "++label
  strict<-evaluate(force text)
  hPutStrLn(milestoneHandle context)strict
  hFlush(milestoneHandle context)
  putStrLn("B01 "++strict)
  hFlush stdout

ordered :: World -> [Command] -> [OrderedCommand]
ordered world bodies=let epoch=participantEpoch(worldParticipants world M.!1);first=M.findWithDefault 0(1,epoch)(worldHighWater world)+1 in
  [OrderedCommand ordinal(CommandId(worldId world)1 epoch(first+ordinal))body|(ordinal,body)<-zip[0..]bodies]

one :: Context -> [Command] -> Run -> IO(Run,ColonyOutput)
one context bodies current=do
  let world=live current
      commands=ordered world bodies
      native@(Boundary header _ _)=supplyChainBoundary world commands
  (next,out)<-evaluate(force(pureStep native world))
  (arena,arenaOut)<-right(play Colony(RecordedBoundary header(map commandId commands)[])(singleton 1(OrderedBatch commands))world) >>= evaluate.force
  assert "native/Arena exact World and output"(next==arena&&out==arenaOut)
  assert("no kernel diagnostics "++show(outputDiagnostics out))(null(outputDiagnostics out))
  assert("commands actually apply "++show(map receiptOutcome(outputReceipts out)))(all(\r->case receiptOutcome r of Applied _->True;_->False)(outputReceipts out))
  digest<-right(canonicalStateHash next) >>= evaluate.force
  inputNF<-evaluate(force native)
  frame<-evaluate(ReplayFrame inputNF out digest)
  hPutStrLn(traceHandle context)(show native++" => "++show out++" hash="++hex digest)
  let !priorFrames=reverseFrames current
  pure(Run next(frame:priorFrames),out)

hex :: BS.ByteString -> String
hex=concatMap(\b->[digits!!fromIntegral(b `div` 16),digits!!fromIntegral(b `mod` 16)]).BS.unpack
  where digits="0123456789abcdef"

untilWorld :: Context -> String -> Word64 -> (World->Bool) -> Run -> IO Run
untilWorld context label budget predicate=go budget
  where
    go remaining !current
      | predicate(live current)=pure current
      | remaining==0=fail("B01 bound exceeded: "++label++" at "++show(simTick(live current)))
      | otherwise=fst <$> one context [] current >>= go(remaining-1)

advance :: Context -> Word64 -> Run -> IO Run
advance context count current=foldM(\r _->fst <$> one context [] r)current[1..count]

firstApplied :: ColonyOutput -> IO EntityId
firstApplied out=case map receiptOutcome(outputReceipts out)of [Applied(Just ident)]->pure ident;other->fail("expected one applied ID: "++show other)

jobAt :: EntityId -> World -> Job
jobAt ident world=worldJobs world M.!ident

atOwner :: World -> Owner -> Resource -> Integer
atOwner world owner resource=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory world)),lotOwner lot==owner,lotResource lot==resource]
freeAt :: World -> Owner -> Resource -> Integer
freeAt world owner resource=observedFree(observe Colony 1 world)owner resource

startOldBatch :: Context -> SupplyChainDescriptor -> Run -> IO(EntityId,Run)
startOldBatch context descriptor=go initialSupplyChainPolicy(12000::Word64)
  where
    go policy budget current=case[jobId job|job<-M.elems(worldJobs(live current)),jobRecipe job=="cook",jobPhase job==Running]of
      [ident]->pure(ident,current)
      _|budget==0->fail "B01 initial real supply chain did not start cook"
       |otherwise->do
         let(nextPolicy,commands)=supplyChainCommands descriptor(observe Colony 1(live current))policy
         (next,_)<-one context(map commandBody commands)current
         go nextPolicy(budget-1)next

-- Save captures one actual P10 state. While the real POSIX worker commits its
-- bytes,10 more native boundaries execute. Reload then replays precisely that
-- suffix and must catch up with uninterrupted execution at every output/hash.
saveWhileAdvancing :: Context -> FilePath -> Run -> IO(Run,World,BS.ByteString)
saveWhileAdvancing context directory current=do
  createDirectoryIfMissing True directory
  let capturedWorld=live current
      identity=identityFor(Epoch "b01-controlled-single-session" 1)capturedWorld
      ticket=SaveTicket identity 1 ManualSave
      meta=CheckpointMeta 1 Nothing "b01-combined-interruption"
  captured<-right(captureSnapshot ticket meta capturedWorld)
  adapter<-nativeAdapter
  finished<-newEmptyMVar
  _<-forkFinally(nativeSave adapter directory(pure identity)captured)(putMVar finished)
  advanced<-advance context 10 current
  result<-takeMVar finished >>= right
  receipt<-right(saveCompletion result)
  assert "native commit phases and captured tick"(saveProgress result==[Captured,Written,Flushed,Renamed,ManifestCommitted,CallbackAccepted]&&committedTick receipt==simTick capturedWorld&&simTick(live advanced)>committedTick receipt)
  recovery<-recoverCheckpoints directory
  generation<-maybe(fail "native save not automatically recoverable")pure(recoveryAutomatic recovery)
  loaded<-loadGeneration directory generation
  assert "native generation decode is exact captured World"(loaded==capturedWorld)
  originalBytes<-BS.readFile(directory++"/"++generationFile generation)
  let delta=reverse(take 10(reverseFrames advanced))
  caught<-foldM replayFrame loaded delta
  assert "save/reload catches live progress without skipping10 boundaries"(caught==live advanced)
  mark context("native save/reload while Return and outage: phases="++show(saveProgress result)++" captured="++show(simTick capturedWorld))(live advanced)
  pure(advanced,loaded,originalBytes)

replayFrame :: World -> ReplayFrame -> IO World
replayFrame world frame=do
  (next,out)<-evaluate(force(pureStep(replayInput frame)world))
  digest<-right(canonicalStateHash next)
  assert "replay output/hash at every saved boundary"(out==replayOutput frame&&digest==replayStateHash frame)
  pure next

saveMigrated :: FilePath -> World -> IO World
saveMigrated directory world=do
  createDirectoryIfMissing True directory
  let identity=identityFor(Epoch "b01-controlled-single-session" 1)world
      ticket=SaveTicket identity 2 ManualSave
  captured<-right(captureSnapshot ticket(CheckpointMeta 1 Nothing "b01-migrated-branch")world)
  adapter<-nativeAdapter
  result<-nativeSave adapter directory(pure identity)captured
  _<-right(saveCompletion result)
  recovery<-recoverCheckpoints directory
  generation<-maybe(fail "migrated generation absent")pure(recoveryAutomatic recovery)
  loaded<-loadGeneration directory generation
  assert "migrated native branch save/load exact"(loaded==world)
  pure loaded

replaySegment :: FilePath -> String -> World -> Run -> IO World
replaySegment directory label start result=do
  bytes<-right(encodeCheckpoint defaultCheckpointMeta start)
  contentId<-right(contentHash(worldContent start))
  let frames=reverse(reverseFrames result)
      replay=Replay(ReplayHeader(worldId start)(branchId start)(sha256 bytes)(worldRuleset start)contentId "RDF-RNG-1" 1 "B01-combined-scenario" 1)frames
  wire<-right(encodeReplay replay)
  BS.writeFile(directory++"/"++label++"-checkpoint.cbor")bytes
  BS.writeFile(directory++"/"++label++"-replay.cbor")wire
  decoded<-right(decodeReplay wire)
  (_,loaded)<-right(decodeCheckpoint bytes)
  replayed<-foldM replayFrame loaded(replayFrames decoded)
  assert("full segment exact state "++label)(replayed==live result)
  putStrLn("B01 segment="++label++" frames="++show(length frames)++" replayBytes="++show(BS.length wire))
  pure replayed

combinedInterruptionTests :: Content -> IO()
combinedInterruptionTests content=do
  stamp<-getMonotonicTimeNSec
  let directory="evidence/b01/run-"++show stamp
  createDirectoryIfMissing True directory
  withFile(directory++"/native-trace.log")WriteMode $ \trace->withFile(directory++"/milestones.log")WriteMode $ \milestones->do
    let context=Context trace milestones
    (descriptor,fuelStore,initial)<-right(combinedFixture content)
    let generator=Owner MachineInput(supplyGenerator descriptor)
        kitchenInput=Owner MachineInput(supplyKitchen descriptor)
        kitchenOutput=Owner MachineOutput(supplyKitchen descriptor)
        farmOutput=Owner MachineOutput(supplyFarm descriptor)
        pumpOutput=Owner MachineOutput(supplyPump descriptor)
        pantry=last(supplyPantries descriptor)
    assert "explicit initial fuel layout"(atOwner initial generator Fuel==2000&&atOwner initial fuelStore Fuel==48000)
    (oldId,running)<-startOldBatch context descriptor(Run initial [])
    mark context "oldv1 cook started after actual extraction/grow/road inputs"(live running)
    outage<-untilWorld context "generator fuel exhausted" 200(\w->atOwner w generator Fuel==0)running
    stalled<-advance context 20 outage
    assert "power shortage freezes physical old WIP"(jobProgress(jobAt oldId(live outage))==jobProgress(jobAt oldId(live stalled))&&jobPhase(jobAt oldId(live stalled))==Running&&jobBlocked(jobAt oldId(live stalled))==Just(InvalidReference "NoPower"))
    assert "old immutable snapshot exists before interruption"(jobSnapshotContentId(jobAt oldId(live stalled))==Just knownV1ContentId)
    mark context "real fuel exhaustion stops old cook"(live stalled)
    (requested,requestOut)<-one context[RequestDelivery fuelStore generator Fuel 36000 1]stalled
    interruptedRequest<-firstApplied requestOut
    let carrying w=any(\shipment->shipmentKind shipment==DeliveryChild interruptedRequest&&shipmentStatus shipment==ShipmentCarrying&&case vehiclePosition(transportVehicles(worldTransport w)M.!shipmentVehicle shipment)of Traversing{}->True;_->False)(M.elems(transportShipments(worldTransport w)))
    loaded<-untilWorld context "fuel shipment physically on road" 500 carrying requested
    (cancelled,_)<-one context[CancelDelivery interruptedRequest]loaded
    let returns w=[shipment|shipment<-M.elems(transportShipments(worldTransport w)),case shipmentKind shipment of ReturnShipment _->True;_->False]
    assert "loaded cancel produces physical Return cargo"(any((==ShipmentCarrying).shipmentStatus)(returns(live cancelled))&&atOwner(live cancelled)generator Fuel==0)
    mark context "loaded supply cancelled; Return retains36000 fuel while cook remains unpowered"(live cancelled)
    (advanced,capturedWorld,sourceBytes)<-saveWhileAdvancing context(directory++"/source-save")cancelled
    assert "saved WIP progress survived moving Return suffix"(jobProgress(jobAt oldId capturedWorld)==jobProgress(jobAt oldId(live advanced)))
    let cook=contentRecipes content M.!"cook"
        nextCook=cook{recipeInputs=M.insert Fuel 800(recipeInputs cook),recipeOutputs=M.insert Ration 19000(recipeOutputs cook)}
        nextContent=content{contentRecipes=M.insert "cook" nextCook(contentRecipes content)}
    migrated<-right(applyCookBalanceV2 2 nextContent(live advanced))
    assert "migration preserves old physical WIP/snapshot and all unrelated state"(migrated{branchId=branchId(live advanced),worldRuleset=worldRuleset(live advanced),worldContent=worldContent(live advanced)}==live advanced)
    recordedTransition<-captureTransition directory nextContent(live advanced)migrated
    restored<-saveMigrated(directory++"/new-branch-save")migrated
    mark context "exact two-field recipe update committed on new branch, old batch snapshot unchanged"restored
    returned<-untilWorld context "cancelled cargo actually returned" 1000(\w->any((==ShipmentReturned).shipmentStatus)(returns w))(Run restored [])
    assert "all cancelled fuel returned rather than delivered late"(atOwner(live returned)fuelStore Fuel==48000&&atOwner(live returned)generator Fuel==0)
    (resupply,_)<-one context[RequestDelivery fuelStore generator Fuel 36000 1,OrderProduction(supplyPump descriptor),RequestDelivery farmOutput kitchenInput Crops 20000 1,RequestDelivery fuelStore kitchenInput Fuel 800 1]returned
    resumed<-untilWorld context "real delivered fuel restarts old batch" 1500(\w->jobProgress(jobAt oldId w)>jobProgress(jobAt oldId restored))resupply
    mark context "reissued physical supply arrives; old cook resumes"(live resumed)
    waterReady<-untilWorld context "third real extraction finishes" 1500(\w->freeAt w pumpOutput Water>=10000)resumed
    (waterSent,_)<-one context[RequestDelivery pumpOutput kitchenInput Water 10000 1]waterReady
    oldFinished<-untilWorld context "old cook completes withv1 output" 2000(\w->jobPhase(jobAt oldId w)==Completed)waterSent
    assert "old batch has not been silently balanced"(M.findWithDefault 0(Ration,RecipeOutput)(invLedger(worldInventory(live oldFinished)))==18000)
    mark context "old batch completed:1000 fuel input,18000 ration output"(live oldFinished)
    newInputs<-untilWorld context "real new recipe inputs arrive" 2000(\w->freeAt w kitchenInput Crops>=20000&&freeAt w kitchenInput Water>=10000&&freeAt w kitchenInput Fuel>=800)oldFinished
    (newStart,_)<-one context[OrderProduction(supplyKitchen descriptor),RequestDelivery kitchenOutput pantry Ration 18000 1,RequestDelivery fuelStore generator Fuel 10000 1]newInputs
    let newJobs=[jobId job|job<-M.elems(worldJobs(live newStart)),jobRecipe job=="cook",jobId job/=oldId]
    newId<-case newJobs of [ident]->pure ident;_->fail "new cook did not start uniquely"
    assert "new job snapshot binds catalogv2"(jobSnapshotContentId(jobAt newId(live newStart))==Just knownV2ContentId)
    mark context "new batch starts with800 fuel/19000 ration snapshot"(live newStart)
    newFinished<-untilWorld context "new cook completes" 2500(\w->jobPhase(jobAt newId w)==Completed)newStart
    (rationSent,_)<-one context[RequestDelivery kitchenOutput pantry Ration 19000 1]newFinished
    delivered<-untilWorld context "all uncancelled requests actually delivered" 2000(\w->all(\request->requestStatus request `elem`[RequestCompleted,RequestCancelled])(M.elems(transportRequests(worldTransport w))))rationSent
    final<-advance context 400 delivered
    let inventory=worldInventory(live final)
        ledger r reason=M.findWithDefault 0(r,reason)(invLedger inventory)
        fourthConsumed=37000-atOwner(live final)pantry Ration
    assert "two correct recipe outputs and exact old/new fuel inputs"(ledger Ration RecipeOutput==37000&&ledger Fuel RecipeInput==1800)
    assert "no hidden generator refuel; exact48000 actual burning"(ledger Fuel FuelBurned==48000&&atOwner(live final)generator Fuel==0&&atOwner(live final)fuelStore Fuel==1200)
    assert "three actual source extractions and no fresh food bootstrap"(ledger Water Extraction==180000&&fourthConsumed>0)
    assert "interrupted parent terminal stays cancelled"(requestStatus(transportRequests(worldTransport(live final))M.!interruptedRequest)==RequestCancelled)
    assert "all inventory and cross-domain invariants"(validateWorld(live final)==Right())
    unchanged<-BS.readFile(directory++"/source-save/"++generationFilename 1)
    assert "source save bytes never changed by replay/migration"(unchanged==sourceBytes)
    mark context("final ledger ration37000 fuelRecipe1800 fuelPower48000; fourth-colony consumed="++show fourthConsumed)(live final)
    replayedPrefix<-replaySegment directory "before-update" initial advanced
    replayedMigration<-replayTransition nextContent recordedTransition replayedPrefix
    assert "both replay segments join through the recorded migration action"(replayedMigration==restored)
    _<-replaySegment directory "after-update" replayedMigration final
    digest<-right(canonicalStateHash(live final))
    writeFile(directory++"/result.txt")("PASS\ninitialProfile="++worldRuleset initial++"\nfinalProfile="++worldRuleset(live final)++"\nfinalTick="++show(simTick(live final))++"\nfinalHash="++hex digest++"\nfourthColonyNewRationConsumed="++show fourthConsumed++"\n")
    writeFile "evidence/b01/latest-result-path.txt"(directory++"\n")
    putStrLn("CombinedInterruptionTests PASS: actual fuel outage + loaded Cancel/Return + native concurrent save/reload + immutable-old/exact-new recipe update in one scenario; native/Arena and both canonical replay segments; finalHash="++hex digest++"; evidence="++directory)
