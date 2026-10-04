{-# LANGUAGE ForeignFunctionInterface #-}
module Browser where
import Data.IORef
import Foreign.C.String (CString, newCString)
import Foreign.C.Types (CInt(..))
import Foreign.Marshal.Alloc (free)
import Foreign.StablePtr
import Game.Arena
import Paper.Game
import Paper.View

type Session = IORef World
newSession :: IO (StablePtr Session)
newSession = newIORef initial >>= newStablePtr

action :: StablePtr Session -> CInt -> IO CInt
action handle index = do
  ref <- deRefStablePtr handle
  world <- readIORef ref
  let command = if index == -1 then Just Restart else if index == -2 then Just Undo else Rotate <$> cell (toInteger index)
  case command of
    Nothing -> pure 0
    Just input -> case play Circuit () (singleton Gardener input) world of
      Left () -> pure 0
      Right (next, outcomes) -> do
        writeIORef ref next
        pure (if outcomes == [Refused] then 0 else 1)

renderSession :: StablePtr Session -> IO CString
renderSession handle = deRefStablePtr handle >>= readIORef >>= newCString . render
readMoves :: StablePtr Session -> IO CInt
readMoves handle = fromIntegral . movesLeft <$> (deRefStablePtr handle >>= readIORef)
readPhase :: StablePtr Session -> IO CInt
readPhase handle = do
  world <- deRefStablePtr handle >>= readIORef
  pure (case phase world of Playing -> 0; Won -> 1; OutOfMoves -> 2)
freeText :: CString -> IO ()
freeText = free
freeSession :: StablePtr Session -> IO ()
freeSession = freeStablePtr

foreign export ccall newSession :: IO (StablePtr Session)
foreign export ccall action :: StablePtr Session -> CInt -> IO CInt
foreign export ccall renderSession :: StablePtr Session -> IO CString
foreign export ccall readMoves :: StablePtr Session -> IO CInt
foreign export ccall readPhase :: StablePtr Session -> IO CInt
foreign export ccall freeText :: CString -> IO ()
foreign export ccall freeSession :: StablePtr Session -> IO ()
