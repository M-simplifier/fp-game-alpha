-- Original is generated from the pinned Git baseline by compare-baseline.sh.
module Main (main) where

import Control.Monad (unless)
import Data.Set qualified as S
import Original qualified as O
import Paper.Game qualified as N

type VisiblePosition = (String, [Int], Int, String, Bool)

oldCommand :: Integer -> O.Command
oldCommand number
  | number == 16 = O.Undo
  | number == 17 = O.Restart
  | otherwise = maybe O.Restart O.Rotate (O.cell number)

newCommand :: Integer -> N.Command
newCommand number
  | number == 16 = N.Undo
  | number == 17 = N.Restart
  | otherwise = maybe N.Restart N.Rotate (N.cell number)

oldView :: O.World -> VisiblePosition
oldView world =
  ( show (O.tiles world),
    map O.cellNumber (S.toList (O.wetCells world)),
    O.movesLeft world,
    show (O.phase world),
    O.canUndo world
  )

newView :: N.World -> VisiblePosition
newView world =
  ( show (N.tiles world),
    map N.cellNumber (S.toList (N.wetCells world)),
    N.movesLeft world,
    show (N.phase world),
    N.canUndo world
  )

compareTrace :: [Integer] -> IO ()
compareTrace = go O.initial N.initial
  where
    go old new [] = unless (oldView old == newView new) (error "final mismatch")
    go old new (command : remaining) = do
      let (oldNext, oldEvents) = O.step (oldCommand command) old
          (newNext, newEvents) = N.step (newCommand command) new
      unless
        (oldView old == newView new && show oldEvents == show newEvents)
        (error ("transition mismatch before command " ++ show command))
      go oldNext newNext remaining

main :: IO ()
main = do
  let shortTraces = sequence (replicate 4 [0 .. 17])
      nextSeed seed = (1103515245 * seed + 12345) `mod` 2147483648
      longTraces =
        [take 120 (map (`mod` 18) (tail (iterate nextSeed seed))) | seed <- [1 .. 200]]
  mapM_ compareTrace (shortTraces ++ longTraces)
  putStrLn "PASS: old/new observations and outcomes on 104976 exhaustive four-command traces and 200 deterministic 120-command traces"
