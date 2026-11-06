module Main (main) where

import Control.Monad (unless)
import PureFall.Core
import PureFall.Host.Save
import PureFall.Session
import PureFall.Time
import PureFall.View
import System.Exit (die)

main :: IO ()
main = do
  let normal = fst (advanceFrame (frameMicros 5000) [Clockwise] (Held Rightward False) True (start (fresh Practice 90210)))
  restoredNormal <- roundTrip normal 0 [] (frameMicros 0)
  check "normal session preserves pending edges, held state and fractional tick" (restoredSession restoredNormal == normal)
  check "normal immediate RenderModel restored" (renderModel 0 (sessionGame normal) == renderModel 0 (sessionGame (restoredSession restoredNormal)))
  let study = fst (advanceFrame (frameMicros 0) [Study] (Held Neutral False) True (start (fixture Cavity)))
      count = length (reachable (sessionGame study))
      index = count - 1
  selected <- roundTrip study (-1) [] (frameMicros 19000)
  check "selected study index normalized and restored" (restoredStudyIndex selected == index)
  check "selected study immediate RenderModel restored" (renderModel index (sessionGame study) == renderModel (restoredStudyIndex selected) (sessionGame (restoredSession selected)))
  check "idle path debt normalized to zero" (restoredMoveDebt selected == frameMicros 0)
  entry <- case studySelect index (sessionGame study) of
    Nothing -> die "Cavity has no study landing"
    Just value -> pure value
  let commands = landingPath entry ++ [HardDrop]
      split = min 3 (length commands - 1)
      (inFlight, _) = runMoves study (take split commands)
      remaining = drop split commands
      debt = frameMicros 47000
  flight <- roundTrip inFlight index remaining debt
  check "in-flight remaining moves restored" (restoredMoves flight == remaining)
  check "in-flight microseconds restored" (restoredMoveDebt flight == debt)
  check "in-flight semantic session and immediate effects restored" (restoredSession flight == inFlight && sessionCues (restoredSession flight) == sessionCues inFlight)
  let expected = runMoves inFlight remaining
      actual = runMoves (restoredSession flight) (restoredMoves flight)
  check "restored continuation has identical session and ordered effects" (actual == expected)
  check "restored continuation locks exactly one piece" (piecesLocked (sessionGame (fst actual)) == piecesLocked (sessionGame inFlight) + 1)
  check "invalid host syntax rejected" (isRejected (restoreHostCheckpoint "broken"))
  check "host version rejected" (restoreHostCheckpoint (rawEnvelope 99 normal 0 [] 0) == Left HostSaveVersion)
  check "corrupt semantic session rejected" (isRejected (restoreHostCheckpoint "HostEnvelope 1 \"broken\" 0 [] 0"))
  check "negative study index rejected" (restoreHostCheckpoint (rawEnvelope 1 study (-1) [] 0) == Left HostStudyIndex)
  check "out-of-range study index rejected" (restoreHostCheckpoint (rawEnvelope 1 study count [] 0) == Left HostStudyIndex)
  check "non-study selection rejected" (restoreHostCheckpoint (rawEnvelope 1 normal 1 [] 0) == Left HostStudyIndex)
  check "negative path debt rejected" (restoreHostCheckpoint (rawEnvelope 1 study 0 remaining (-1)) == Left HostMoveDebt)
  check "whole-step path debt rejected" (restoreHostCheckpoint (rawEnvelope 1 study 0 remaining (frameMicroCount pathStepMicros)) == Left HostMoveDebt)
  check "idle path debt rejected" (restoreHostCheckpoint (rawEnvelope 1 study 0 [] 1) == Left HostMoveDebt)
  check "in-flight path outside frozen study rejected" (restoreHostCheckpoint (rawEnvelope 1 normal 0 [HardDrop] 0) == Left HostMovePhase)
  check "path without final drop rejected" (isRejected (restoreHostCheckpoint (rawEnvelope 1 study 0 [MoveLeft] 0)))
  check "multiple drops rejected" (isRejected (restoreHostCheckpoint (rawEnvelope 1 study 0 [HardDrop, HardDrop] 0)))
  check "pause injected into remaining path rejected" (isRejected (restoreHostCheckpoint (rawEnvelope 1 study 0 [Pause, HardDrop] 0)))
  check "hold injected into remaining path rejected" (isRejected (restoreHostCheckpoint (rawEnvelope 1 study 0 [SwapHold, HardDrop] 0)))
  check "contradictory blocked movement rejected by production transition" (isRejected (restoreHostCheckpoint (rawEnvelope 1 study 0 (replicate 12 MoveLeft ++ [HardDrop]) 0)))
  let replaySource = fst (advanceFrame (frameMicros 16667) [] (Held Neutral False) True normal)
  check "active run replay excluded from host saves" (isRejected (hostCheckpoint (restartReplay replaySource) 0 [] (frameMicros 0)))
  let tooManyPending = fst (advanceFrame (frameMicros 0) (replicate 1025 Clockwise) (Held Neutral False) True (start (fresh Practice 12)))
  check "encoder refuses a session beyond the supported pending-input limit" (isRejected (hostCheckpoint tooManyPending 0 [] (frameMicros 0)))
  putStrLn "native-host-check: 27 save boundary checks passed"

check :: String -> Bool -> IO ()
check name passed = unless passed (die ("FAILED: " ++ name))

roundTrip :: Session -> Int -> [Command] -> FrameMicros -> IO RestoredHost
roundTrip session selected remaining debt = case hostCheckpoint session selected remaining debt >>= restoreHostCheckpoint of
  Left issue -> die ("Save round trip failed: " ++ show issue)
  Right restored -> pure restored

runMoves :: Session -> [Command] -> (Session, [Cue])
runMoves session = foldl' apply (session, [])
  where
    apply (current, cues) command = let (next, more) = tickSession (TickInput [command] (Held Neutral False)) current in (next, cues ++ more)

rawEnvelope :: Int -> Session -> Int -> [Command] -> Integer -> String
rawEnvelope version session index remaining debt = "HostEnvelope " ++ show version ++ " " ++ show (sessionCheckpoint session) ++ " " ++ show index ++ " " ++ show remaining ++ " " ++ show debt

isRejected :: Either a b -> Bool
isRejected result = case result of Left _ -> True; Right _ -> False
