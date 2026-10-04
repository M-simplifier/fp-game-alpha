{-# LANGUAGE ScopedTypeVariables #-}
module CheckpointLibraryTests (checkpointLibraryTests) where

import Colony.CheckpointLibrary
import Colony.Codec
import Colony.Codec.CBOR
import Colony.Content
import Colony.ContentCodec (knownV1ContentId,knownV2ContentId)
import Colony.Jobs
import Colony.Migrate
import Colony.Save
import Colony.RNG(initialRng)
import Colony.Session(bindRecordedSession)
import Colony.SessionTrace
import Colony.Scheduler (pureStep)
import Colony.Types
import Colony.Units (Resource(Fuel,Ration))
import Colony.World
import Control.Concurrent (forkIO,newEmptyMVar,putMVar,takeMVar)
import Control.Exception (bracket,throwIO)
import Control.Monad (forM_,replicateM,unless,void)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Either (isLeft)
import Data.List (isInfixOf,nub,sort)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Word (Word64)
import System.Directory (createDirectory,createDirectoryIfMissing,doesDirectoryExist,listDirectory,makeAbsolute,
                         removeFile,removePathForcibly,renameDirectory,renameFile)
import System.FilePath ((</>))
import System.IO (hClose,openBinaryTempFile,withBinaryFile,IOMode(WriteMode),hSetFileSize)
import System.Posix.Files (createNamedPipe,createSymbolicLink)
import System.Posix.Process (forkProcess,getProcessStatus,ProcessStatus(Exited),exitImmediately)
import System.Exit (ExitCode(ExitSuccess))
import Text.Read (readMaybe)

assert :: String -> Bool -> IO ()
assert label ok=unless ok(ioError(userError("CheckpointLibrary assertion: "++label)))
must :: Show e => Either e a -> IO a
must=either(ioError.userError.show)pure

-- Mutation and deletion are confined to a new unique directory per group.
-- Packaged compatibility fixture inputs are only read; they are never changed.
withTemp :: (FilePath -> IO a) -> IO a
withTemp=bracket acquire removePathForcibly
  where
    acquire=do
      (path,handle)<-openBinaryTempFile "." ".checkpoint-library-test-"
      hClose handle
      removeFile path
      createDirectory path
      makeAbsolute path

configAt :: FilePath -> LibraryConfig
configAt root=LibraryConfig(root </> "library") Nothing Nothing

loadPackaged :: String -> IO World
loadPackaged name=BS.readFile("evidence/migration-fixtures" </> name) >>= must . decodeCheckpoint >>= pure . snd

commit :: FilePath -> Word64 -> World -> IO ()
commit directory sequenceNo world=do
  createDirectoryIfMissing True directory
  let ident=identityFor(Epoch "checkpoint-library-tests" 1)world
      ticket=SaveTicket ident sequenceNo ManualSave
  captured<-must(captureSnapshot ticket(CheckpointMeta sequenceNo Nothing "checkpoint-library-focused")world)
  adapter<-nativeAdapter
  result<-nativeSave adapter directory(pure ident)captured
  void(must(saveCompletion result))

registered :: LibraryConfig -> World -> FilePath
registered config world=libraryRoot config </> ("world-"++show(worldId world)) </> ("branch-"++show(branchId world))

findEntry :: LibraryConfig -> Word64 -> IO Entry
findEntry config branch=do
  (entries,_)<-listLibrary config False >>= must
  case filter((==branch).entryBranchId)entries of
    [entry]->pure entry
    _->ioError(userError("expected one entry for branch "++show branch))

profile :: Word64 -> String
profile n="red-dune-reference-"++show n

balanceContent :: Content -> Content
balanceContent content=content{contentRecipes=M.adjust update "cook"(contentRecipes content)}
  where update recipe=recipe{recipeInputs=M.insert Fuel 800(recipeInputs recipe),recipeOutputs=M.insert Ration 19000(recipeOutputs recipe)}

-- Independent field expectations, not a repeated call to a migration helper.
assertPreserved :: String -> World -> World -> IO ()
assertPreserved label source target=do
  assert(label++" exact physical inventory and reservations")(worldInventory source==worldInventory target)
  assert(label++" exact job snapshots, content IDs and progress")(worldJobs source==worldJobs target)
  assert(label++" exact RNG, authority and participant roles")
    (worldRng source==worldRng target&&worldAuthority source==worldAuthority target&&worldParticipants source==worldParticipants target)
  assert(label++" exact history and high-water marks")
    (worldHighWater source==worldHighWater target&&worldReceipts source==worldReceipts target&&worldRecentEvents source==worldRecentEvents target)
  assert(label++" all fields except explicit branch/content/rules")
    (target{branchId=branchId source,worldContent=worldContent source,worldRuleset=worldRuleset source}==source)

traceCheck :: BS.ByteString -> RestoreAction -> World -> PreparedSource -> IO()
traceCheck sourceBytes action live prepared=do
  let authority="11111111-2222-4333-8444-555555555555"
  activated<-must(bindRecordedSession authority(preparedSourceBranch prepared)(preparedWorld prepared))
  liveHash<-must(canonicalStateHash live)
  record<-must(makeActivationRecord action sourceBytes liveHash activated)
  bytes<-must(encodeActivationRecord record)
  decoded<-must(decodeActivationRecord bytes)
  replayed<-must(replayActivation decoded live sourceBytes)
  assert "exact versioned interactive-activation replay for registered profile/schema/action"(decoded==record&&replayed==activated)
  assert "changed action cannot reauthorize a different target"(isLeft(replayActivation decoded{activationAction="unknown"}live sourceBytes))

profileTests :: Content -> World -> IO ()
profileTests content running=withTemp $ \root->do
  let config=configAt root
      expected=[(0,[(Restore,0),(Rules,4),(Balance,1),(RulesBalance,5)])
               ,(1,[(Restore,1),(Rules,5)])
               ,(2,[(Restore,2),(Rules,4),(Balance,3),(RulesBalance,5)])
               ,(3,[(Restore,3),(Rules,5)])
               ,(4,[(Restore,4),(Balance,5),(RulesBalance,5)])
               ,(5,[(Restore,5)])]
  forM_ expected $ \(n,actions)->do
    let source=running{branchId=n+1,worldRuleset=profile n,worldContent=if odd n then balanceContent content else content}
        directory=registered config source
    _<-must(canonicalWorldBytes source)
    commit directory 1 source
    entry<-findEntry config(n+1)
    bytes<-readEntry entry >>= must
    before<-BS.readFile(directory </> generationFilename 1)
    assert("profile "++show n++" exact action allowlist")(entryActions entry==map fst actions)
    forM_ [Restore,Rules,Balance,RulesBalance] $ \action->case lookup action actions of
      Nothing->assert "unavailable transformation rejects"(isLeft(prepareEntry entry action 101 bytes))
      Just targetProfile->do
        prepared<-must(prepareEntry entry action 101 bytes)
        let target=preparedWorld prepared
            expectedContent=if action `elem` [Balance,RulesBalance] then balanceContent content else worldContent source
        assert("profile "++show n++" "++actionId action++" exact target")
          (branchId target==101&&worldRuleset target==profile targetProfile&&worldContent target==expectedContent&&preparedSourceSchema prepared==3)
        assertPreserved("profile "++show n++" "++actionId action)source target
        traceCheck bytes action source prepared
        assert "descriptions include real preservation and changes"(not(null(preparedChanges prepared))&&not(null(preparedPreserved prepared)))
    assert "zero/same branch rejected"(isLeft(prepareEntry entry Restore 0 bytes)&&isLeft(prepareEntry entry Restore(n+1)bytes))
    assert "different supplied bytes rejected"(isLeft(prepareEntry entry Restore 101(BS.snoc bytes 0)))
    (originalMeta,_)<-must(decodeCheckpoint bytes)
    changedValidBytes<-must(encodeCheckpoint originalMeta source{worldRng=initialRng 987654321})
    assert "selected immutable bytes reject valid same-summary replacement"(bytes/=changedValidBytes&&isLeft(prepareEntry entry Restore 101 changedValidBytes))
    after<-BS.readFile(directory </> generationFilename 1)
    assert "source byte immutability across every action"(before==after)
    putStrLn("LIBRARY-PROFILE "++show n++" expected="++show[(actionId a,p)| (a,p)<-actions]++" inventory/snapshots/RNG/history/source-bytes/activation-CBOR-replay PASS")
  -- A genuinely started v2 snapshot, rather than merely relabeling old WIP.
  planned<-loadPackaged "planned-v3.cbor"
  updated<-must(applyCookBalanceV2 50(balanceContent content)planned)
  let header=BoundaryHeader(worldId updated)(branchId updated)(boundarySeq updated)True(worldAuthority updated)(worldRuleset updated)
      (started,out)=pureStep(Boundary header [] [])updated
      source=started{branchId=50,worldRuleset=profile 5}
      jobs=M.elems(worldJobs source)
  assert "real kernel started a v2 snapshot"(null(outputDiagnostics out)&&not(null jobs)&&all((==Just knownV2ContentId).jobSnapshotContentId)jobs)
  assert "archived old running fixture has v1 content IDs"(all((==Just knownV1ContentId).jobSnapshotContentId)(M.elems(worldJobs running)))
  commit(registered config source)1 source
  entry<-findEntry config 50
  bytes<-readEntry entry >>= must
  target<-preparedWorld <$> must(prepareEntry entry Restore 51 bytes)
  assertPreserved "running v2 snapshot" source target
  putStrLn "LIBRARY-RUNNING-SNAPSHOTS genuine old v1 and new v2 kernel snapshots preserved PASS"

legacyTests :: World -> IO ()
legacyTests running=withTemp $ \root->do
  let fixtureDir=root </> "compatibility"
      config=(configAt root){compatibilityFixtureDirectory=Just fixtureDir}
  createDirectory fixtureDir
  v1<-must(legacyV1Fixture running)
  v2<-must(legacyV2Fixture running)
  one<-must(encodeLegacyV1 v1)
  two<-must(encodeLegacyV2 v2)
  BS.writeFile(fixtureDir </> "running-wip-v1.cbor")one
  BS.writeFile(fixtureDir </> "running-wip-v2.cbor")two
  BS.writeFile(fixtureDir </> "arbitrary-not-registered.cbor")one
  (without,_)<-listLibrary config False >>= must
  assert "compatibility requires explicit opt-in"(null without)
  (entries,warnings)<-listLibrary config True >>= must
  assert "only two registered compatibility fixtures"(length entries==2&&null warnings&&all((==Compatibility).entryKind)entries)
  forM_ entries $ \entry->do
    bytes<-readEntry entry >>= must
    prepared<-must(prepareEntry entry Restore 200 bytes)
    let target=preparedWorld prepared
        sourceCore=if entrySchema entry==1 then v1Core v1 else v2Core v2
    assert "legacy source schema stays accurate"(preparedSourceSchema prepared==entrySchema entry)
    assert "legacy independent archived authority/RNG/job/history expectations"
      (worldAuthority target==legacyAuthority sourceCore&&worldRng target==legacyRng sourceCore
       &&worldJobs target==legacyJobs sourceCore&&worldHighWater target==legacyHighWater sourceCore
       &&worldParticipants target==legacyParticipants sourceCore&&worldReceipts target==legacyReceipts sourceCore)
    assert "legacy physical assets preserved against direct source totals"
      (assetTotals(worldInventory target)==if entrySchema entry==1 then v1Stock v1 else assetTotals(worldInventory running))
    assert "real sequential legacy result" . (==target) . migrationWorld =<< must(migrateLegacyBytes 200 bytes)
    forM_(entryActions entry) $ \action->do
      preparedAction<-must(prepareEntry entry action 201 bytes)
      let candidate=preparedWorld preparedAction
      traceCheck bytes action running preparedAction
      assert "legacy transformed source retains archived jobs and RNG"(worldJobs candidate==worldJobs target&&worldRng candidate==worldRng target)
      assert "legacy transformed source retains physical assets"(assetTotals(worldInventory candidate)==assetTotals(worldInventory target))
    putStrLn("LIBRARY-LEGACY V"++show(entrySchema entry)++" sequential migration, assets, jobs, RNG, history and all advertised actions/activation-CBOR-replay PASS")
  assert "legacy source files unchanged" . (==one) =<< BS.readFile(fixtureDir </> "running-wip-v1.cbor")
  assert "legacy source files unchanged" . (==two) =<< BS.readFile(fixtureDir </> "running-wip-v2.cbor")
  BS.writeFile(fixtureDir </> "running-wip-v1.cbor")(BS.init one)
  (remaining,rejections)<-listLibrary config True >>= must
  assert "bad compatibility fixture warning, never entry"(length remaining==1&&not(null rejections))
  BS.writeFile(fixtureDir </> "running-wip-v2.cbor")one
  (none,wrongLabel)<-listLibrary config True >>= must
  assert "fixture schema-label mismatch rejects"(null none&&length wrongLabel==2)
  putStrLn "LIBRARY-LEGACY corrupt fixture, explicit include flag and schema-label mismatch PASS"

catalogTests :: World -> IO ()
catalogTests running=withTemp $ \root->do
  let config=configAt root
      directory=registered config running
  commit directory 1 running
  candidate<-must(encodeCheckpoint(CheckpointMeta 2 Nothing "candidate")running)
  BS.writeFile(directory </> generationFilename 2)candidate
  (entries,warnings)<-listLibrary config False >>= must
  assert "native committed and orphan recovery candidates are distinct"
    (sort(map entryKind entries)==[Committed,Candidate]&&null warnings)
  let candidateEntry=head(filter((==Candidate).entryKind)entries)
  candidateBytes<-readEntry candidateEntry >>= must
  void(must(prepareEntry candidateEntry Restore 2 candidateBytes))
  report<-recoverCheckpoints directory
  generation<-case recoveryAutomatic report of Just g->pure g;_->ioError(userError "missing native committed")
  assert "catalog source agrees with real loadGeneration" . (==running) =<< loadGeneration directory generation
  let legacy=root </> "legacy"
  commit legacy 1 running
  (flat,_)<-listLibrary config{legacyFlatDirectory=Just legacy}False >>= must
  assert "registered and read-only legacy entries have unique opaque handles"
    (length flat==3&&length(nub(map entryId flat))==3&&all(not . isInfixOf root . entryId)flat)
  -- Native envelope tampering is made canonical so rejection cannot be blamed
  -- merely on invalid CBOR. Every malformed input lives only in this temp tree.
  term<-must(decodeCanonical candidate)
  let altered key value=case term of CMap fields->must(encodeCanonical(CMap[(k,if k==key then value else v)|(k,v)<-fields]));_->ioError(userError "expected envelope")
  variants<-sequence
    [altered 5(CInteger 99),altered 6(CText(T.pack "red-dune-reference-99"))
    ,altered 7(CBytes(BS.replicate 32 0)),altered 12(CBytes(BS.replicate 32 0))
    ,altered 6(CText(T.pack "red-dune-reference-1"))]
  forM_(zip[3..]variants) $ \(sequenceNo,bytes)->BS.writeFile(directory </> generationFilename sequenceNo)bytes
  BS.writeFile(directory </> generationFilename 8)(BS.init candidate)
  (valid,rejected)<-listLibrary config False >>= must
  assert "corrupt/schema/hash/ruleset/catalog mismatch sources are warnings only"
    (length valid==2&&length rejected>=6)
  assert "warnings do not expose filesystem paths"(all(not . isInfixOf root)rejected&&all(not . isInfixOf "/proc/")rejected)
  -- Valid encoded content in a registered directory with the wrong identity.
  let wrong=libraryRoot config </> "world-1" </> "branch-900"
  commit wrong 1 running
  (stillValid,wrongWarnings)<-listLibrary config False >>= must
  assert "registered branch/world identity is enforced"(length stillValid==2&&not(null wrongWarnings))
  createDirectory(libraryRoot config </> "world-01")
  createDirectory(libraryRoot config </> "world-1" </> "branch-01")
  (canonical,malformed)<-listLibrary config False >>= must
  assert "noncanonical decimal paths do not become entries"(length canonical==2&&length malformed>length wrongWarnings)
  -- A missing manifest cannot label an orphan generation committed.
  removeFile(directory </> manifestFilename)
  (orphans,_)<-listLibrary config False >>= must
  assert "manifest loss exposes only candidates"(length orphans==2&&all((==Candidate).entryKind)orphans)
  putStrLn "LIBRARY-CATALOG native committed/candidates, flat directory, corruption/schema/hash/catalog, identity, canonical names and manifest loss PASS"

replacementTests :: World -> IO ()
replacementTests running=do
  withTemp $ \root->do
    let config=configAt root;directory=registered config running;path=directory </> generationFilename 1
    commit directory 1 running
    entry<-findEntry config(branchId running)
    bytes<-readEntry entry >>= must
    -- Byte-identical replacement still invalidates an old selection identity.
    BS.writeFile(directory </> "replacement")bytes
    renameFile(directory </> "replacement")path
    assert "byte-identical inode replacement rejects old selection" . isLeft =<< readEntry entry
    entry2<-findEntry config(branchId running)
    BS.writeFile path(BS.init bytes)
    assert "same inode modification rejects" . isLeft =<< readEntry entry2
  withTemp $ \root->do
    let config=configAt root;directory=registered config running;path=directory </> generationFilename 1
    commit directory 1 running
    entry<-findEntry config(branchId running)
    bytes<-readEntry entry >>= must
    let outside=root </> "outside.save"
    BS.writeFile outside bytes
    removeFile path
    createSymbolicLink outside path
    assert "selected file replaced by symlink rejects" . isLeft =<< readEntry entry
    (entries,warnings)<-listLibrary config False >>= must
    assert "symlink generation nonactivatable warning"(null entries&&not(null warnings))
  withTemp $ \root->do
    let config=configAt root;directory=registered config running
    commit directory 1 running
    entry<-findEntry config(branchId running)
    renameDirectory directory(directory++"-moved")
    createDirectory directory
    assert "selected directory replaced rejects" . isLeft =<< readEntry entry
    removePathForcibly directory
    createSymbolicLink(directory++"-moved")directory
    assert "parent symlink rejects" . isLeft =<< readEntry entry
  withTemp $ \root->do
    let config=configAt root;directory=registered config running;path=directory </> generationFilename 1
    createDirectoryIfMissing True directory
    createNamedPipe path 0o600
    (entries,warnings)<-listLibrary config False >>= must
    assert "FIFO does not block or activate"(null entries&&not(null warnings))
    removeFile path
    withBinaryFile path WriteMode(\h->hSetFileSize h(toInteger(maxPayloadBytes defaultDecodeLimits)+1))
    (oversized,rejections)<-listLibrary config False >>= must
    assert "oversized file rejected before unbounded read"(null oversized&&not(null rejections))
  putStrLn "LIBRARY-READ replaced inode, in-place modification, directory replacement, file/parent symlink, FIFO and oversized file PASS"

reservationTests :: IO ()
reservationTests=do
  withTemp $ \root->do
    let config=configAt root
    (one,p1)<-reserveBranch config 1 1 >>= must
    (two,p2)<-reserveBranch config 1 1 >>= must
    assert "fresh branch excludes source and prior reservations"(one==2&&two==3&&p1/=p2)
    -- A new config value and repeated call model restart with only disk state.
    (restart,_)<-reserveBranch(LibraryConfig(libraryRoot config)Nothing Nothing)1 1 >>= must
    assert "reservation high-water survives new allocator instance"(restart==4)
    ready<-replicateM 24 newEmptyMVar
    forM_ ready $ \result->void(forkIO(reserveBranch config 1 1 >>= putMVar result))
    allocated<-mapM(takeMVar >=> must)ready
    let ids=map fst allocated
    assert "24 concurrent atomic mkdir reservations are unique"(length(nub ids)==24&&sort ids==[5..28])
    assert "all reserved directories actually exist" . and =<< mapM(doesDirectoryExist . snd)allocated
    (high,_)<-reserveBranch config 1 100 >>= must
    assert "supplied source is a lower bound"(high==101)
    assert "maxBound supplied source rejects" . isLeft =<< reserveBranch config 1 maxBound
    assert "zero world rejects" . isLeft =<< reserveBranch config 0 1
    let exhaustion=libraryRoot config </> "world-2"
    createDirectory exhaustion
    createDirectory(exhaustion </> ("branch-"++show(maxBound::Word64)))
    assert "observed maxBound refuses wrap" . isLeft =<< reserveBranch config 2 1
    (lastId,_)<-reserveBranch config 3(maxBound-1) >>= must
    assert "last representable branch allocates exactly maxBound"(lastId==maxBound)
    assert "restart after last branch refuses reuse" . isLeft =<< reserveBranch config 3 1
    putStrLn "LIBRARY-RESERVE first=2, restart=4, concurrent=[5..28], source lower bound=101, maxBound/no wrap PASS"
  withTemp $ \root->do
    let config=configAt root
    createDirectoryIfMissing True(libraryRoot config </> "world-1")
    createDirectory(libraryRoot config </> "world-1" </> "branch-01")
    assert "malformed reservation names refuse allocation" . isLeft =<< reserveBranch config 1 0
    assert "config traversal refused" . isLeft =<< reserveBranch config{libraryRoot=root </> ".." </> "escape"}1 0
  withTemp $ \root->do
    let config=configAt root;outside=root </> "outside"
    createDirectory outside
    createSymbolicLink outside(libraryRoot config)
    assert "symlink library root rejects writes" . isLeft =<< reserveBranch config 1 0
    assert "symlink target untouched" . null =<< listDirectory outside
  withTemp $ \root->do
    let config=configAt root;outside=root </> "outside"
    createDirectory outside
    createDirectory(libraryRoot config)
    createSymbolicLink outside(libraryRoot config </> "world-1")
    assert "symlink world refuses allocation" . isLeft =<< reserveBranch config 1 0
    assert "symlink target untouched" . null =<< listDirectory outside
  withTemp $ \root->do
    let config=configAt root;outside=root </> "outside"
    createDirectory outside
    createDirectoryIfMissing True(libraryRoot config </> "world-1")
    createSymbolicLink outside(libraryRoot config </> "world-1" </> "branch-1")
    assert "symlink existing branch refuses allocation" . isLeft =<< reserveBranch config 1 0
    assert "symlink target untouched" . null =<< listDirectory outside
  withTemp $ \root->do
    let config=configAt root
    processes<-mapM (\index->forkProcess $ do
      (branch,_)<-reserveBranch config 4 0 >>= must
      BSC.writeFile(root </> ("process-"++show index++".out"))(BSC.pack(show branch))
      exitImmediately ExitSuccess) [1..8::Word64]
    statuses<-mapM(getProcessStatus True False)processes
    assert "all independent allocator processes exited successfully"(all(==Just(Exited ExitSuccess))statuses)
    branches<-mapM (\index->BSC.readFile(root </> ("process-"++show index++".out")) >>= \bytes->
      maybe(ioError(userError "invalid process allocation record"))pure(readMaybe(BSC.unpack bytes)::Maybe Word64)) [1..8::Word64]
    assert "cross-process mkdir allocation is unique"(sort branches==[1..8])
  forM_ [BeforeBranchSync,AfterBranchSync,BeforeBranchParentSync,AfterBranchParentSync] $ \point->withTemp $ \root->do
    let config=configAt root
        hook observed=if observed==point then throwIO(LibraryError "injected branch fsync boundary failure") else pure()
    failed<-reserveBranchWithSyncHook hook config 1 0
    assert "injected fsync failure does not report a reservation success"(isLeft failed)
    assert "uncertain branch reservation is retained" =<< doesDirectoryExist(libraryRoot config </> "world-1" </> "branch-1")
    (next,_)<-reserveBranch config 1 0 >>= must
    assert "retry never reuses uncertain branch ID"(next==2)
    putStrLn("LIBRARY-BRANCH-FAULT "++show point++" failed-without-success, branch-1 retained, retry=branch-2 PASS")
  putStrLn "LIBRARY-RESERVE traversal, malformed decimal, root/world/branch symlinks, 8 independent processes and fsync-boundary failures PASS; no physical power-cut claim"
  where (>=>) f g x=f x >>= g

checkpointLibraryTests :: Content -> IO ()
checkpointLibraryTests content=do
  running<-loadPackaged "running-wip-v3.cbor"
  assert "packaged running fixture is actual running WIP"(any((==Running).jobPhase)(M.elems(worldJobs running)))
  profileTests content running
  legacyTests running
  catalogTests running
  replacementTests running
  reservationTests
  putStrLn "CheckpointLibraryTests PASS: immutable controlled catalog, exact preparation, all six profiles, legacy sequential imports, filesystem identity and atomic reservations"
