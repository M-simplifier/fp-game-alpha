-- Test-build instrumentation only. It pauses delivery of an already computed
-- nativeSave result, not the save protocol, World, or callback-admission code.
-- The ordinary application does not import this module.
module SaveReceiptBarrier(awaitReceiptDelivery) where
import Control.Concurrent(threadDelay)
import Control.Monad(unless)
import Data.Word(Word64)
import System.Directory(doesFileExist)
import System.Environment(getEnv)
import System.FilePath((</>))

awaitReceiptDelivery :: Word64 -> IO()
awaitReceiptDelivery marker=if marker/=2000 then pure()else do
  root<-getEnv "RED_DUNE_TEST_BARRIER_DIR"
  writeFile(root </> "ready")"nativeSave result computed; completion delivery held\n"
  let wait=do
        released<-doesFileExist(root </> "release")
        unless released(threadDelay 1000>>wait)
  wait
