module CancellationProfileTests(cancellationProfileTests) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.ContentCodec
import Colony.Inventory
import Colony.Jobs
import Colony.JSON
import Colony.Maintenance
import Colony.Migrate
import Colony.Presentation(productionCancellation,obj,str,num,arr)
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(forM_,unless,foldM)
import Data.Either(isLeft)
import Data.List(sortOn)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)

assert :: String -> Bool -> IO()
assert label condition=unless condition(fail("Cancellation profiles: "++label))
right :: Show e => Either e a -> IO a
right=either(fail.show)pure

tx :: TxId
tx=TxId 1 1(BoundarySeq 0)P1 0

-- Construct a valid running batch; manual credit is an explicit state-unit
-- fixture, not a claim that these tests simulated its earlier work ticks.
fixture :: Content -> String -> [(Resource,[Integer])] -> IO(World,Job)
fixture content rid quantities=do
  ((site,job),inv)<-right $ runInventory(do
    colony<-freshId
    sid<-freshId
    let input=Owner MachineInput sid;output=Owner MachineOutput sid
    addStorage input(Storage 400000 Nothing colony)
    addStorage output(Storage 400000 Nothing colony)
    forM_ quantities $ \(r,qs)->forM_(zip[0..]qs) $ \(ordinal,q)->do
      _<-mintLot tx InitialGrant Nothing r q input(SimTick 0)Nothing("split-"++show r++"-"++show(ordinal::Integer))
      pure()
    planned<-planJob content rid input output M.empty
    job<-startJob content(SimTick 0)planned
    pure(Site sid rid input output M.empty 0 False,job))(emptyInventory content)
  let world=(initialWorld content){worldMode=Paused,worldInventory=inv,worldJobs=M.singleton(jobId job)job,worldSites=M.singleton(siteId site)site,worldJobSites=M.singleton(jobId job)(siteId site)}
  right(validateWorld world)
  pure(world,job)

setJob :: Job -> World -> World
setJob job world=world{worldJobs=M.insert(jobId job)job(worldJobs world)}
loss :: Resource -> Inventory -> Integer
loss r inv=M.findWithDefault 0(r,CancelledProcessLoss)(invLedger inv)
physical :: Resource -> Inventory -> Integer
physical r inv=sum[qtyValue(lotQty l)|l<-M.elems(invLots inv),lotResource l==r]

compositions :: Integer -> [[Integer]]
compositions 0=[[]]
compositions n=[k:rest|k<-[1..n],rest<-compositions(n-k)]

