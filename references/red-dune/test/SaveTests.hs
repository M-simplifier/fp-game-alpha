{-# LANGUAGE ScopedTypeVariables #-}
module SaveTests (saveTests) where

import Colony.Codec
import Colony.Codec.CBOR
import Colony.Codec.Value (encodeValue)
import Colony.Content
import Colony.Inventory
import Colony.Save
import Colony.Scheduler (pureStep)
import Colony.Types
import Colony.Units (Resource(Water,Ore))
import Colony.World
import Control.Exception (ErrorCall,bracket,evaluate,try)
import Control.Monad (forM,forM_,unless,when)
import qualified Data.ByteString as BS
import Data.Either (isLeft,isRight)
import Data.IORef (newIORef,modifyIORef',readIORef,writeIORef)
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromJust,isNothing)
import Data.Word (Word64)
import System.Directory (createDirectory,doesFileExist,listDirectory,removeFile,removePathForcibly)
import System.FilePath ((</>))
import System.IO (hClose,openBinaryTempFile,withBinaryFile,IOMode(WriteMode),hSetFileSize)
import System.IO.Error (mkIOError,fullErrorType,permissionErrorType)
import System.Posix.Files (createSymbolicLink)

assert :: String -> Bool -> IO ()
assert label passed = unless passed (ioError (userError ("Save assertion failed: " ++ label)))
must :: Show e => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

-- Every deletion in this suite is within a uniquely created temporary test
-- directory under the current implementation workspace. No user save is read.
withTemp :: (FilePath -> IO a) -> IO a
withTemp = bracket acquire removePathForcibly
  where
    acquire = do
      (path,handle) <- openBinaryTempFile "." ".save-test-"
      hClose handle
      removeFile path
      createDirectory path
      pure path

sampleWorld :: Content -> IO World
sampleWorld content = do
  let owner = Owner Warehouse (EntityId 100)
      tx = TxId 1 1 (BoundarySeq 0) P0 0
      action = do
        addStorage owner (Storage 1000000 Nothing (EntityId 1))
        _ <- mintLot tx InitialGrant Nothing Water 1000 owner (SimTick 0) Nothing "save water"
        _ <- mintLot tx InitialGrant Nothing Ore 900 owner (SimTick 0) Nothing "save ore"
        pure ()
  (_,inventory) <- must "save fixture inventory" (runInventory action (worldInventory (initialWorld content)))
  pure (initialWorld content) {worldInventory=inventory}

identity :: World -> SaveIdentity
identity = identityFor (Epoch "save-test-session" 1)
snapshot :: World -> Word64 -> IO CapturedSnapshot
snapshot world seqNo = must "capture" (captureSnapshot (SaveTicket (identity world) seqNo ManualSave)
  (CheckpointMeta seqNo Nothing "native-save-tests") world {simTick=SimTick seqNo})

saveTests :: Content -> IO ()
saveTests content = do
  world <- sampleWorld content
  testQueue world
  withTemp $ \root -> do
    let seed = root </> "seed"
    createDirectory seed
    adapter <- nativeAdapter
    forM_ [1..3] $ \seqNo -> do
      captured <- snapshot world seqNo
      result <- nativeSave adapter seed (pure (identity world)) captured
      assert ("initial committed generation " ++ show seqNo) (isRight (saveCompletion result))
    seedFiles <- listDirectory seed
    seedBytes <- forM (filter (/=".checkpoint.lock") seedFiles) $ \name -> do
      bytes <- BS.readFile (seed </> name)
      pure (name,bytes)
    let clone label = do
          let directory = root </> label
          createDirectory directory
          forM_ seedBytes $ \(name,bytes) -> BS.writeFile (directory </> name) bytes
          pure directory
    fourth <- snapshot world 4
    -- Baseline records the exact operations and each concrete chunk index.
    baseline <- clone "baseline"
    points <- newIORef []
    recording <- newSaveAdapter 1024 (\p -> modifyIORef' points (++[p]) >> pure Proceed)
    baselineResult <- nativeSave recording baseline (pure (identity world)) fourth
    assert "exact phase separation" (saveProgress baselineResult == [Captured,Written,Flushed,Renamed,ManifestCommitted,CallbackAccepted])
    assert "baseline success only after callback" (isRight (saveCompletion baselineResult))
    recovered <- recoverCheckpoints baseline
    assert "current and previous two committed" (map (checkpointSequence . generationMeta) (recoveryCommitted recovered) == [4,3,2])
    assert "cleanup prunes only oldest committed" . not =<< doesFileExist (baseline </> generationFilename 1)
    loaded <- loadGeneration baseline (fromJust (recoveryAutomatic recovered))
    assert "real filesystem load preserves complete world and assets" (loaded == world {simTick=SimTick 4})
    receipt <- must "accepted receipt" (saveCompletion baselineResult)
    assert "receipt records captured tick rather than later live state" (committedTick receipt == SimTick 4)
    allPoints <- readIORef points
    assert "fault trace has no duplicate point" (nub allPoints == allPoints)
    forM_ (zip [0::Int ..] allPoints) $ \(caseNo,target) -> do
      directory <- clone ("fault-" ++ show caseNo)
      hit <- newIORef False
      faulty <- newSaveAdapter 1024 $ \point -> if point == target
        then writeIORef hit True >> pure (FailWith ("simulated process interruption at " ++ show target))
        else pure Proceed
      result <- nativeSave faulty directory (pure (identity world)) fourth
      assert ("injection was reached " ++ show target) =<< readIORef hit
      let cleanup = case target of
            FaultPoint _ (DeleteOldGeneration _) -> True
            FaultPoint _ CleanupDirectorySync -> True
            _ -> False
      assert ("no false callback success " ++ show target)
        (if cleanup then isRight (saveCompletion result) && not (null (saveWarnings result))
         else isLeft (saveCompletion result) && CallbackAccepted `notElem` saveProgress result)
      report <- recoverCheckpoints directory
      automatic <- maybe (ioError (userError ("lost every committed generation " ++ show target))) pure (recoveryAutomatic report)
      let sequenceNo = checkpointSequence (generationMeta automatic)
      assert ("only intact old/new committed generation loads " ++ show target) (sequenceNo `elem` [3,4])
      putStrLn ("SAVE-FAULT " ++ show target ++ " phases=" ++ show (saveProgress result) ++ " automatic=" ++ show sequenceNo ++ " candidates=" ++ show (map (checkpointSequence . generationMeta) (recoveryCandidates report)) ++ " outcome=" ++ if cleanup then "committed-with-cleanup-warning" else "failed-without-success")
      restored <- loadGeneration directory automatic
      assert ("injected failure conserves exact assets " ++ show target) (restored == world {simTick=SimTick sequenceNo})
      forM_ [2,3] $ \old -> do
        bytes <- BS.readFile (directory </> generationFilename old)
        assert ("previous two bytes immutable " ++ show target) (lookup (generationFilename old) seedBytes == Just bytes)
      existsOldest <- doesFileExist (directory </> generationFilename 1)
      when (ManifestCommitted `notElem` saveProgress result) (assert "never prune before verified commit" existsOldest)
      assert "no tmp is exposed as a recovery generation"
        (all (\g -> generationFile g == generationFilename (checkpointSequence (generationMeta g)))
             (recoveryCommitted report ++ recoveryCandidates report))
    let chunkPoints = [(role,index) | FaultPoint Before (WriteChunk role index) <- allPoints]
    forM_ (zip [0::Int ..] chunkPoints) $ \(caseNo,(role,index)) -> do
      directory <- clone ("short-" ++ show caseNo)
      faulty <- newSaveAdapter 1024 (\point -> pure (if point == FaultPoint Before (WriteChunk role index) then ShortWrite else Proceed))
      result <- nativeSave faulty directory (pure (identity world)) fourth
      putStrLn ("SAVE-SHORT-WRITE " ++ show role ++ " chunk=" ++ show index ++ " phases=" ++ show (saveProgress result))
      assert "actual partial fd write is a failure" (saveCompletion result == Left (ShortWriteDetected role index))
      report <- recoverCheckpoints directory
      assert "short write cannot move the commit pointer" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 3)
      assert "short write cannot send successful callback" (CallbackAccepted `notElem` saveProgress result)
      assert "manifest partial write leaves validated new candidate" (role /= ManifestFile || map (checkpointSequence . generationMeta) (recoveryCandidates report) == [4])
    forM_ [("disk-full",fullErrorType,DiskFull),("permission",permissionErrorType,PermissionDenied)] $ \(label,errorType,kind) ->
      forM_ chunkPoints $ \(role,index) -> do
        directory <- clone (label ++ show role ++ show index)
        faulty <- newSaveAdapter 1024 $ \point -> if point == FaultPoint Before (WriteChunk role index)
          then ioError (mkIOError errorType ("simulated " ++ label) Nothing Nothing) else pure Proceed
        result <- nativeSave faulty directory (pure (identity world)) fourth
        putStrLn ("SAVE-IO-ERROR " ++ show kind ++ " " ++ show role ++ " chunk=" ++ show index)
        assert "IO failure is classified without world reset" (case saveCompletion result of Left (StorageIO actual _) -> actual == kind; _ -> False)
        report <- recoverCheckpoints directory
        assert "IO error preserves last commit" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 3)
        let input = Boundary (BoundaryHeader 1 1 (boundarySeq world) True (worldAuthority world) (worldRuleset world)) [] []
            (continued,out) = pureStep input world
        assert "simulation can continue after failed shell save" (simTick continued > simTick world && null (outputDiagnostics out))
    testCaptureFailure world clone
    testRecovery world fourth clone seedBytes
    testReadbackAndSession world fourth clone
    testRetry world fourth clone
    putStrLn ("Native save protocol: " ++ show (length allPoints) ++ " exact before/after fault points, " ++ show (length chunkPoints) ++ " concrete short-write chunk points, disk-full/permission injection, readback, recovery, retention and session rejection passed")

