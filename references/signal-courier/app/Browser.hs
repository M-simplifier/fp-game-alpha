{-# LANGUAGE ForeignFunctionInterface #-}

module Browser where

import Data.IORef
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (free)
import Foreign.StablePtr
import Game.Transition
import Signal.Game
import Signal.View

newSession :: IO (StablePtr (IORef Session))
newSession = newIORef initial >>= newStablePtr

action :: StablePtr (IORef Session) -> CInt -> IO CInt
action handle code = case decodeCommand (fromIntegral code) of
  Nothing -> pure 0
  Just input -> do
    ref <- deRefStablePtr handle
    modifyIORef' ref (fst . stepMachine Courier input)
    pure 1

renderSession :: StablePtr (IORef Session) -> IO CString
renderSession handle = deRefStablePtr handle >>= readIORef >>= newCString . render

readPhase :: StablePtr (IORef Session) -> IO CInt
readPhase handle = do
  current <- view <$> (deRefStablePtr handle >>= readIORef)
  pure (case status current of Delivering -> 0; Complete -> 1; Exhausted -> 2)

readTicks :: StablePtr (IORef Session) -> IO CInt
readTicks handle = fromIntegral . elapsedTicks . view <$> (deRefStablePtr handle >>= readIORef)

freeText :: CString -> IO ()
freeText = free

freeSession :: StablePtr (IORef Session) -> IO ()
freeSession = freeStablePtr

foreign export ccall newSession :: IO (StablePtr (IORef Session))

foreign export ccall action :: StablePtr (IORef Session) -> CInt -> IO CInt

foreign export ccall renderSession :: StablePtr (IORef Session) -> IO CString

foreign export ccall readPhase :: StablePtr (IORef Session) -> IO CInt

foreign export ccall readTicks :: StablePtr (IORef Session) -> IO CInt

foreign export ccall freeText :: CString -> IO ()

foreign export ccall freeSession :: StablePtr (IORef Session) -> IO ()
