{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables #-}
-- | Linux/POSIX native checkpoint protocol. One adapter is shared by a save
-- worker; its mutex serializes requests. The OS file lock also rejects another
-- process writing the same directory. All success is after fsync + readback.
module Colony.Save
  ( SaveIdentity(..), identityFor, SaveKind(..), SaveTicket(..)
  , SaveQueue(..), QueueAdmission(..), emptySaveQueue, enqueueSave, finishSave
  , CapturedSnapshot, capturedTicket, capturedMeta, capturedTick, capturedStateHash
  , captureSnapshot, SavePhase(..), SaveFailure(..), StorageFailureKind(..), CheckpointCommitted(..)
  , SaveResult(..), FileRole(..), SaveOperation(..), FaultTiming(..)
  , FaultPoint(..), FaultEffect(..), SaveAdapter, newSaveAdapter, nativeAdapter
  , nativeSave, Generation(..), RecoveryReport(..), recoverCheckpoints, loadGeneration
  , generationFilename, manifestFilename, nextCheckpointSequence, readBounded
  ) where

import Colony.Codec
import Colony.Codec.CBOR
import Colony.Types (Epoch,SimTick)
import Colony.World
import Control.Concurrent.MVar (MVar,newMVar,withMVar)
import Control.DeepSeq (force)
import Control.Exception (Exception,IOException,bracket,bracketOnError,catch,evaluate,throwIO)
import Control.Monad (forM,forM_,unless,when)
import qualified Data.ByteString as BS
import Data.IORef (newIORef,modifyIORef',readIORef)
import Data.List (sortOn)
import Data.Maybe (listToMaybe,mapMaybe)
import qualified Data.Text as T
import Data.Typeable (Typeable)
import Data.Word (Word64)
import Foreign.Ptr (castPtr)
import System.Directory (doesDirectoryExist,listDirectory,removeFile,renameFile)
import System.FilePath ((</>))
import System.IO (SeekMode(AbsoluteSeek),hClose)
import System.IO.Error (isFullError,isPermissionError)
import System.Posix.Files (getFdStatus,isRegularFile,fileSize)
import System.Posix.IO (OpenMode(ReadOnly,ReadWrite,WriteOnly),OpenFileFlags(..),LockRequest(WriteLock),
                       openFd,closeFd,fdWriteBuf,fdToHandle,defaultFileFlags,setLock)
import System.Posix.Unistd (fileSynchronise)
import Text.Read (readMaybe)

-- Epoch is shell/session identity, never restored from checkpoint bytes.
data SaveIdentity = SaveIdentity
  { saveWorldId :: !Word64, saveBranchId :: !Word64, saveEpoch :: !Epoch }
  deriving (Eq,Show)
identityFor :: Epoch -> World -> SaveIdentity
identityFor epoch world = SaveIdentity (worldId world) (branchId world) epoch

data SaveKind = Autosave | ManualSave deriving (Eq,Show)
data SaveTicket = SaveTicket
  { ticketIdentity :: !SaveIdentity, ticketSerial :: !Word64, ticketKind :: !SaveKind }
  deriving (Eq,Show)

-- Pending tickets contain NO world/snapshot roots. Capture only when started.
data SaveQueue = SaveQueue
  { queueIdentity :: !SaveIdentity, queueActive :: !(Maybe SaveTicket)
  , queueAutosave :: !(Maybe SaveTicket), queueManual :: !(Maybe SaveTicket) }
  deriving (Eq,Show)
data QueueAdmission = Started | Pending | Coalesced | AlreadyPending | WrongSession
  deriving (Eq,Show)
emptySaveQueue :: SaveIdentity -> SaveQueue
emptySaveQueue ident = SaveQueue ident Nothing Nothing Nothing
enqueueSave :: SaveTicket -> SaveQueue -> (QueueAdmission,SaveQueue)
enqueueSave ticket queue
  | ticketIdentity ticket /= queueIdentity queue = (WrongSession,queue)
  | queueActive queue == Nothing = (Started,queue {queueActive=Just ticket})
  | queueActive queue == Just ticket = (AlreadyPending,queue)
  | ticketKind ticket == Autosave =
      (if queueAutosave queue == Nothing then Pending else Coalesced,queue {queueAutosave=Just ticket})
  | queueManual queue == Nothing = (Pending,queue {queueManual=Just ticket})
  | otherwise = (AlreadyPending,queue)
finishSave :: SaveTicket -> SaveQueue -> (Bool,SaveQueue)
finishSave ticket queue
  | queueActive queue /= Just ticket || ticketIdentity ticket /= queueIdentity queue = (False,queue)
  | Just manual <- queueManual queue = (True,queue {queueActive=Just manual,queueManual=Nothing})
  | otherwise = (True,queue {queueActive=queueAutosave queue,queueAutosave=Nothing})

data CapturedSnapshot = CapturedSnapshot
  { capturedTicket :: !SaveTicket, capturedMeta :: !CheckpointMeta
  , capturedTick :: !SimTick, capturedStateHash :: !BS.ByteString
  , capturedBytes :: !BS.ByteString }
  deriving (Eq,Show)

-- Call at the P10 boundary. This forces authoritative state to NF and captures
-- strict canonical bytes, so no mutable or lazily evolving world is retained.
captureSnapshot :: SaveTicket -> CheckpointMeta -> World -> Either SaveFailure CapturedSnapshot
captureSnapshot ticket meta original = do
  let world = force original
      ident = ticketIdentity ticket
  unless (saveWorldId ident == worldId world && saveBranchId ident == branchId world)
    (Left (InvalidSnapshot "world/branch does not match request identity"))
  bytes <- mapCodec (encodeCheckpoint meta world)
  digest <- mapCodec (canonicalStateHash world)
  pure (CapturedSnapshot ticket meta (simTick world) digest bytes)

data SavePhase = Captured | Written | Flushed | Renamed | ManifestCommitted | CallbackAccepted
  deriving (Eq,Ord,Show)
data StorageFailureKind = DiskFull | PermissionDenied | OtherIO deriving (Eq,Show)
data SaveFailure = InvalidSnapshot String | InvalidStorage String | StorageIO StorageFailureKind String
                 | InjectedFailure String | ShortWriteDetected FileRole Word64
                 | StaleCallback | SequenceNotFresh
  deriving (Eq,Show,Typeable)
instance Exception SaveFailure

data CheckpointCommitted = CheckpointCommitted
  { committedTicket :: !SaveTicket, committedSequence :: !Word64
  , committedTick :: !SimTick, committedStateHash :: !BS.ByteString
  , committedFile :: !FilePath }
  deriving (Eq,Show)
data SaveResult = SaveResult
  { saveProgress :: ![SavePhase], saveCompletion :: !(Either SaveFailure CheckpointCommitted)
  , saveWarnings :: ![SaveFailure] }
  deriving (Eq,Show)

data FileRole = GenerationFile | ManifestFile deriving (Eq,Ord,Show)
data SaveOperation = Capture | WriteChunk FileRole Word64 | FlushFile FileRole
                   | VerifyFile FileRole | RenameGeneration | SyncDirectory FileRole
                   | ReplaceManifest | CommitReadback | CallbackValidation
                   | DeleteOldGeneration FilePath | CleanupDirectorySync
  deriving (Eq,Ord,Show)
data FaultTiming = Before | After deriving (Eq,Ord,Show)
data FaultPoint = FaultPoint !FaultTiming !SaveOperation deriving (Eq,Ord,Show)
data FaultEffect = Proceed | FailWith String | ShortWrite deriving (Eq,Show)
data SaveAdapter = SaveAdapter
  { adapterMutex :: !(MVar ()), adapterChunkBytes :: !Int
  , adapterFault :: FaultPoint -> IO FaultEffect }
newSaveAdapter :: Int -> (FaultPoint -> IO FaultEffect) -> IO SaveAdapter
newSaveAdapter chunk hook
  | chunk <= 0 || chunk > 1048576 = throwIO (InvalidStorage "chunk size must be 1..1048576")
  | otherwise = SaveAdapter <$> newMVar () <*> pure chunk <*> pure hook
nativeAdapter :: IO SaveAdapter
nativeAdapter = newSaveAdapter 65536 (const (pure Proceed))

data Generation = Generation
  { generationFile :: !FilePath, generationHash :: !BS.ByteString
  , generationMeta :: !CheckpointMeta, generationWorldId :: !Word64
  , generationBranchId :: !Word64, generationTick :: !SimTick }
  deriving (Eq,Show)
data RecoveryReport = RecoveryReport
  { recoveryAutomatic :: !(Maybe Generation)
  , recoveryCommitted :: ![Generation], recoveryCandidates :: ![Generation]
  , recoveryRejected :: ![(FilePath,String)], recoveryManifestProblem :: !(Maybe String) }
  deriving (Eq,Show)
data ManifestEntry = ManifestEntry !Word64 !FilePath !BS.ByteString deriving (Eq,Show)
data Manifest = Manifest !Word64 !Word64 ![ManifestEntry] deriving (Eq,Show)

manifestFilename :: FilePath
manifestFilename = "manifest.cbor"
generationFilename :: Word64 -> FilePath
generationFilename seqNo = "generation-" ++ show seqNo ++ ".save"
generationSequence :: FilePath -> Maybe Word64
generationSequence name = do
  digits <- stripPrefix "generation-" name >>= stripSuffix ".save"
  seqNo <- readMaybe digits
  if name == generationFilename seqNo then Just seqNo else Nothing
  where
    stripPrefix prefix value = if take (length prefix) value == prefix then Just (drop (length prefix) value) else Nothing
    stripSuffix suffix value = if drop (length value-length suffix) value == suffix then Just (take (length value-length suffix) value) else Nothing

-- Failed requests may leave tmp files. A retry gets a fresh sequence rather
-- than deleting or overwriting uncertain bytes. The final save still rechecks
-- under its writer lock; callers must serialize sequence allocation + capture.
nextCheckpointSequence :: FilePath -> IO (Either SaveFailure Word64)
nextCheckpointSequence directory = trySave $ do
  names <- listDirectory directory
  let sequenceOf name = case generationSequence name of
        Just seqNo -> Just seqNo
        Nothing -> case reverse name of
          'p':'m':'t':'.':rest ->
            let stem = reverse rest
                normalized = if take 9 stem == "manifest-" then "generation-" ++ drop 9 stem else stem
            in generationSequence (normalized ++ ".save")
          _ -> Nothing
      maximumUsed = maximum (0:mapMaybe sequenceOf names)
  when (maximumUsed == maxBound) (throwIO (InvalidStorage "checkpoint sequence exhausted"))
  pure (maximumUsed+1)

mapCodec :: Either CodecError a -> Either SaveFailure a
mapCodec = either (Left . InvalidSnapshot . show) Right
codecIO :: Either CodecError a -> IO a
codecIO = either (throwIO . InvalidStorage . show) pure
trySave :: IO a -> IO (Either SaveFailure a)
trySave action = (Right <$> action) `catch` (pure . Left :: SaveFailure -> IO (Either SaveFailure a))
  `catch` (\(err :: IOException) -> pure (Left (StorageIO (if isFullError err then DiskFull else if isPermissionError err then PermissionDenied else OtherIO) (show err))))

-- The cap is checked from fstat before reading, and again while reading, so a
-- file that grows concurrently cannot bypass the byte budget. Symlinks and
-- special files are rejected, not followed. No filenames from a manifest can
-- escape this directory: decodeManifest checks the exact generated filename.
readBounded :: Integer -> FilePath -> IO BS.ByteString
readBounded cap path = do
  handle <- bracketOnError
    (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \fd -> do
      status <- getFdStatus fd
      unless (isRegularFile status && toInteger (fileSize status) <= cap)
        (throwIO (InvalidStorage "not a regular file or exceeds byte limit"))
      fdToHandle fd
  bracket (pure handle) hClose $ \h -> go h 0 []
  where
    go handle used chunks = do
      chunk <- BS.hGet handle (fromInteger (min 65536 (cap-used+1)))
      if BS.null chunk then pure (BS.concat (reverse chunks)) else do
        let next = used + toInteger (BS.length chunk)
        when (next > cap) (throwIO (InvalidStorage "file exceeds byte limit"))
        go handle next (chunk:chunks)

readGeneration :: FilePath -> FilePath -> IO Generation
readGeneration directory name = do
  seqNo <- maybe (throwIO (InvalidStorage "invalid generation filename")) pure (generationSequence name)
  bytes <- readBounded (toInteger (maxPayloadBytes defaultDecodeLimits)) (directory </> name)
  (meta,world) <- codecIO (decodeCheckpoint bytes)
  unless (checkpointSequence meta == seqNo) (throwIO (InvalidStorage "filename/envelope sequence mismatch"))
  evaluate (Generation name (sha256 bytes) meta (worldId world) (branchId world) (simTick world))

-- Load one explicitly chosen descriptor; revalidate bytes and the descriptor's
-- full checkpoint hash so selection cannot silently load a changed file.
loadGeneration :: FilePath -> Generation -> IO World
loadGeneration directory generation = do
  unless (generationSequence (generationFile generation) == Just (checkpointSequence (generationMeta generation)))
    (throwIO (InvalidStorage "invalid selected generation filename"))
  bytes <- readBounded (toInteger (maxPayloadBytes defaultDecodeLimits)) (directory </> generationFile generation)
  unless (sha256 bytes == generationHash generation) (throwIO (InvalidStorage "selected generation changed"))
  (meta,world) <- codecIO (decodeCheckpoint bytes)
  unless (meta == generationMeta generation && worldId world == generationWorldId generation && branchId world == generationBranchId generation)
    (throwIO (InvalidStorage "selected generation identity mismatch"))
  evaluate (force world)

manifestBytes :: Manifest -> Either CodecError BS.ByteString
manifestBytes (Manifest world branch entries) = do
  payload <- encodeCanonical (CMap
    [(0,CText (T.pack "RDF-NATIVE-MANIFEST")),(1,CInteger 1),(2,word world),(3,word branch)
    ,(4,CArray [CArray [word seqNo,CText (T.pack name),CBytes hash] | ManifestEntry seqNo name hash <- entries])])
  encodeCanonical (CMap [(0,CBytes payload),(1,CBytes (sha256 payload)),(2,CText (T.pack "RDF-MANIFEST-END"))])
  where word = CInteger . toInteger

decodeManifest :: BS.ByteString -> Either CodecError Manifest
decodeManifest bytes = do
  root <- decodeCanonicalWith defaultDecodeLimits {maxPayloadBytes=65536,maxContainerItems=64,maxNodes=256,maxDepth=8} bytes
  payload <- case root of
    CMap [(0,CBytes body),(1,CBytes digest),(2,CText footer)]
      | digest == sha256 body && footer == T.pack "RDF-MANIFEST-END" -> Right body
    _ -> Left (CodecError "invalid manifest checksum/footer/envelope")
  body <- decodeCanonical payload
  case body of
    CMap [(0,CText magic),(1,CInteger 1),(2,CInteger world),(3,CInteger branch),(4,CArray terms)]
      | magic == T.pack "RDF-NATIVE-MANIFEST" && inWord world && inWord branch -> do
        unless (not (null terms) && length terms <= 3) (Left (CodecError "manifest requires current plus at most previous two"))
        entries <- mapM entry terms
        let sequences = [s | ManifestEntry s _ _ <- entries]
        unless (and (zipWith (>) sequences (drop 1 sequences))) (Left (CodecError "manifest generations not strictly newest first"))
        pure (Manifest (fromInteger world) (fromInteger branch) entries)
    _ -> Left (CodecError "unsupported/malformed manifest")
  where
    inWord n = n >= 0 && n <= toInteger (maxBound :: Word64)
    entry (CArray [CInteger seqNo,CText name,CBytes hash])
      | inWord seqNo && BS.length hash == 32 && T.unpack name == generationFilename (fromInteger seqNo)
      = Right (ManifestEntry (fromInteger seqNo) (T.unpack name) hash)
    entry _ = Left (CodecError "invalid manifest entry")

recoverCheckpoints :: FilePath -> IO RecoveryReport
recoverCheckpoints directory = do
  names <- listDirectory directory
  let generations = map snd (reverse (sortOn fst [(seqNo,name) | name <- names,Just seqNo <- [generationSequence name]]))
  inspected <- forM generations $ \name -> do
    result <- trySave (readGeneration directory name)
    pure (name,result)
  let valid = [generation | (_,Right generation) <- inspected]
      invalid = [(name,show err) | (name,Left err) <- inspected]
  marker <- trySave (readBounded 65536 (directory </> manifestFilename) >>= codecIO . decodeManifest)
  case marker of
    Left err -> pure (RecoveryReport Nothing [] valid invalid (Just (show err)))
    Right (Manifest world branch entries) -> do
      let matches (ManifestEntry seqNo name digest) generation =
            generationFile generation == name && checkpointSequence (generationMeta generation) == seqNo
            && generationHash generation == digest && generationWorldId generation == world
            && generationBranchId generation == branch
          selected = mapMaybe (\entry -> listToMaybe (filter (matches entry) valid)) entries
          referenced = [name | ManifestEntry _ name _ <- entries]
          mismatch = [(name,"manifest reference missing, corrupt, hash-mismatched or wrong world/branch")
                     | entry@(ManifestEntry _ name _) <- entries,not (any (matches entry) valid)]
          candidates = filter (\generation -> generationFile generation `notElem` map generationFile selected) valid
          manifestProblem = if null mismatch then Nothing else Just ("one or more of " ++ show referenced ++ " failed validation; using verified committed fallback if available")
      pure (RecoveryReport (listToMaybe selected) selected candidates (invalid++mismatch) manifestProblem)

fault :: SaveAdapter -> FaultTiming -> SaveOperation -> IO FaultEffect
fault adapter timing operation = do
  effect <- adapterFault adapter (FaultPoint timing operation)
  case effect of
    FailWith reason -> throwIO (InjectedFailure reason)
    ShortWrite -> case (timing,operation) of
      (Before,WriteChunk _ _) -> pure ShortWrite
      _ -> throwIO (InvalidStorage "ShortWrite injection is valid only before WriteChunk")
    Proceed -> pure Proceed
point :: SaveAdapter -> FaultTiming -> SaveOperation -> IO ()
point adapter timing operation = fault adapter timing operation >> pure ()
around :: SaveAdapter -> SaveOperation -> IO a -> IO a
around adapter operation action = do
  point adapter Before operation
  value <- action
  point adapter After operation
  pure value

writeFlushed :: SaveAdapter -> FileRole -> FilePath -> BS.ByteString -> IO () -> IO () -> IO ()
writeFlushed adapter role path bytes written flushed = bracket
  (openFd path WriteOnly defaultFileFlags {creat=Just 0o600,exclusive=True,nofollow=True,cloexec=True}) closeFd $ \fd -> do
    go fd 0 bytes
    written
    around adapter (FlushFile role) (fileSynchronise fd)
    flushed
  where
    go _ _ remaining | BS.null remaining = pure ()
    go fd index remaining = do
      let (chunk,rest) = BS.splitAt (adapterChunkBytes adapter) remaining
          operation = WriteChunk role index
      effect <- fault adapter Before operation
      let intended = BS.length chunk
          requested = if effect == ShortWrite then intended-1 else intended
      actual <- BS.useAsCString chunk $ \ptr -> fdWriteBuf fd (castPtr ptr) (fromIntegral requested)
      unless (toInteger actual == toInteger intended) (throwIO (ShortWriteDetected role index))
      point adapter After operation
      go fd (index+1) rest

syncDirectory :: FilePath -> IO ()
syncDirectory directory = bracket
  (openFd directory ReadOnly defaultFileFlags {directory=True,nofollow=True,cloexec=True}) closeFd fileSynchronise

-- Adapter-local mutex handles threads. Advisory lock handles other cooperating
-- processes. The lock file is neither a commit marker nor a recovery input.
withWriter :: SaveAdapter -> FilePath -> IO a -> IO a
withWriter adapter directory action = withMVar (adapterMutex adapter) $ \() -> bracket
  (openFd (directory </> ".checkpoint.lock") ReadWrite defaultFileFlags {creat=Just 0o600,nofollow=True,cloexec=True}) closeFd $ \fd -> do
    setLock fd (WriteLock,AbsoluteSeek,0,0)
    action

nativeSave :: SaveAdapter -> FilePath -> IO SaveIdentity -> CapturedSnapshot -> IO SaveResult
nativeSave adapter directory currentIdentity snapshot = do
  progress <- newIORef []
  warnings <- newIORef []
  let phase p = modifyIORef' progress (++[p])
      ticket = capturedTicket snapshot
      ident = ticketIdentity ticket
      seqNo = checkpointSequence (capturedMeta snapshot)
      name = generationFilename seqNo
      temp = "generation-" ++ show seqNo ++ ".tmp"
      manifestTemp = "manifest-" ++ show seqNo ++ ".tmp"
      entry generation = ManifestEntry (checkpointSequence (generationMeta generation)) (generationFile generation) (generationHash generation)
      receipt = CheckpointCommitted ticket seqNo (capturedTick snapshot) (capturedStateHash snapshot) name
      failUnless condition reason = unless condition (throwIO reason)
  result <- trySave $ do
    exists <- doesDirectoryExist directory
    failUnless exists (InvalidStorage "save directory must already exist and be durable")
    withWriter adapter directory $ do
      around adapter Capture (evaluate (BS.length (capturedBytes snapshot)) >> phase Captured)
      before <- recoverCheckpoints directory
      names <- listDirectory directory
      let occupied = mapMaybe generationSequence names
      failUnless (all (<seqNo) occupied) SequenceNotFresh
      failUnless (all (\g -> generationWorldId g == saveWorldId ident && generationBranchId g == saveBranchId ident)
                      (recoveryCommitted before ++ recoveryCandidates before))
                 (InvalidStorage "directory contains another world/branch")
      writeFlushed adapter GenerationFile (directory </> temp) (capturedBytes snapshot) (phase Written) (pure ())
      around adapter (VerifyFile GenerationFile) $ do
        bytes <- readBounded (toInteger (maxPayloadBytes defaultDecodeLimits)) (directory </> temp)
        failUnless (bytes == capturedBytes snapshot) (InvalidStorage "generation flush readback differs")
        _ <- codecIO (decodeCheckpoint bytes)
        pure ()
      phase Flushed
      -- This name cannot exist under this writer lock: all generation numbers
      -- were checked, and tmp creation is O_EXCL. Never overwrite a generation.
      around adapter RenameGeneration (renameFile (directory </> temp) (directory </> name))
      phase Renamed
      around adapter (SyncDirectory GenerationFile) (syncDirectory directory)
      let newEntry = ManifestEntry seqNo name (sha256 (capturedBytes snapshot))
          retained = take 2 (recoveryCommitted before)
          marker = Manifest (saveWorldId ident) (saveBranchId ident) (newEntry:map entry retained)
      markerBytes <- codecIO (manifestBytes marker)
      writeFlushed adapter ManifestFile (directory </> manifestTemp) markerBytes (pure ()) (pure ())
      around adapter (VerifyFile ManifestFile) $ do
        bytes <- readBounded 65536 (directory </> manifestTemp)
        failUnless (bytes == markerBytes) (InvalidStorage "manifest flush readback differs")
        _ <- codecIO (decodeManifest bytes)
        pure ()
      around adapter ReplaceManifest (renameFile (directory </> manifestTemp) (directory </> manifestFilename))
      around adapter (SyncDirectory ManifestFile) (syncDirectory directory)
      around adapter CommitReadback $ do
        bytes <- readBounded 65536 (directory </> manifestFilename)
        failUnless (bytes == markerBytes) (InvalidStorage "committed manifest readback differs")
        verified <- recoverCheckpoints directory
        failUnless (map generationFile (recoveryCommitted verified) == name:map generationFile retained)
                   (InvalidStorage "committed generation readback failed")
      phase ManifestCommitted
      around adapter CallbackValidation $ do
        current <- currentIdentity
        failUnless (current == ident) StaleCallback
      phase CallbackAccepted
      -- Only formerly committed entries dropped from this exact manifest are
      -- cleanup targets; orphan/unconfirmed/corrupt/foreign files are untouched.
      -- Cleanup failures are warnings after durable commit, never asset loss or
      -- a reason to conceal a valid persisted receipt.
      forM_ (drop 2 (recoveryCommitted before)) $ \old -> do
        outcome <- trySave (around adapter (DeleteOldGeneration (generationFile old)) (removeFile (directory </> generationFile old)))
        either (\err -> modifyIORef' warnings (++[err])) (const (pure ())) outcome
      when (length (recoveryCommitted before) > 2) $ do
        outcome <- trySave (around adapter CleanupDirectorySync (syncDirectory directory))
        either (\err -> modifyIORef' warnings (++[err])) (const (pure ())) outcome
      pure receipt
  SaveResult <$> readIORef progress <*> pure result <*> readIORef warnings