-- A queue holds request metadata only: one active + one latest autosave + one
-- first manual. More autosaves coalesce; further manual clicks show progress.
testQueue :: World -> IO ()
testQueue world = do
  let ident = identity world
      ticket serial kind = SaveTicket ident serial kind
      first = ticket 1 Autosave
      (started,q1) = enqueueSave first (emptySaveQueue ident)
      (_,q2) = enqueueSave (ticket 2 ManualSave) q1
      (duplicate,q3) = enqueueSave (ticket 3 ManualSave) q2
      latest = foldl (\queue n -> snd (enqueueSave (ticket n Autosave) queue)) q3 [4..10004]
  assert "idle save starts immediately" (started == Started)
  assert "manual pending is bounded and preserves first click" (duplicate == AlreadyPending && queueManual q3 == Just (ticket 2 ManualSave))
  assert "10001 autosaves coalesce to exactly latest pending request" (queueAutosave latest == Just (ticket 10004 Autosave) && queueActive latest == Just first)
  let (finished,next) = finishSave first latest
  assert "manual pending takes next slot" (finished && queueActive next == Just (ticket 2 ManualSave))
  let (_,nextAuto) = finishSave (ticket 2 ManualSave) next
  assert "latest autosave follows manual" (queueActive nextAuto == Just (ticket 10004 Autosave) && isNothing (queueManual nextAuto))
  let changed = emptySaveQueue ident {saveEpoch=Epoch "new-session" 2}
  assert "old completion cannot mutate new queue" (finishSave first changed == (False,changed))
  assert "old request rejected at new session" (enqueueSave first changed == (WrongSession,changed))
  assert "duplicate non-active completion rejected" (finishSave first nextAuto == (False,nextAuto))

