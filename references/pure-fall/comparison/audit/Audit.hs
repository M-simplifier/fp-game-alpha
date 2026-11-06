module Main (main) where

import Data.Either (isLeft)
import PureFall.Core
import PureFall.Session
import PureFall.Time
import Text.Read (readMaybe)

-- This is an independent representation of the serialized grammar, not an
-- import of Session's private representation. Mutations exercise its decoder.
data SavedSession = SavedSession Int String Integer [Command] Held [(String,Int)] [TickInput] [Cue] String [TickInput] Bool (String,Int)
  deriving (Show,Read)

neutral :: Held
neutral = Held Neutral False

one :: [Command] -> TickInput
one commands = TickInput commands neutral

main :: IO ()
main = do
  let initial = fresh Practice 15
      started = start initial
      (pressed,_) = advanceFrame (frameMicros 5000) [] (Held Leftward False) True started
      (released,_) = advanceFrame (frameMicros 11667) [] neutral True pressed
      expectedLeft = active initial >>= shifted (gameBoard initial) (-1) 0
  putStrLn "A: host-style LEFT press and release across two sub-tick frames"
  print ("initial", active initial, "expected at first tick", expectedLeft)
  print ("actual",active (sessionGame released),"ticks",tickCount (ticks (sessionGame released)),"retained press",pendingEdges pressed)
  let (both,_) = admittedStep (TickInput [MoveLeft] (Held Leftward False)) initial
  print ("edge+held simultaneously", active both)
  let (dropped,_) = tickSession (one [HardDrop]) started
      (midpiece,_) = tickSession (one [MoveLeft]) dropped
      fabricatedCurrentHistory = forgeHistory midpiece
  putStrLn "B: syntactically valid history replaces the previous piece checkpoint with current mid-piece"
  case restoreSession fabricatedCurrentHistory of
    Left issue -> print ("rejected",issue)
    Right accepted -> do
      print ("accepted",sessionGame accepted==sessionGame midpiece)
      print ("rewind unchanged",sessionGame (rewindPiece accepted)==sessionGame accepted)
      print ("actual expected normal rewind",piecesLocked (sessionGame (rewindPiece midpiece)),active (sessionGame (rewindPiece midpiece)))
  putStrLn "C: fresh session claims a nonexistent finished+clear cue"
  print (restoreSession (forgeCues started))
  putStrLn "D: rejected admission does not preserve Session codec closure"
  let (rejected,_) = tickSession (one (replicate 33 HardDrop)) started
  print ("game preserved",sessionGame rejected==initial,"save rejected",isLeft (restoreSession (sessionCheckpoint rejected)))
  putStrLn "E: failed hold consumes a later command"
  let usedHold = fst (admittedStep (one [SwapHold]) initial)
      (dropAfterFailedHold,_) = admittedStep (one [SwapHold,HardDrop]) usedHold
      (dropAlone,_) = admittedStep (one [HardDrop]) usedHold
  print ("drop after failed hold",piecesLocked dropAfterFailedHold,"drop alone",piecesLocked dropAlone)

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
