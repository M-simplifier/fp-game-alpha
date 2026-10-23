module Main (main) where

import Control.Monad (unless)
import River.Gameplay qualified as Gameplay
import River.Protocol qualified as Protocol
import River.Snapshot qualified as Snapshot
import System.Exit (exitFailure)

main :: IO ()
main = do
  let failures = [label | (label, passed) <- Gameplay.checks ++ Snapshot.checks ++ Protocol.checks, not passed]
  unless (null failures) $ do
    mapM_ (putStrLn . ("FAIL " ++)) failures
    exitFailure
  putStrLn "river-laws: PASS (journey, save, Step/Arena, boundaries, tick/clock, mutation)"
