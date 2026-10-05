module Main (main) where

import Control.Exception (AsyncException (UserInterrupt), IOException, catch, throwIO)
import Data.Text qualified as Text
import FpGame.CLI
import FpGame.Command
import FpGame.Error
import FpGame.Process (withTerminationHandler)
import FpGame.Result
import System.Environment (getArgs)
import System.Exit
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)

main :: IO ()
main = withTerminationHandler (mainBody `catch` interrupted)
  where
    interrupted UserInterrupt = exitWith (ExitFailure 130)
    interrupted other = throwIO other

mainBody :: IO ()
mainBody = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  arguments <- getArgs
  case arguments of
    ["--help"] -> putStr usage
    ["-h"] -> putStr usage
    ["--version"] -> putStrLn "fp-game 0.1.0.0"
    _ -> case parseOptions arguments of
      Left message -> hPutStrLn stderr (message ++ "\n" ++ usage) >> exitWith (ExitFailure 2)
      Right options -> do
        result <- runCommand options `catch` (pure . failure) `catch` ioFailure
        render (jsonOutput options) result
        exitWith (if resultCode result == 0 then ExitSuccess else ExitFailure (resultCode result))
  where
    ioFailure :: IOException -> IO Result
    ioFailure errorValue = pure (failure (ToolError ToolIO (Text.pack (show errorValue))))