testRecovery :: World -> CapturedSnapshot -> (String -> IO FilePath) -> [(FilePath,BS.ByteString)] -> IO ()
testRecovery world fourth clone seedBytes = do
  forM_ ["missing","corrupt"] $ \kind -> do
    directory <- clone ("manifest-" ++ kind)
    if kind == "missing" then removeFile (directory </> manifestFilename)
      else BS.writeFile (directory </> manifestFilename) (BS.pack [1,2,3])
    report <- recoverCheckpoints directory
    assert "missing/corrupt manifest never silently auto-loads latest" (isNothing (recoveryAutomatic report) && null (recoveryCommitted report))
    assert "all valid generations become explicitly unconfirmed" (map (checkpointSequence . generationMeta) (recoveryCandidates report) == [3,2,1])
    selected <- loadGeneration directory (head (recoveryCandidates report))
    assert "explicit candidate selection restores assets" (selected == world {simTick=SimTick 3})
    adapter <- nativeAdapter
    result <- nativeSave adapter directory (pure (identity world)) fourth
    assert "new explicit save can restore valid commit marker" (isRight (saveCompletion result))
    assert "unconfirmed old generations are never cleanup targets" =<< doesFileExist (directory </> generationFilename 1)
  corrupted <- clone "corrupt-latest"
  BS.writeFile (corrupted </> generationFilename 3) (BS.pack [0])
  report <- recoverCheckpoints corrupted
  assert "corrupt latest falls back to validated previous commit" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 2)
  assert "corruption reason remains visible" (not (null (recoveryRejected report)))
  forM_ [1,2] $ \seqNo -> BS.writeFile (corrupted </> generationFilename seqNo) (BS.pack [0])
  allBad <- recoverCheckpoints corrupted
  assert "all corrupt never resets or fabricates a world" (isNothing (recoveryAutomatic allBad) && null (recoveryCandidates allBad) && not (null (recoveryRejected allBad)))
  tempOnly <- clone "temp-only"
  BS.writeFile (tempOnly </> "generation-999.tmp") (fromJust (lookup (generationFilename 3) seedBytes))
  tempReport <- recoverCheckpoints tempOnly
  assert "complete but unrenamed tmp ignored" (null (recoveryCandidates tempReport))
  noReuse <- clone "no-sequence-reuse"
  old <- snapshot world 3
  adapter <- nativeAdapter
  collision <- nativeSave adapter noReuse (pure (identity world)) old
  assert "generation names never overwritten" (saveCompletion collision == Left SequenceNotFresh)
  oldBytes <- BS.readFile (noReuse </> generationFilename 3)
  assert "collision preserves original bytes" (Just oldBytes == lookup (generationFilename 3) seedBytes)
  -- A foreign world must never be mixed into the directory's commit history.
  let foreignWorld = world {worldId=2}
  foreignSnapshot <- snapshot foreignWorld 4
  foreignResult <- nativeSave adapter noReuse (pure (identity foreignWorld)) foreignSnapshot
  assert "foreign world save blocked without changing marker" (isLeft (saveCompletion foreignResult))
  invalidDir <- clone "future-and-semantic"
  let original = fromJust (lookup (generationFilename 3) seedBytes)
  tree <- must "checkpoint envelope" (decodeCanonical original)
  future <- alterEnvelope tree [(5,CInteger 99)]
  BS.writeFile (invalidDir </> generationFilename 3) future
  futureReport <- recoverCheckpoints invalidDir
  assert "future schema rejected" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic futureReport) == Just 2)
  invalidPayload <- must "encode deliberately broken semantic state" (encodeValue world {simTick=SimTick 3,worldInventory=(worldInventory world) {invLedger=M.empty}})
  semantic <- alterEnvelope tree [(16,CBytes invalidPayload),(11,CInteger (toInteger (BS.length invalidPayload))),
                                  (12,CBytes (sha256 invalidPayload)),(13,CBytes (sha256 invalidPayload))]
  BS.writeFile (invalidDir </> generationFilename 3) semantic
  semanticReport <- recoverCheckpoints invalidDir
  assert "checksum-correct asset inconsistency still rejected" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic semanticReport) == Just 2)
  hugeDir <- clone "oversized-and-symlink"
  withBinaryFile (hugeDir </> generationFilename 50) WriteMode $ \handle -> hSetFileSize handle (1024*1024*1024+1)
  createSymbolicLink (generationFilename 3) (hugeDir </> generationFilename 51)
  hugeReport <- recoverCheckpoints hugeDir
  assert "sparse oversized file rejected before allocation" (generationFilename 50 `elem` map fst (recoveryRejected hugeReport))
  assert "symlink generation never followed" (generationFilename 51 `elem` map fst (recoveryRejected hugeReport))
  assert "malformed side files do not destroy prior commit" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic hugeReport) == Just 3)
  -- A selected candidate changed after listing must be revalidated.
  changed <- clone "selection-toctou"
  choices <- recoverCheckpoints changed
  let selected = fromJust (recoveryAutomatic choices)
  BS.writeFile (changed </> generationFile selected) (BS.pack [0])
  changedResult <- try (loadGeneration changed selected) :: IO (Either SaveFailure World)
  assert "candidate selection rechecks whole-file hash" (isLeft changedResult)
  -- Explicit storage outcome models around unflushed directory entries. These
  -- are NOT real device power-cut tests. Each model mutates only its clone.
  forM_ ["old-marker","new-marker","missing-marker","torn-marker","lost-generation"] $ \model -> do
    directory <- clone ("power-model-" ++ model)
    faulty <- newSaveAdapter 1024 $ \point -> do
      let target = if model == "lost-generation" then FaultPoint After RenameGeneration else FaultPoint After ReplaceManifest
      if point /= target then pure Proceed else do
        case model of
          "old-marker" -> BS.writeFile (directory </> manifestFilename) (fromJust (lookup manifestFilename seedBytes))
          "new-marker" -> pure ()
          "missing-marker" -> removeFile (directory </> manifestFilename)
          "torn-marker" -> BS.writeFile (directory </> manifestFilename) (BS.pack [0,1])
          _ -> removeFile (directory </> generationFilename 4)
        pure (FailWith ("simulated storage outcome " ++ model))
    result <- nativeSave faulty directory (pure (identity world)) fourth
    assert "storage outcome model never emits success" (isLeft (saveCompletion result))
    recovered <- recoverCheckpoints directory
    if model `elem` ["missing-marker","torn-marker"]
      then assert "no trustworthy marker means only candidates" (isNothing (recoveryAutomatic recovered) && length (recoveryCandidates recovered) == 4)
      else assert "old/new atomic marker selects intact generation"
             (fmap (checkpointSequence . generationMeta) (recoveryAutomatic recovered) == Just (if model == "new-marker" then 4 else 3))
  where
    alterEnvelope (CMap fields) replacements = must "modified envelope" (encodeCanonical (CMap [(tag,maybe value id (lookup tag replacements)) | (tag,value) <- fields]))
    alterEnvelope _ _ = ioError (userError "invalid test envelope")