cancellationProfileTests :: Content -> IO()
cancellationProfileTests content=do
  (baseline,baseJob)<-fixture content "tools" [(Metal,[10000]),(Parts,[8])]
  (split,splitJob)<-fixture content "tools" [(Metal,[1,9999]),(Parts,replicate 8 1)]
  let half j=j{jobProgress=jobRequired j `div` 2}
  (_,legacyOne)<-right(runInventory(cancelJob "red-dune-reference-0" tx(half baseJob))(worldInventory baseline))
  (_,legacyEight)<-right(runInventory(cancelJob "red-dune-reference-0" tx(half splitJob))(worldInventory split))
  (_,correctedEight)<-right(runInventory(cancelJob "red-dune-reference-2" tx(half splitJob))(worldInventory split))
  assert "old parts split counterexample preserved:4 versus0"(loss Parts legacyOne==4&&loss Parts legacyEight==0)
  assert "corrected parts8 singleton pieces lose4; metal loses5000"(loss Parts correctedEight==4&&loss Metal correctedEight==5000)
  putStrLn "Cancellation baseline: legacy parts[8] loss4; parts[1x8] loss0; corrected profile2 loss4 and metal5000"
  -- Exhaust all 128 ordered positive compositions of Parts8. Metal also has
  -- single, uneven two-way, and three-way partitions. An independent Integer
  -- resource oracle never calls a production rounding/selection helper.
  let partitions=compositions 8
      progress required=[0,1,required `div` 8-1,required `div` 8,required `div` 8+1,required `div` 4,required `div` 2-1,required `div` 2,required `div` 2+1,required-1,required]
  forM_(zip[0..]partitions) $ \(ordinal,parts)->do
    let metals=case ordinal `mod` (3::Integer)of 0->[10000];1->[1,9999];_->[7,13,9980]
    (world,job)<-fixture content "tools" [(Metal,metals),(Parts,parts)]
    forM_(progress(jobRequired job)) $ \credit->do
      let current=job{jobProgress=credit}
      (ended,inv)<-right(runInventory(cancelJob "red-dune-reference-2" tx current)(worldInventory world))
      forM_[(Parts,8),(Metal,10000)] $ \(resource,q)->do
        let expected=q*credit `div` jobRequired current
        assert "split-independent per-resource loss"(loss resource inv==expected)
        assert "loss+physical exactly original, no creation"(physical resource inv+expected==q)
      assert "terminal exactly once; reservations empty"(jobPhase ended==Cancelled&&jobTerminalCount ended==1&&M.null(invCapacity inv)&&M.null(invQuantity inv)&&M.null(invNatural inv))
      assert "repeated cancel refuses without a second debit"(runInventory(cancelJob "red-dune-reference-2" tx ended)inv==Left AlreadyTerminal)
  frozenLegacyReplay
  fefoCase content
  rollbackCase content
  maintenanceAgreement content
  migrationReplay content split(half splitJob)
  putStrLn "CancellationProfileTests PASS:128 Parts partitions x11 progress boundaries=1408 mixed-resource transactions; FEFO expiry/born/ID ties; rollback; maintenance agreement; profiles0/1 legacy and2/3 corrected; branch migration, catalog snapshots, replay/Arena/UI match"

fefoCase :: Content -> IO()
fefoCase content=do
  (world,job)<-fixture content "cook"[(Crops,replicate 5 4000),(Water,[10000]),(Fuel,[1000])]
  let inv=worldInventory world
      crops=[l|l<-M.elems(invLots inv),lotResource l==Crops]
      metadata=[(Just(SimTick 300),SimTick 1),(Just(SimTick 200),SimTick 2),(Just(SimTick 200),SimTick 1),(Nothing,SimTick 0),(Just(SimTick 200),SimTick 1)]
      edits=[l{lotExpires=expiry,lotBorn=born}|(l,(expiry,born))<-zip crops metadata]
      varied=inv{invLots=foldr(\l->M.insert(lotId l)l)(invLots inv)edits}
      -- Independent lexicographic oracle: finite expiry before none, then born,
      -- then ID. 10k loss exhausts first two4k lots and removes2k from the third.
      order l=(maybe(1::Integer,0)(\(SimTick tick)->(0,toInteger tick))(lotExpires l),lotBorn l,lotId l)
      ordered=sortOn order edits
      expected=M.fromList[(lotProvenance l,(q,lotBorn l,lotExpires l))|(l,q)<-zip ordered[0,0,2000,4000,4000],q>0]
  (_,result)<-right(runInventory(cancelJob "red-dune-reference-2" tx(job{jobProgress=jobRequired job `div` 2}))varied)
  let actual=M.fromList[(lotProvenance l,(qtyValue(lotQty l),lotBorn l,lotExpires l))|l<-M.elems(invLots result),lotResource l==Crops]
  assert "FEFO consumes expiry/born/ID ties and preserves survivor metadata"(actual==expected&&loss Crops result==10000)

rollbackCase :: Content -> IO()
rollbackCase content=do
  (world,job)<-fixture content "cook"[(Crops,[20000]),(Water,[10000]),(Fuel,[1000])]
  let inv=worldInventory world
      limited=inv{invStorage=M.adjust(\s->s{storageCapacity=reservedWeight inv(jobOutput job)})(jobOutput job)(invStorage inv)}
      current=job{jobProgress=jobRequired job `div` 4}
      before=(setJob current world){worldInventory=limited,worldRuleset="red-dune-reference-2"}
      (after,out)=pureStep(cancelBoundary before current)before
  right(validateWorld before)
  assert "capacity refusal after simulated partial losses is fully atomic"(worldInventory after==limited&&worldJobs after==worldJobs before&&null(outputEvents out)&&null(outputDiagnostics out)&&map receiptOutcome(outputReceipts out)==[CommandFailed ReturnCapacityFull])
  let preview=M.fromList(productionCancellation before current)
  assert "UI refusal matches core capacity refusal"(M.lookup "cancelAllowed" preview==Just(JBool False)&&M.lookup "cancelFailure" preview==Just(num ReturnCapacityFull))

