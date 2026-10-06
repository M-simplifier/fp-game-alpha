-- | Only the developer component loads this module. Heap values never survive a
-- reload: stop joins runHost (and therefore its children) before GHCi reloads.
module Main (main, start, stop, Handle) where

import Control.Concurrent (ThreadId, forkFinally, killThread)
import Control.Concurrent.MVar
import Control.Exception (SomeException, mask)
import RedDune.ContentPack (decodePack, defaultPack)
import RedDune.Host (HostConfig (..), runHost)
import System.Environment (setEnv)

data Handle = Handle !ThreadId !(MVar (Either SomeException ()))

main :: IO ()
main = putStrLn "Use bash references/red-dune-live/tools/dev.sh from the repository root."

start :: String -> Int -> FilePath -> FilePath -> Maybe FilePath -> IO Handle
start revision port store ui packPath = do
  pack <- maybe (pure defaultPack) (\path -> readFile path >>= either fail pure . decodePack) packPath
  setEnv "RED_DUNE_DEV_REVISION" revision
  mask $ \restore -> do
    done <- newEmptyMVar
    child <- forkFinally (restore (runHost (HostConfig port store ui) pack)) (putMVar done)
    pure (Handle child done)

stop :: Handle -> IO ()
stop (Handle child done) = do
  killThread child
  _ <- readMVar done
  pure ()
