{-# LANGUAGE BangPatterns #-}

module Main where

import Colony.Types
import Colony.World
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List (sort)
import RedDune.Campaign
import RedDune.Game
import RedDune.GameSave
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import Text.Read (readMaybe)

must :: Either String a -> IO a
must = either (ioError . userError) pure

main :: IO ()
main = do
  args <- getArgs
  (path, count) <- case args of [file, n] | Just amount <- (readMaybe n :: Maybe Int), amount >= 100 && amount <= 12000 -> pure (file, amount); _ -> ioError (userError "Usage: red-dune-tick-bench ACTIVE-LIVE.save 100..12000")
  original <- BS.readFile path >>= must . decodeGame
  unless (worldMode (gameWorld original) == Active && campaignEnding (gameCampaign original) == Ongoing) (ioError (userError "Benchmark needs an active, nonterminal checkpoint"))
  (final, samples) <- loop count original []
  let sorted = sort samples
      percentile n = sorted !! min (length sorted - 1) (length sorted * n `div` 100)
      SimTick first = simTick (gameWorld original)
      SimTick lastTick = simTick (gameWorld final)
  unless (lastTick - first == fromIntegral count) (ioError (userError "Campaign ended before full sample; choose an earlier cut"))
  putStrLn ("forcedTicks=" ++ show count ++ " CPU ms mean=" ++ show (sum samples / fromIntegral count) ++ " p50=" ++ show (percentile 50) ++ " p95=" ++ show (percentile 95) ++ " p99=" ++ show (percentile 99) ++ " max=" ++ show (maximum samples) ++ " above50ms=" ++ show (length (filter (> 50) samples)))
  where
    loop 0 !game values = pure (game, values)
    loop n !game values = do
      start <- getCPUTime
      next <- must (advanceGame 1 game) >>= evaluate . force
      end <- getCPUTime
      loop (n - 1) next ((fromIntegral (end - start) / 1e9 :: Double) : values)
