module ProcessSpec (runProcessTests, processChildMode) where

import Control.Concurrent (forkFinally, killThread, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (onException)
import Control.Monad (forM, forM_, unless)
import Data.Text qualified as Text
import FpGame.Path (selectProject)
import FpGame.Process
import FpGame.Result (Result (Executed))
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (canonicalizePath, doesFileExist, removePathForcibly)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure), die, exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStr, hPutStrLn, hSetBuffering, hSetEncoding, hSetNewlineMode, noNewlineTranslation, stderr, stdout, utf8)
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Process (getCurrentPid)
import System.Timeout (timeout)

-- Use this compiled test executable as the child on every platform. There is
-- no shell, Python dependency, Unix-only sleep command, or substitute process
-- implementation in these fixtures.
processChildMode :: [String] -> Maybe (IO ())
processChildMode ["--process-gate", started, release, late] = Just $ do
  pid <- getCurrentPid
  writeFile started (show pid <> "\n")
  let awaitRelease = do
        allowed <- doesFileExist release
        unless allowed (threadDelay 1000 >> awaitRelease)
  awaitRelease
  writeFile late "released effect\n"
processChildMode ["--process-echo", message] = Just $ do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetNewlineMode stdout noNewlineTranslation
  hSetNewlineMode stderr noNewlineTranslation
  putStrLn message
  hPutStrLn stderr "child diagnostic"
  exitWith (ExitFailure 7)
processChildMode ["--process-newlines"] = Just $ do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetNewlineMode stdout noNewlineTranslation
  hSetNewlineMode stderr noNewlineTranslation
  hPutStr stdout "stdout 日本語\r\nmiddle\rlast\n"
  hPutStr stderr "stderr 日本語\r\nmiddle\rlast\n"
processChildMode _ = Nothing

runProcessTests :: IO ()
runProcessTests = do
  hSetBuffering stdout LineBuffering
  temporary <- getCanonicalTemporaryDirectory >>= \base -> createTempDirectory base "fp-game-process-tests"
  directory <- canonicalizePath temporary
  runCases directory `onException` hPutStrLn stderr ("Process failure fixtures retained at " <> directory)
  removePathForcibly directory

runCases :: FilePath -> IO ()
runCases directory = do
  root <- selectProject (Just directory)
  executable <- getExecutablePath
  putStrLn "Process phase: captured arguments and streams"
  let literal = "spaces 日本語 'quotes' \"double\" ; $HOME & --flag"
  echoed <- execute root (ProcessRequest executable ["--process-echo", literal] (Just 20) Captured)
  expect "argument arrays, child stdout/stderr and nonzero exit are preserved" $ case echoed of
    Executed command 7 output errors ->
      command == [executable, "--process-echo", literal]
        && output == Text.pack (literal <> "\n")
        && errors == Text.pack "child diagnostic\n"
    _ -> False

  putStrLn "Process phase: captured universal newlines"
  newlines <- execute root (ProcessRequest executable ["--process-newlines"] (Just 20) Captured)
  expect "captured stdout and stderr use universal newlines without losing Unicode" $ case newlines of
    Executed _ 0 output errors ->
      output == Text.pack "stdout 日本語\nmiddle\nlast\n"
        && errors == Text.pack "stderr 日本語\nmiddle\nlast\n"
    _ -> False

  putStrLn "Process phase: positive release gate"
  -- Positive control: the real child waits at the gate and writes when released.
  let positiveStarted = directory </> "positive-started"
      positiveRelease = directory </> "positive-release"
      positiveLate = directory </> "positive-late"
  positiveDone <- newEmptyMVar
  positiveThread <-
    forkFinally
      (execute root (ProcessRequest executable ["--process-gate", positiveStarted, positiveRelease, positiveLate] (Just 20) Captured))
      (putMVar positiveDone)
  positiveReady <- timeout 5000000 (awaitFile positiveStarted)
  unless (positiveReady == Just ()) (killThread positiveThread)
  expect "positive gate child started" (positiveReady == Just ())
  premature <- doesFileExist positiveLate
  expect "gate prevents effects before release" (not premature)
  writeFile positiveRelease "release positive control\n"
  positiveResult <- takeMVar positiveDone
  expect "released child exits normally" $ case positiveResult of
    Right (Executed _ 0 _ _) -> True
    _ -> False
  released <- doesFileExist positiveLate
  expect "released child produces the observable effect" released

  -- Vary early acquisition cancellation, then cancel once after a deterministic
  -- child-start handshake. forkFinally masks fixture setup too. Every child's
  -- effect is gated until after cancellation completes, not a wall-clock delay.
  lateFiles <- forM [1 .. 81 :: Int] $ \number -> do
    putStrLn ("Process phase: cancel case " <> show number <> "/81")
    let started = directory </> ("started-" <> show number)
        late = directory </> ("late-" <> show number)
        release = directory </> ("release-" <> show number)
    began <- getMonotonicTimeNSec
    finished <- newEmptyMVar
    thread <-
      forkFinally
        (execute root (ProcessRequest executable ["--process-gate", started, release, late] (Just 20) Captured))
        (putMVar finished)
    if number == 81
      then do
        ready <- timeout 5000000 (awaitFile started)
        unless (ready == Just ()) (killThread thread)
        expect "cancellation fixture reached the child-start barrier" (ready == Just ())
        putStrLn "Process phase: started-child barrier reached; requesting cancellation"
      else threadDelay ((number `mod` 10) * 50)
    requested <- getMonotonicTimeNSec
    killThread thread
    outcome <- takeMVar finished
    returned <- getMonotonicTimeNSec
    -- Release only after cancellation returned. A late file can no longer be
    -- explained by a child effect committed before cancellation was requested.
    writeFile release "parent cancellation completed\n"
    let detail =
          "case="
            <> show number
            <> " requested_us="
            <> show ((requested - began) `div` 1000)
            <> " returned_us="
            <> show ((returned - began) `div` 1000)
            <> " outcome="
            <> show outcome
    writeFile (directory </> ("case-" <> show number <> ".txt")) detail
    pure (late, detail)

  putStrLn "Process phase: closed-gate child timeout (1 second)"
  let timeoutStarted = directory </> "timeout-started"
      timeoutLate = directory </> "timeout-late"
      timeoutRelease = directory </> "timeout-release"
  timed <- execute root (ProcessRequest executable ["--process-gate", timeoutStarted, timeoutRelease, timeoutLate] (Just 1) Captured)
  writeFile timeoutRelease "timeout returned\n"
  expect "captured timeout terminates the child" $ case timed of
    Executed _ 1 _ errors -> Text.pack "timed out" `Text.isInfixOf` errors
    _ -> False
  started <- doesFileExist timeoutStarted
  expect "timeout fixture started a real child" started
  putStrLn "Process phase: joined cancellation and timeout; checking post-return releases"
  threadDelay 1000000
  forM_ ((timeoutLate, "timeout") : lateFiles) $ \(path, detail) -> do
    leaked <- doesFileExist path
    expect ("cancelled process tree produced a post-cancellation file: " <> detail) (not leaked)
  putStrLn "Process cancellation and stream boundary tests passed"
  where
    expect label condition = unless condition (die label)
    awaitFile path = do
      exists <- doesFileExist path
      unless exists (threadDelay 1000 >> awaitFile path)
