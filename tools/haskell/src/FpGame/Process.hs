{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Execute argument arrays, never a shell command. Captured children share
-- their request's lifetime via POSIX groups or Windows Job Objects. Interactive
-- POSIX commands replace this process so the caller's shell owns job control.
module FpGame.Process
  ( ProcessRequest (..),
    Capture (..),
    execute,
    requireTool,
    withTerminationHandler,
  )
where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
import Control.Monad (void, when)
import Data.ByteString qualified as Bytes
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error (lenientDecode)
import FpGame.Error
import FpGame.Path
import FpGame.Result
import System.Directory (findExecutable)
import System.Exit
import System.IO (Handle, hClose)
import System.Process
import System.Timeout (timeout)
#ifndef mingw32_HOST_OS
import Control.Concurrent (myThreadId)
import System.Directory (makeAbsolute, withCurrentDirectory)
import System.Posix.Process (executeFile)
import System.Posix.Signals (Handler(Catch), installHandler, signalProcessGroup, sigKILL, sigTERM)
#endif

data Capture = Captured | Interactive deriving (Eq, Show)

data ProcessRequest = ProcessRequest
  { processExecutable :: FilePath,
    processArguments :: [String],
    processTimeoutSeconds :: Maybe Int,
    processCapture :: Capture
  }
  deriving (Eq, Show)

requireTool :: String -> IO FilePath
requireTool name = findExecutable name >>= maybe (failTool MissingTool (name ++ " is missing. Run doctor and follow docs/setup.md.")) pure

execute :: ProjectRoot -> ProcessRequest -> IO Result
execute root request = runSelected root request `catch` failedIO
  where
    failedIO :: IOException -> IO Result
    failedIO errorValue = pure (Executed command 1 "" (Text.pack (show errorValue)))
    command = processExecutable request : processArguments request

runSelected :: ProjectRoot -> ProcessRequest -> IO Result
#ifdef mingw32_HOST_OS
runSelected = capturedProcess
#else
runSelected root request
  | processCapture request == Interactive = do
      -- Resolve before changing cwd. Successful exec does not return: Cabal
      -- inherits this shell job's PID, process group, terminal and streams.
      executable <- makeAbsolute (processExecutable request)
      withCurrentDirectory (projectPath root) $
        executeFile executable False (processArguments request) Nothing
  | otherwise = capturedProcess root request
#endif

capturedProcess :: ProjectRoot -> ProcessRequest -> IO Result
capturedProcess root request = mask $ \restore ->
  -- Keep ownership setup masked until the child group and cleanup are known.
  -- Only the wait is restored to the caller's interruptibility; cancellation
  -- after createProcess cannot slip between acquisition and the stop handler.
  bracket (createProcess configuration) closePipes $ \(_, output, errors, process) -> do
    -- Obtain the group identifier before waitForProcess closes the process handle.
    processId <- getPid process
    stopped <- newIORef False
    let stop = do
          firstStop <- atomicModifyIORef' stopped (\previous -> (True, not previous))
          when firstStop $ do
            stopTree process processId
            void (waitForProcess process)
        waitCaptured = case (output, errors) of
          (Just outputHandle, Just errorHandle) ->
            withReader stop outputHandle $ \readOutput ->
              withReader stop errorHandle $ \readErrors -> do
                code <- waitForProcess process
                out <- readOutput
                err <- readErrors
                pure (code, out, err)
          _ -> failTool ToolIO "Could not create process capture pipes."
        waitInteractive = do
          code <- waitForProcess process
          pure (code, Bytes.empty, Bytes.empty)
        wait = if processCapture request == Captured then waitCaptured else waitInteractive
        waitWithDeadline = case processTimeoutSeconds request of
          Nothing -> Just <$> wait
          Just seconds -> timeout (seconds * 1000000) wait
    completed <- restore waitWithDeadline `onException` stop
    case completed of
      Nothing -> stop >> pure (Executed command 1 "" "Command timed out; process tree terminated.")
      Just (code, out, err) -> pure (Executed command (exitNumber code) (decode out) (decode err))
  where
    command = processExecutable request : processArguments request
    capturing = processCapture request == Captured
    configuration =
      (proc (processExecutable request) (processArguments request))
        { cwd = Just (projectPath root),
          std_in = if capturing then NoStream else Inherit,
          std_out = if capturing then CreatePipe else Inherit,
          std_err = if capturing then CreatePipe else Inherit,
          create_group = True,
          use_process_jobs = True
        }
    closePipes (_, out, err, _) = mapM_ (maybe (pure ()) (ignoreIO . hClose)) [out, err]
    -- Capture is a text protocol: replace invalid UTF-8, then match Python's
    -- universal-newline handling. This does not claim binary byte equivalence.
    -- Interactive children inherit their streams and bypass this conversion.
    decode = Text.replace "\r" "\n" . Text.replace "\r\n" "\n" . Text.decodeUtf8With lenientDecode
    exitNumber ExitSuccess = 0
    exitNumber (ExitFailure code) = if code < 0 then 128 - code else code

stopTree :: ProcessHandle -> Maybe Pid -> IO ()
#ifdef mingw32_HOST_OS
stopTree process _ = ignoreIO (terminateProcess process)
#else
stopTree process processId =
  maybe (ignoreIO (terminateProcess process)) (ignoreIO . signalProcessGroup sigKILL) processId
#endif

-- Terminate before cancelling pipe readers: a reader may be in a blocking OS
-- read, so waiting for killThread first can delay cancellation until the child
-- finishes naturally. Mask setup and stop once across nested readers, then
-- cancel readers before closing handles. Strict bytes avoid deferred reads.
withReader :: IO () -> Handle -> (IO Bytes.ByteString -> IO a) -> IO a
withReader stop pipe action = mask $ \restore -> do
  result <- newEmptyMVar
  bracket
    (forkIO $ (try (Bytes.hGetContents pipe) :: IO (Either IOException Bytes.ByteString)) >>= putMVar result)
    killThread
    (\_ -> restore (action (takeMVar result >>= either throwIO pure)) `onException` stop)

ignoreIO :: IO () -> IO ()
ignoreIO action = action `catch` (\(_ :: IOException) -> pure ())

#ifndef mingw32_HOST_OS
data Terminated = Terminated deriving (Show)
instance Exception Terminated
#endif

withTerminationHandler :: IO () -> IO ()
#ifndef mingw32_HOST_OS
withTerminationHandler action =
  (do
    thread <- myThreadId
    bracket
      (installHandler sigTERM (Catch (throwTo thread Terminated)) Nothing)
      (\old -> void (installHandler sigTERM old Nothing))
      (\_ -> action)) `catch` (\Terminated -> exitWith (ExitFailure 143))
#else
withTerminationHandler action = action
#endif