testReadbackAndSession :: World -> CapturedSnapshot -> (String -> IO FilePath) -> IO ()
testReadbackAndSession world fourth clone = do
  forM_ [GenerationFile,ManifestFile] $ \role -> do
    directory <- clone ("readback-corruption-" ++ show role)
    let filename = if role == GenerationFile then "generation-4.tmp" else "manifest-4.tmp"
    faulty <- newSaveAdapter 1024 $ \point -> do
      when (point == FaultPoint After (FlushFile role)) (BS.writeFile (directory </> filename) (BS.pack [0]))
      pure Proceed
    result <- nativeSave faulty directory (pure (identity world)) fourth
    assert "post-flush readback catches mismatched bytes" (isLeft (saveCompletion result) && ManifestCommitted `notElem` saveProgress result)
    report <- recoverCheckpoints directory
    assert "readback mismatch preserves prior marker" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 3)
  let ident = identity world
      replacements = [ident {saveEpoch=Epoch "save-test-session" 2},ident {saveEpoch=Epoch "different-authority" 1},ident {saveWorldId=999},ident {saveBranchId=999}]
  forM_ (zip [0::Int ..] replacements) $ \(caseNo,current) -> do
    directory <- clone ("stale-callback-" ++ show caseNo)
    adapter <- nativeAdapter
    result <- nativeSave adapter directory (pure current) fourth
    assert "stale callback rejected after physical commit" (saveCompletion result == Left StaleCallback && ManifestCommitted `elem` saveProgress result && CallbackAccepted `notElem` saveProgress result)
    report <- recoverCheckpoints directory
    assert "old-session commit remains recoverable for its own world" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 4)
  directory <- clone "corrupt-after-commit-readback"
  faulty <- newSaveAdapter 1024 $ \point -> do
    when (point == FaultPoint Before CommitReadback) (BS.writeFile (directory </> generationFilename 4) (BS.pack [0]))
    pure Proceed
  result <- nativeSave faulty directory (pure ident) fourth
  assert "readback must include committed generation not merely manifest bytes" (isLeft (saveCompletion result) && CallbackAccepted `notElem` saveProgress result)
  assert "failed commit readback cannot prune old generation" =<< doesFileExist (directory </> generationFilename 1)

