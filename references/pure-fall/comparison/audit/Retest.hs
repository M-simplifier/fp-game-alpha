module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import PureFall.Core
import PureFall.Session
import PureFall.Time
import System.Exit (exitFailure)
import Text.Read (readMaybe)

data SavedSession = SavedSession Int String Integer [Command] Held [(String,Int)] [TickInput] [Cue] String [TickInput] Bool (String,Int)
  deriving (Show,Read)

neutral :: Held
neutral = Held Neutral False

one :: [Command] -> TickInput
one commands = TickInput commands neutral

check :: String -> Bool -> IO ()
check name passed = do
  putStrLn ((if passed then "PASS " else "FAIL ") ++ name)
  unless passed exitFailure

main :: IO ()
main = do
  let initial = fresh Practice 15
      started = start initial
      expectedLeft = active initial >>= shifted (gameBoard initial) (-1) 0
      (pressed,_) = advanceFrame (frameMicros 5000) [MoveLeft] (Held Leftward False) True started
      (released,cues) = advanceFrame (frameMicros 11667) [] neutral True pressed
      (both,_) = admittedStep (TickInput [MoveLeft] (Held Leftward False)) initial
  check "native edge protocol preserves sub-tick LEFT tap exactly once"
    (pendingEdges pressed == [MoveLeft] && active (sessionGame released) == expectedLeft && cues == [Moved] && tickCount (ticks (sessionGame released)) == 1)
  check "matching LEFT edge plus held direction avoids double movement" (active both == expectedLeft)
  let (batched,_) = advanceFrame (frameMicros 50000) [MoveLeft] (Held Leftward False) True started
      (split,_) = advanceFrame (frameMicros 45000) [] (Held Leftward False) True pressed
  check "constant-held catch-up is invariant under zero-tick frame partition" (sessionGame batched == sessionGame split && debtUnits batched == debtUnits split)
  let heldLeft = Held Leftward False
      (firstTick,_) = advanceFrame (frameMicros 16667) [MoveLeft] heldLeft True started
      (almostDue,_) = advanceFrame (frameMicros 133333) [] heldLeft True firstTick
      (shortRelease,_) = advanceFrame (frameMicros 5000) [] neutral True almostDue
      (freshPress,freshCues) = advanceFrame (frameMicros 11667) [MoveLeft] heldLeft True shortRelease
      expectedFreshPress = active (sessionGame almostDue) >>= shifted (gameBoard (sessionGame almostDue)) (-1) 0
  check "sub-tick release/repress restarts DAS and moves exactly once"
    (active (sessionGame freshPress) == expectedFreshPress && freshCues == [Moved])
  let usedHold = fst (admittedStep (one [SwapHold]) initial)
      (afterFailedHold,_) = admittedStep (one [SwapHold,HardDrop]) usedHold
  check "failed hold leaves following hard drop available" (piecesLocked afterFailedHold == 1)
  let (dropped,_) = tickSession (one [HardDrop]) started
      (midpiece,_) = tickSession (one [MoveLeft]) dropped
  check "current mid-piece cannot masquerade as rewind checkpoint" (isLeft (restoreSession (forgeHistory midpiece)))
  check "impossible win and duplicate-row clear cues rejected" (isLeft (restoreSession (forgeCues started)))
  let (rejected,_) = tickSession (one (replicate 33 HardDrop)) started
  check "admission-rejected input preserves game and an encodable session"
    (sessionGame rejected == initial && null (traceInputs rejected) && restoreSession (sessionCheckpoint rejected) == Right rejected)
  let (twice,_) = tickSession (one [HardDrop]) midpiece
      rewound = rewindPiece twice
      (branch,_) = tickSession (one [MoveRight]) rewound
  check "rebuilt rewind goes to previous piece spawn and branch remains restorable"
    (sessionGame rewound == sessionGame dropped && restoreSession (sessionCheckpoint branch) == Right branch)
  check "replay of a new branch excludes discarded suffix" (sessionGame (playReplay (restartReplay branch)) == sessionGame branch)

playReplay :: Session -> Session
playReplay session = if replayAvailable session then playReplay (fst (replayNext session)) else session

forgeHistory :: Session -> String
forgeHistory session = case readMaybe (sessionCheckpoint session) of
  Just (SavedSession version saved debt pending held _ trace cues initial replay focused piece) ->
    show (SavedSession version saved debt pending held [(saved,length trace)] trace cues initial replay focused piece)
  Nothing -> "FAILED TO PARSE"

forgeCues :: Session -> String
forgeCues session = case readMaybe (sessionCheckpoint session) of
  Just (SavedSession version saved debt pending held history trace _ initial replay focused piece) ->
    show (SavedSession version saved debt pending held history trace [Finished Won,Cleared (Clear [23,23] NoSpin 12345 True True)] initial replay focused piece)
  Nothing -> "FAILED TO PARSE"
