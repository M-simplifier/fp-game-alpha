module Main where

import Control.Monad (unless)
import Data.List qualified as List
import Game.Arena hiding (view)
import Game.Transition
import Signal.Game
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True ".build"
  let observations = trace (machine Courier) winningTrace initial
      (winner, events) = replay (machine Courier) winningTrace initial
  print (view winner, events)
  unless (status (view winner) == Complete) (error "Winning witness failed")
  unless (all (invariant . after) observations) (error "Witness invariant")
  let commands = [Tick d j | d <- [Still, West, East], j <- [False, True]] ++ [Retry, Restart]
      walk n s = if n == 0 then invariant s else all (\c -> let (next, _) = advance c s in invariant next && walk (n - 1) next) commands
  unless (walk (6 :: Int) initial) (error "Bounded exhaustive transitions")
  let (_, first) = replay (machine Courier) (take 100 winningTrace) initial
      (middle, _) = replay (machine Courier) (take 100 winningTrace) initial
      (lastState, lastEvents) = replay (machine Courier) (drop 100 winningTrace) middle
  unless ((lastState, first ++ lastEvents) == (winner, events)) (error "Replay composition")
  unless (play Courier () (singleton Rider Restart) winner == Right (initial, [])) (error "Arena reset")
  let waiting = List.foldl' (\s _ -> fst (advance (Tick Still False) s)) initial [1 .. 11000 :: Int]
  unless (status (view waiting) == Exhausted && elapsedTicks (view waiting) == 10800) (error "Session bound")
  unless (fst (advance Restart waiting) == initial) (error "Restart bound")
  let falling = List.foldl' (\s _ -> fst (advance (Tick East False) s)) initial [1 .. 100 :: Int]
  unless (fallCount (view falling) > 0) (error "Canal retry")
  unless (all ((== Nothing) . decodeCommand) [-1, 8, 10000]) (error "Input rejection")
  let checkpointRun = trace (machine Courier) (replicate 37 (Tick East False) ++ [Tick East True] ++ replicate 220 (Tick East False)) initial
      recovered = [view (after frame) | frame <- checkpointRun, Fell `elem` emitted frame, parcelsDelivered (view (before frame)) == 1]
  unless (any (\v -> courierX v == 540 && parcelsDelivered v == 1) recovered) (error "Delivery checkpoint recovery")
  unless (all (\c -> fst (advance c winner) == winner) (take 7 commands)) (error "Win is terminal except restart")
  let (deadlineWinner, _) = replay (machine Courier) (replicate 10378 (Tick Still False) ++ take 422 winningTrace) initial
  unless (status (view deadlineWinner) == Complete && elapsedTicks (view deadlineWinner) == 10800) (error "Last playable tick win precedence")
  unless (fst (advance (Tick East True) waiting) == waiting) (error "Past deadline changed state")
  let rooftop = concat [[Tick East True], replicate 27 (Tick East False), [Tick Still True], replicate 30 (Tick Still False), replicate 20 (Tick East False), [Tick East True], replicate 12 (Tick East False), replicate 30 (Tick Still False)]
      scenicTrace = replicate 37 (Tick East False) ++ rooftop ++ replicate 89 (Tick East False) ++ rooftop ++ replicate 89 (Tick East False) ++ rooftop ++ replicate 24 (Tick East False)
      (scenic, _) = replay (machine Courier) scenicTrace initial
  print (view scenic)
  unless (status (view scenic) == Complete && collectedStamps (view scenic) == [0, 1, 2] && fallCount (view scenic) == 0) (error "All optional routes reachable")
  writeFile ".build/scenic-witness.txt" (unlines (map show scenicTrace))
  writeFile ".build/witness.txt" (unlines (map show winningTrace))
  putStrLn "PASS native: constructive win, invariant tree depth 6, replay split, arena/reset, timeout, falls, invalid input"