-- Retry uses a fresh sequence, preserving incomplete bytes and all confirmed
-- saves. Wraparound is refused rather than reusing an old filename.
testRetry :: World -> CapturedSnapshot -> (String -> IO FilePath) -> IO ()
testRetry world fourth clone = do
  directory <- clone "retry-after-short-write"
  faulty <- newSaveAdapter 1024 (\point -> pure (if point == FaultPoint Before (WriteChunk GenerationFile 0) then ShortWrite else Proceed))
  failed <- nativeSave faulty directory (pure (identity world)) fourth
  assert "retry fixture first save failed" (isLeft (saveCompletion failed))
  next <- nextCheckpointSequence directory >>= must "next retry sequence"
  assert "retry skips abandoned temporary generation" (next == 5)
  fifth <- snapshot world next
  adapter <- nativeAdapter
  retried <- nativeSave adapter directory (pure (identity world)) fifth
  assert "fresh-sequence retry succeeds without reset" (isRight (saveCompletion retried))
  assert "retry does not delete uncertain temporary bytes" =<< doesFileExist (directory </> "generation-4.tmp")
  BS.writeFile (directory </> ("manifest-" ++ show (maxBound :: Word64) ++ ".tmp")) BS.empty
  exhausted <- nextCheckpointSequence directory
  assert "sequence overflow rejected" (isLeft exhausted)

-- Capture/encoding faults occur before the first filesystem operation. They
-- neither replace a manifest nor produce a fictitious Captured/Committed event.
testCaptureFailure :: World -> (String -> IO FilePath) -> IO ()
testCaptureFailure world clone = do
  directory <- clone "capture-failure"
  before <- BS.readFile (directory </> manifestFilename)
  let ticket = SaveTicket (identity world) 4 ManualSave
      meta = CheckpointMeta 4 Nothing "capture-failure-test"
      invalid = world {worldInventory=(worldInventory world) {invLedger=M.empty}}
  assert "invalid snapshot rejected before IO" (isLeft (captureSnapshot ticket meta invalid))
  exception <- try (evaluate (captureSnapshot ticket meta world {worldRuleset=error "simulated encoder exception"}))
    :: IO (Either ErrorCall (Either SaveFailure CapturedSnapshot))
  assert "capture forces invalid lazy fields rather than deferring into a worker" (isLeft exception)
  after <- BS.readFile (directory </> manifestFilename)
  assert "capture failures preserve committed bytes" (after == before)
  report <- recoverCheckpoints directory
  assert "capture failures leave old checkpoint automatically recoverable" (fmap (checkpointSequence . generationMeta) (recoveryAutomatic report) == Just 3)
