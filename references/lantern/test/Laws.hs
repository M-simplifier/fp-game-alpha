module Main (main) where

import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty (..))
import Game.Arena (Attempt (..), attempt, play, singleton)
import Game.Arena.Finite (Controller (..), Node (..), finiteArena, forceReach, states)
import Game.Transition (machine, replay)
import Lantern
import System.Exit (exitFailure)

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

main :: IO ()
main = do
  board <- case mkBoard [Cart V 2 2] [1] [2] of
    Left problem -> print problem >> exitFailure
    Right valid -> pure valid
  check "count validation" (mkBoard [Cart V 2 2] [] [2] == Left CartPositionCountMismatch)
  check "fish-row validation" (mkBoard [Cart V 2 2] [1] [6] == Left InvalidFishRows)
  check "fish begins occupied" (mkBoard [Cart V 2 2] [1] [5] == Left InitiallyClearFishRow)
  check "largest Int coordinate cannot wrap into board" $
    mkBoard [Cart H 2 2] [maxBound :: Int] [2] == Left (InvalidCart 0)
  check "smallest Int coordinate is invalid" $
    mkBoard [Cart H 2 2] [minBound :: Int] [2] == Left (InvalidCart 0)
  check "invalid size is rejected before width subtraction" $
    mkBoard [Cart H 2 maxBound] [0] [2] == Left (InvalidCart 0)
  other <- case mkBoard [Cart H 2 2] [1] [2] of
    Left problem -> print problem >> exitFailure
    Right valid -> pure valid
  let start = initial board
      win = Move 0 (-1)
      (finished, departure) = advance board win start
      witness = Lantern board
      foreignWorld = initial other
  check "state from a different board is rejected" $
    not (wellFormed board foreignWorld)
      && not (legal board foreignWorld win)
      && advance board win foreignWorld == (foreignWorld, mempty)
      && null (successors board foreignWorld)
  check "Arena rejects foreign state before indexing" $
    attempt witness () (singleton () win) foreignWorld
      == Rejected "This trolley cannot move that way." foreignWorld
  check "state stays well formed" (wellFormed board start && wellFormed board finished)
  check "one fish departs" (remaining finished == 0 && departure == Departed [2])
  check "post-win stability" (advance board win finished == (finished, mempty))
  check "bad index does not crash" (advance board (Move (-1) 1) start == (start, mempty))
  check "all invalid indices and distances preserve the entire state" $
    all
      (\move -> not (legal board start move) && advance board move start == (start, mempty))
      [Move minBound 1, Move maxBound (-1), Move 1 1, Move 0 0, Move 0 minBound, Move 0 maxBound]
  blocked <- case mkBoard [Cart V 2 2, Cart H 0 2] [1, 2] [2] of
    Left problem -> print problem >> exitFailure
    Right valid -> pure valid
  check "collision refusal retains both carts and the fish mask" $
    let blockedStart = initial blocked
     in advance blocked (Move 0 (-1)) blockedStart == (blockedStart, mempty)
          && not (legal blocked blockedStart (Move 0 (-1)))
  twoFish <- case mkBoard [Cart V 2 2] [1] [2, 1] of
    Left problem -> print problem >> exitFailure
    Right valid -> pure valid
  let (firstDeparture, firstRows) = advance twoFish (Move 0 (-1)) (initial twoFish)
      (returned, returnedRows) = advance twoFish (Move 0 1) firstDeparture
      (bothGone, lastRows) = advance twoFish (Move 0 1) returned
  check "departures keep fish identities across a return move" $
    remaining firstDeparture == 2
      && firstRows == Departed [2]
      && returnedRows == mempty
      && remaining returned == 2
      && lastRows == Departed [1]
      && remaining bothGone == 0
      && positions bothGone == [2]
  check "board failures keep their established priority" $
    mkBoard [Cart H 0 99] [] [] == Left CartPositionCountMismatch
      && mkBoard [Cart H 0 99] [0] [] == Left (InvalidCart 0)
      && mkBoard [Cart H 0 2, Cart V 0 2] [0, 0] [] == Left InvalidFishRows
      && mkBoard [Cart H 0 2, Cart V 0 2] [0, 0] [5] == Left InitialCollision
  check "Arena executes the original rule" (play witness () (singleton () win) start == Right (finished, departure))
  check "invalid move is rejected before rule" $
    attempt witness () (singleton () (Move 0 99)) start
      == Rejected "This trolley cannot move that way." start
  check "Machine and explicit Step agree" (replay (machine witness) [win] start == (finished, departure))
  let below = fst (advance board (Move 0 1) start)
      bottom = fst (advance board (Move 0 1) below)
      reachable = [start, finished, below, bottom]
      edges world = [(move, next) | (move, next, _) <- successors board world]
      node world = case edges world of
        [] -> Halted
        first : rest -> Choice (Participant ()) (first :| rest)
  graph <- case finiteArena [(world, node world) | world <- reachable] of
    Left problem -> print problem >> exitFailure
    Right closed -> pure closed
  check "finite graph is closed" (length (states graph) == 4)
  let terminal = filter ((== 0) . remaining) reachable
  check "controller can force a clear row" (forceReach [()] terminal graph == states graph)
  putStrLn "lantern-laws: PASS (validated board, original Step/Arena, finite reachability)"