maintenanceAgreement :: Content -> IO()
maintenanceAgreement content=do
  forM_[[8],replicate 8 1,[1,2,5]] $ \parts->do
    ((target,source,state),inv)<-right $ runInventory(do
      colony<-freshId;target<-freshId;storage<-freshId
      let source=Owner Warehouse storage
      addStorage source(Storage 2000000 Nothing colony)
      forM_(zip[1..]parts) $ \(ordinal,q)->mintLot tx InitialGrant Nothing Parts q source(SimTick 0)Nothing(show(ordinal::Integer))>>pure()
      facility<-either throwTx pure(newFacility content target "pump")
      pure(target,source,emptyMaintenance{maintenanceFacilities=M.singleton target(facility{facilityCondition=0})}))(emptyInventory content)
    ((ident,planned),reserved)<-right(runInventory(planMaintenance content(SimTick 0)target source source state)inv)
    (started,wip)<-right(runInventory(startMaintenance ident 1 planned)reserved)
    let job=maintenanceJobs started M.! ident
    assert "repair uses same Parts8 input as tool example"(maintenanceParts job==8)
    forM_[0,1,maintenanceRequired job `div` 4,maintenanceRequired job `div` 2,maintenanceRequired job-1,maintenanceRequired job] $ \credit->do
      let updated=started{maintenanceJobs=M.insert ident(job{maintenanceProgress=credit})(maintenanceJobs started)}
      (_,result)<-right(runInventory(cancelMaintenance tx ident updated)wip)
      assert "maintenance uses the identical resource-level Parts loss"(loss Parts result==8*credit `div` maintenanceRequired job)

cancelBoundary :: World -> Job -> NativeInput
cancelBoundary world job=Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)False(worldAuthority world)(worldRuleset world))
  [OrderedCommand 0(CommandId(worldId world)1(participantEpoch(worldParticipants world M.!1))1)(CancelProduction(jobId job))][]

