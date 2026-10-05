{-# LANGUAGE RecordWildCards #-}
-- Independent imperative shell laboratory, importing the unchanged 0.2 core.
-- This is not a shipped UI. Persistence is isolated per request, not one slot.
module Main where
import Colony.Save
import Colony.Types (Epoch(..), SimTick(..))
import Colony.World (World(..), initialWorld)
import Colony.Content (loadContent)
import Colony.Codec (CheckpointMeta(..), canonicalStateHash)
import Control.Monad (foldM, unless)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Exit (die)

data Mode = Correct | EpochMutant | ActiveMutant | PersistMutant deriving (Eq,Show,Read)
data Job = Job { jobTicket :: SaveTicket, jobSnapshot :: CapturedSnapshot,
                 jobPhase :: String, jobRevision :: Int, jobBranch :: Int,
                 jobAccepts :: Int, jobAcceptedEpoch :: Int, jobResult :: Maybe SaveResult }
data Shell = Shell { shEpoch :: Int, shBranch :: Int, shRevision :: Int,
                     shQueue :: SaveQueue, shJobs :: M.Map Int Job,
                     shReceipt :: Int, shSaved :: Bool, shWorld :: World }
epochOf :: Int -> Int
epochOf r = (r-1) `div` 2
idOf :: Int -> Int
idOf r = (r-1) `mod` 2 + 1
ident :: Shell -> SaveIdentity
ident s = identityFor (Epoch "tlc-lab" (fromIntegral (shEpoch s))) (shWorld s)
active :: Shell -> Int
active = maybe 0 (fromIntegral . ticketSerial) . queueActive . shQueue
check :: String -> Bool -> IO ()
check msg ok = unless ok (die msg)
jsonBool :: Bool -> String
jsonBool b = if b then "true" else "false"
stateJson :: String -> Int -> Shell -> String
stateJson ev req s@Shell{..} = "{" ++ intercalate "," fields ++ "}"
 where
  field k v = show k ++ ":" ++ v
  values f def = "[" ++ intercalate "," [maybe def f (M.lookup r shJobs) | r <- [1..4]] ++ "]"
  fields = [field "event" (show ev), field "request" (show req), field "epoch" (show shEpoch),
    field "branch" (show shBranch), field "revision" (show shRevision), field "active" (show (active s)),
    field "receipt" (show shReceipt), field "saved" (jsonBool shSaved),
    field "phase" (values (show . jobPhase) (show "unused")),
    field "captured" (values (show . jobRevision) "0"),
    field "capturedBranch" (values (show . jobBranch) "0"),
    field "acceptedEpoch" (values (show . jobAcceptedEpoch) "0"),
    field "accepted" (values (show . jobAccepts) "0")]

step :: Mode -> FilePath -> Shell -> (String,Int) -> IO Shell
step mode root s@Shell{..} (ev,r) = case ev of
 "Start" -> do
  check "Start out of scope" (r >= 1 && r <= 4 && epochOf r == shEpoch && active s == 0 && M.notMember r shJobs)
  let ticket = SaveTicket (ident s) (fromIntegral (idOf r)) ManualSave
      world = shWorld {simTick = SimTick (fromIntegral shRevision)}
  snap <- either (die . show) pure (captureSnapshot ticket (CheckpointMeta 1 Nothing "tlc-lab") world)
  let (admission,q) = enqueueSave ticket shQueue
  check "real enqueueSave did not start" (admission == Started)
  pure s {shQueue=q, shJobs=M.insert r (Job ticket snap "writing" shRevision shBranch 0 0 Nothing) shJobs}
 "Persist" -> do
  j <- getJob
  check "Persist requires writing" (jobPhase j == "writing")
  let dir = root </> ("request-" ++ show r)
  createDirectoryIfMissing True dir
  adapter <- nativeAdapter
  result <- nativeSave adapter dir (pure (ident s)) (jobSnapshot j)
  check ("real save did not reach ManifestCommitted: " ++ show result) (ManifestCommitted `elem` saveProgress result)
  case saveCompletion result of
   Left _ -> pure ()
   Right receipt -> do
    check "receipt ticket differs" (committedTicket receipt == jobTicket j)
    check "receipt tick differs from capture" (committedTick receipt == capturedTick (jobSnapshot j))
    check "receipt tick differs from requested revision" (committedTick receipt == SimTick (fromIntegral (jobRevision j)))
    check "receipt hash differs from capture" (committedStateHash receipt == capturedStateHash (jobSnapshot j))
  recovered <- recoverCheckpoints dir
  generation <- maybe (die "real committed generation unavailable") pure (recoveryAutomatic recovered)
  loaded <- loadGeneration dir generation
  digest <- either (die . show) pure (canonicalStateHash loaded)
  check "readback snapshot hash differs" (digest == capturedStateHash (jobSnapshot j))
  check "readback tick differs" (simTick loaded == capturedTick (jobSnapshot j))
  putStrLn ("NATIVE " ++ show r ++ " " ++ show result)
  pure s {shJobs=M.insert r j {jobPhase="persisted",jobResult=Just result} shJobs}
 "Fail" -> do
  j <- getJob
  check "Fail requires writing" (jobPhase j == "writing")
  let dir = root </> ("request-" ++ show r)
  createDirectoryIfMissing True dir
  adapter <- newSaveAdapter 65536 (\p -> pure $ if p == FaultPoint Before Capture then FailWith "lab failure before first write" else Proceed)
  result <- nativeSave adapter dir (pure (ident s)) (jobSnapshot j)
  check "failure became success" (case saveCompletion result of Left _ -> True; Right _ -> False)
  check "failure reached commit" (ManifestCommitted `notElem` saveProgress result)
  putStrLn ("NATIVE " ++ show r ++ " " ++ show result)
  pure s {shJobs=M.insert r j {jobPhase="failed",jobResult=Just result} shJobs}
 "Callback" -> do
  j <- getJob
  let p = jobPhase j
      enabled = p `elem` ["persisted","failed"] || mode == PersistMutant && p == "writing"
  if not enabled then do
   putStrLn "NOTE callback of uncompleted storage rejected before real finishSave"
   pure s
  else do
   let (realMatch, realQueue) = finishSave (jobTicket j) shQueue
       matching = case mode of
        EpochMutant -> active s == idOf r && jobBranch j == shBranch
        ActiveMutant -> ticketIdentity (jobTicket j) == ident s
        _ -> realMatch
       success = p /= "failed"
       genuineSuccess = maybe False (either (const False) (const True) . saveCompletion) (jobResult j)
   if mode == Correct && matching && success then check "core receipt is not successful" genuineSuccess else pure ()
   putStrLn ("MATCH request=" ++ show r ++ " realQueue=" ++ show realMatch ++ " lab=" ++ show matching)
   let q = if matching then (if realMatch then realQueue else emptySaveQueue (ident s)) else shQueue
       next = s {shQueue=q}
   pure $ if matching && success then next {shJobs=M.insert r j {jobAccepts=min 2 (jobAccepts j+1),jobAcceptedEpoch=shEpoch} shJobs,
                    shReceipt=r, shSaved=jobRevision j == shRevision} else next
 "Drop" -> do
  j <- getJob
  check "Drop requires terminal storage" (jobPhase j `elem` ["persisted","failed"])
  pure s
 "Edit" -> do
  check "Edit out of bound" (shRevision == 0)
  pure s {shRevision=1,shSaved=False,shWorld=shWorld {simTick=SimTick 1}}
 "Load" -> advance False
 "NewBranch" -> advance True
 _ -> die ("unknown event: " ++ ev)
 where
  getJob = maybe (die ("unknown request " ++ show r)) pure (M.lookup r shJobs)
  advance fresh = do
   check "epoch bound exceeded" (shEpoch == 0)
   let b = if fresh then 1 else shBranch
       world = shWorld {branchId=fromIntegral (b+1),simTick=SimTick 0}
       next = s {shEpoch=shEpoch+1, shBranch=b,shRevision=0,shReceipt=0,shSaved=False,shWorld=world}
   pure next {shQueue=emptySaveQueue (ident next)}

parseEvent :: String -> IO (String,Int)
parseEvent line = case words line of
 [e,r] -> pure (e,read r)
 _ -> die ("bad event " ++ line)
main :: IO ()
main = do
 args <- getArgs
 case args of
  [modeArg,contentPath,eventsPath,root] -> do
   mode <- maybe (die "bad mode") pure (lookup modeArg [(show m,m) | m <- [Correct,EpochMutant,ActiveMutant,PersistMutant]])
   content <- loadContent contentPath >>= either die pure
   let world = (initialWorld content) {branchId=1,simTick=SimTick 0}
       zero = Shell 0 0 0 (emptySaveQueue (identityFor (Epoch "tlc-lab" 0) world)) M.empty 0 False world
   events <- readFile eventsPath >>= mapM parseEvent . filter (not . null) . lines
   putStrLn ("STATE " ++ stateJson "Init" 0 zero)
   _ <- foldM (\s ev@(name,r) -> do n <- step mode root s ev; putStrLn ("STATE " ++ stateJson name r n); pure n) zero events
   pure ()
  _ -> die "usage: lifecycle MODE CONTENT EVENTS ISOLATED_SAVE_ROOT"
