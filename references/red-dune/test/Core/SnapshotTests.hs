module Core.SnapshotTests (snapshotTests) where

import Colony.Codec
import Colony.KnownCatalog (knownCatalogV1)
import Colony.Save
import Colony.Types
import Colony.World
import Control.Exception (bracket)
import Control.Monad (unless)
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.IO (hClose, openTempFile)

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

snapshotTests :: IO ()
snapshotTests = bracket freshDirectory removePathForcibly $ \directory -> do
  let initial = initialWorld knownCatalogV1
      identity = identityFor (Epoch "snapshot-test" 1) initial
      ticket serial = SaveTicket identity serial ManualSave
      meta sequenceNo = defaultCheckpointMeta {checkpointSequence = sequenceNo}
      at tick = initial {simTick = SimTick tick, boundarySeq = BoundarySeq tick}
  adapter <- nativeAdapter
  snapshot <- must (captureSnapshot (ticket 1) (meta 1) initial)
  digest <- must (canonicalStateHash initial)
  bytes <- must (encodeCheckpoint (meta 1) initial)
  unless (capturedTicket snapshot == ticket 1 && capturedMeta snapshot == meta 1 && capturedTick snapshot == SimTick 0 && capturedStateHash snapshot == digest) $
    fail "capture queries do not describe the actual immutable payload"
  let expectedShow =
        "CapturedSnapshot {capturedTicket = "
          ++ show (ticket 1)
          ++ ", capturedMeta = "
          ++ show (meta 1)
          ++ ", capturedTick = SimTick 0, capturedStateHash = "
          ++ show digest
          ++ ", capturedBytes = "
          ++ show bytes
          ++ "}"
  unless (show snapshot == expectedShow && showsPrec 11 snapshot "" == "(" ++ expectedShow ++ ")") $
    fail "private snapshot representation changed the diagnostic Show contract"
  first <- nativeSave adapter directory (pure identity) snapshot
  committed <- must (saveCompletion first)
  report <- recoverCheckpoints directory
  generation <- case recoveryAutomatic report of
    Just value -> pure value
    Nothing -> fail "acknowledged save is not recoverable"
  restored <- loadGeneration directory generation
  unless (restored == initial && committedTick committed == simTick restored && committedStateHash committed == digest && committedTicket committed == ticket 1 && generationMeta generation == meta 1) $
    fail "accepted receipt disagrees with the actual recovered tick, state, ticket or sequence"
  unless (saveProgress first == [Captured, Written, Flushed, Renamed, ManifestCommitted, CallbackAccepted]) $
    fail "save publication/callback chronology changed"
  second <- must (captureSnapshot (ticket 2) (meta 2) (at 1))
  saved <- nativeSave adapter directory (pure identity) second
  _ <- must (saveCompletion saved)
  third <- must (captureSnapshot (ticket 3) (meta 3) (at 2))
  stale <- nativeSave adapter directory (pure identity {saveEpoch = Epoch "retired-session" 2}) third
  durable <- recoverCheckpoints directory
  unless
    ( saveCompletion stale == Left StaleCallback
        && saveProgress stale == [Captured, Written, Flushed, Renamed, ManifestCommitted]
        && fmap generationTick (recoveryAutomatic durable) == Just (SimTick 2)
    )
    $ fail "stale callback either acknowledged a retired request or erased its already-durable generation"
  putStrLn "Snapshot: accepted receipt agrees with recovered bytes; late stale callback preserves the durable generation"
  where
    freshDirectory = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "red-dune-core-boundary-"
      hClose handle
      removeFile path
      createDirectory path
      pure path