migrationReplay :: Content -> World -> Job -> IO()
migrationReplay content raw job=do
  let old=setJob job raw
  oldBytes<-right(encodeCheckpoint defaultCheckpointMeta old)
  (_,restored)<-right(decodeCheckpoint oldBytes)
  corrected<-right(applyCancellationCorrection 2 restored)
  assert "migration preserves all fields except explicit branch/profile"(corrected{branchId=branchId old,worldRuleset=worldRuleset old}==old)
  assert "same branch/zero/repeated migration rejected"(isLeft(applyCancellationCorrection 1 old)&&isLeft(applyCancellationCorrection 0 old)&&isLeft(applyCancellationCorrection 3 corrected))
  let cook=contentRecipes content M.!"cook"
      cookV2=cook{recipeInputs=M.insert Fuel 800(recipeInputs cook),recipeOutputs=M.insert Ration 19000(recipeOutputs cook)}
      v2=content{contentRecipes=M.insert "cook" cookV2(contentRecipes content)}
  legacyV2<-right(applyCookBalanceV2 3 v2 old)
  correctedV2<-right(applyCancellationCorrection 4 legacyV2)
  correctionThenBalance<-right(applyCookBalanceV2 4 v2 corrected)
  assert "balance/correction order commute; snapshot retains old catalog"(correctedV2==correctionThenBalance&&jobSnapshotContentId(worldJobs correctedV2 M.!jobId job)==Just knownV1ContentId)
  forM_[old,corrected,legacyV2,correctedV2] $ \start->do
    right(validateWorld start)
    bytes<-right(encodeCheckpoint defaultCheckpointMeta start)
    (_,saved)<-right(decodeCheckpoint bytes)
    let input@(Boundary context commands management)=cancelBoundary saved job
        (end,out)=pureStep input saved
        legacy=worldRuleset saved `elem`["red-dune-reference-0","red-dune-reference-1"]
        expectedParts=if legacy then 0 else 4
    assert "selected profile executes expected loss"(null(outputDiagnostics out)&&loss Parts(worldInventory end)==expectedParts)
    (arena,arenaOut)<-right(play Colony(RecordedBoundary context(map commandId commands)management)(singleton 1(OrderedBatch commands))saved)
    assert "actual Arena cancellation is native cancellation"(arena==end&&arenaOut==out)
    let preview=M.fromList(productionCancellation saved job)
        entries=[obj[("resource",str(resourceKey r)),("quantity",num(loss r(worldInventory end)))]|r<-allResources,loss r(worldInventory end)>0]
    assert "UI estimates selected profile kernel, not resource formula in renderer"(M.lookup "cancelLoss" preview==Just(arr entries))
    digest<-right(canonicalStateHash end)
    catalog<-right(contentHash(worldContent saved))
    let replay=Replay(ReplayHeader(worldId saved)(branchId saved)(sha256 bytes)(worldRuleset saved)catalog "RDF-RNG-1" 1 "cancellation-profile-fixture" 1)[ReplayFrame input out digest]
    wire<-right(encodeReplay replay)
    decoded<-right(decodeReplay wire)
    final<-foldM(\current frame->do
      let(next,result)=pureStep(replayInput frame)current
      stateHash<-right(canonicalStateHash next)
      assert "saved-profile replay output and hash equal"(result==replayOutput frame&&stateHash==replayStateHash frame)
      pure next)saved(replayFrames decoded)
    assert "full replay state and unchanged source checkpoint"(final==end&&encodeCheckpoint defaultCheckpointMeta old==Right oldBytes)
    let changed=replay{replayHeader=(replayHeader replay){replayRulesetId=if legacy then "red-dune-reference-2" else "red-dune-reference-0"}}
    assert "relabeling old replay without transition fails codec"(isLeft(encodeReplay changed))
  let(oldInputWorld,rejected)=pureStep(cancelBoundary old job)corrected
  assert "old replay input cannot run against migrated branch/profile"(oldInputWorld==corrected&&not(null(outputDiagnostics rejected))&&null(outputReceipts rejected))

-- These bytes were produced by compiling the immutable0.2 source separately.
-- Check both source integrity and actual current-kernel legacy-profile replay.
frozenLegacyReplay :: IO()
frozenLegacyReplay=do
  beforeBytes<-BS.readFile "evidence/cancellation-compat/frozen-0.2/before.cbor"
  inputBytes<-BS.readFile "evidence/cancellation-compat/frozen-0.2/input.cbor"
  afterBytes<-BS.readFile "evidence/cancellation-compat/frozen-0.2/after.cbor"
  outputText<-readFile "evidence/cancellation-compat/frozen-0.2/output.txt"
  assert "frozen0.2 checkpoint fingerprint"(sha256Hex beforeBytes=="f471fa996052ebc67af25cff8f27e2f6439cebe4e672a4a2c4a76990343fb76e")
  assert "frozen0.2 native input fingerprint"(sha256Hex inputBytes=="d2b9b1b9ca9c49e3f6ab17d7abd31bea2b451d8d5caf3b67830a0977f2edfcfe")
  assert "frozen0.2 result fingerprint"(sha256Hex afterBytes=="6b8a7d846db50fcc2781cd8f583cbe0121205affa9a5538ca791d0bc0a29ed9c")
  (_,world)<-right(decodeCheckpoint beforeBytes)
  native<-right(decodeNativeInput inputBytes)
  let (next,out)=pureStep native world
  encoded<-right(encodeCheckpoint defaultCheckpointMeta next)
  assert "0.3 executes0.2 legacy trace with identical canonical bytes and output"(encoded==afterBytes&&show out++"\n"==outputText)
