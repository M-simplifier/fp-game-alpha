{-# LANGUAGE BangPatterns #-}

module Main where

import Colony.Needs
import Colony.Presentation (encodeJSON, obj, str)
import Colony.Transport
import Colony.World
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.GameSave
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import System.IO (hFlush, stdout)

must :: Either String a -> IO a
must = either (ioError . userError) pure

act :: [(String, String)] -> GameState -> IO GameState
act fields game = fst <$> must (applyAction (obj [(k, str v) | (k, v) <- fields]) game)

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError label))

main :: IO ()
main = do
  args <- getArgs
  let scenario = case args of s : _ -> s; _ -> "settlement"
  initial <- must (startGame scenario defaultPack)
  bytes <- must (encodeGame initial)
  restored <- must (decodeGame bytes)
  check "initial save exact" (restored == initial)
  check "corrupt save rejected" (case decodeGame (BS.init bytes <> BS.singleton 0) of Left _ -> True; _ -> False)
  staffed <- act [("op", "configure"), ("preset", "survival")] initial
  expanding <- act [("op", "expand"), ("prototype", "warehouse")] staffed
  running <- act [("op", "resume")] expanding
  start <- getCPUTime
  final <- loop (0 :: Int) running
  end <- getCPUTime
  check "campaign reaches authored ending" (campaignEnding (gameCampaign final) == SettlementSecured)
  output <- must (encodeGame final)
  BS.writeFile ("/tmp/red-dune-" ++ scenario ++ "-final.save") output
  putStrLn ("PASS " ++ scenario ++ " forced CPU seconds=" ++ show (fromIntegral (end - start) / 1e12 :: Double) ++ " saveBytes=" ++ show (BS.length output))
  where
    loop !hours !game
      | campaignEnding (gameCampaign game) /= Ongoing = pure game
      | hours >= 144 = do putStrLn (encodeJSON (observeGame game)); ioError (userError "campaign stalled after 144 hours")
      | otherwise = do
          next <- must (advanceGame 1200 game) >>= evaluate . force
          let w = gameWorld next; people = M.elems (needsResidents (worldNeeds w)); transport = worldTransport w
          putStrLn ("hour=" ++ show (hours + 1) ++ " health=" ++ show (minimum (map residentHealth people)) ++ " jobs=" ++ show (M.size (worldJobs w)) ++ " requests=" ++ show (M.size (transportRequests transport)) ++ " receipts=" ++ show (length (worldReceipts w)) ++ " campaign=" ++ show (gameCampaign next))
          hFlush stdout
          -- Checkpoint cuts include active production, transport, construction,
          -- breakdown and stability; both suffixes use the same public transition.
          if hours `elem` [0, 2, 5, 23, 35, 50, 64]
            then do
              saved <- must (encodeGame next)
              BS.writeFile ("/tmp/red-dune-" ++ scenarioId (campaignScenario (gameCampaign next)) ++ "-cut-" ++ show (hours + 1) ++ ".save") saved
              loaded <- must (decodeGame saved)
              a <- must (advanceGame 1200 next)
              b <- must (advanceGame 1200 loaded)
              check ("saved suffix equality hour " ++ show hours) (a == b)
              check "read-only observation" (observeGame loaded == observeGame next)
            else pure ()
          loop (hours + 1) next
