module Main (main) where

import Control.Monad (unless)
import Data.Set qualified as S
import Game.Arena
import Paper.Game

check :: String -> Bool -> IO ()
check name condition = unless condition (error name)

main :: IO ()
main = do
  check "initial" (phase initial == Playing && movesLeft initial == 18)
  check "cell range" (all ((== Nothing) . cell) [-1, 16, 18446744073709551616])
  check "initial undo refused" (step Undo initial == (initial, [Refused]))

  -- This exact first turn is the README's reading example.
  let (moved, firstOutcome) = step (rotate 0) initial
      rewound = fst (step Undo moved)
      movedAfterUndo = applyRotation rewound 0
      restarted = fst (step Restart rewound)
  check
    "first rotation is clockwise"
    ( lookupTile 0 moved == Just (Straight, 2)
        && movesLeft moved == 17
        && firstOutcome == [Turned (requiredCell 0)]
    )
  check "undo restores visible board and budget" (samePosition rewound initial)
  check
    "undo once"
    (not (canUndo rewound) && step Undo movedAfterUndo == (movedAfterUndo, [Refused]))
  check "restart replenishes undo" (canUndo (applyRotation restarted 0))
  let movedTwice = applyRotation moved 2
  check "latest position is restored" (samePosition (fst (step Undo movedTwice)) moved)

  -- The sixth command is refused: the fifth already waters both gardens.
  let winner = foldl applyRotation initial [0, 2, 2, 11, 11, 15]
      beforeWin = foldl applyRotation initial [0, 2, 2, 11]
      reopenedWin = fst (step Undo winner)
  check
    "constructive solution"
    (phase winner == Won && all (`S.member` wetCells winner) goals)
  check "won refuses rotate" (step (rotate 0) winner == (winner, [Refused]))
  check
    "undo reopens win"
    (phase reopenedWin == Playing && samePosition reopenedWin beforeWin)
  check "undo win is spent" (not (canUndo reopenedWin))
  check "reset" (fst (step Restart winner) == initial)

  -- Thirteen harmless rotations leave exactly the five moves needed to win.
  let lastMoveWin = foldl applyRotation initial (replicate 13 4 ++ [0, 2, 2, 11, 11])
  check
    "win takes precedence over empty budget"
    (phase lastMoveWin == Won && movesLeft lastMoveWin == 0)

  let states = scanl applyRotation initial (replicate 18 4)
      beforeLoss = states !! 17
      lost = last states
      reopenedLoss = fst (step Undo lost)
      refusedLoss = fst (step (rotate 4) lost)
  check
    "finite budget"
    (all ((>= 0) . movesLeft) states && phase lost == OutOfMoves)
  check "no postloss change" (refusedLoss == lost)
  check
    "undo reopens loss"
    ( samePosition reopenedLoss beforeLoss
        && movesLeft reopenedLoss == 1
        && phase reopenedLoss == Playing
    )
  check
    "refused rotation preserves undo history"
    (step Undo refusedLoss == step Undo lost)
  check "restart restores whole state" (fst (step Restart reopenedLoss) == initial)

  mapM_ checkArena [(world, number) | world <- states, number <- [0 .. 15]]
  putStrLn "Paper Circuit: transition/history/terminal regressions and 304 Arena comparisons PASS"

-- Test fixtures deliberately fail if their addresses are invalid.
requiredCell :: Integer -> Cell
requiredCell number = case cell number of
  Just location -> location
  Nothing -> error "test fixture is outside the board"

rotate :: Integer -> Command
rotate = Rotate . requiredCell

applyRotation :: World -> Integer -> World
applyRotation world number = fst (step (rotate number) world)

samePosition :: World -> World -> Bool
samePosition first second =
  tiles first == tiles second && movesLeft first == movesLeft second

lookupTile :: Int -> World -> Maybe (Piece, Int)
lookupTile number world =
  lookup
    number
    [(cellNumber location, (piece, rotation)) | (location, piece, rotation) <- tiles world]

checkArena :: (World, Integer) -> IO ()
checkArena (world, number) =
  check
    "Arena original boundary"
    ( play Circuit () (singleton Gardener (rotate number)) world
        == Right (step (rotate number) world)
    )
