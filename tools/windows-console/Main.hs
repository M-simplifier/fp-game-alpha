{-# LANGUAGE ForeignFunctionInterface #-}

-- Internal Windows host glue. The outer process keeps the caller's console
-- and streams; the hidden child owns a UTF-8 console inherited by Cabal/GHC/ar.
module Main (main) where

import Data.Word (Word32)
import Foreign (Ptr, alloca, peek)
import Foreign.C.String (CWString, withCWString)
import Foreign.C.Types (CInt (..))
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.Process (rawSystem, showCommandForUser)
import System.Win32.Console (setConsoleCP, setConsoleOutputCP)
import System.Win32.Types (failIfFalse_)

foreign import ccall safe "fp_game_hidden_console"
  hiddenConsole :: CWString -> Ptr Word32 -> IO CInt

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "--child" : command : rest -> do
      setConsoleCP 65001
      setConsoleOutputCP 65001
      rawSystem command rest >>= exitWith
    command : rest -> do
      self <- getExecutablePath
      -- This is the process library's Win32 argument encoding, passed directly
      -- to CreateProcessW. No shell is involved.
      let line = showCommandForUser self ("--child" : command : rest)
      code <- withCWString line $ \text -> alloca $ \result -> do
        failIfFalse_ "hidden UTF-8 console" ((/= 0) <$> hiddenConsole text result)
        peek result
      exitWith (if code == 0 then ExitSuccess else ExitFailure (fromIntegral code))
    [] -> ioError (userError "Internal console helper requires an executable and argument array.")
