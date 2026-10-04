-- | Game vocabulary, checked restoration and read-only public projections.
module Game.Model
  ( World,
    Position,
    Direction (..),
    Command (..),
    Event (..),
    initial,
    position,
    coordinates,
    turnCount,
    isWon,
    worldWidth,
    worldHeight,
    exitCell,
    restoreWorld,
    invariantErrors,
    InvariantViolation (..),
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Game.Model.Internal

data Direction = North | South | East | West deriving (Eq, Show)

data Command = Move Direction | UseExit deriving (Eq, Show)

data Event = Moved Position | HitWall | ExitUnavailable | Won | AlreadyFinished deriving (Eq, Show)

data InvariantViolation
  = PositionOutsideBoard (Int, Int)
  | NegativeTurn Integer
  | FinishedAwayFromExit
  deriving (Eq, Show)

worldWidth, worldHeight :: Int
worldWidth = 3
worldHeight = 2

exitCell :: (Int, Int)
exitCell = (2, 1)

initial :: World
initial = World (Position (Column 0) (Row 0)) (Turn 0) Exploring

position :: World -> Position
position = worldPosition

coordinates :: Position -> (Int, Int)
coordinates (Position (Column column) (Row row)) = (column, row)

turnCount :: World -> Integer
turnCount world = case worldTurn world of Turn turns -> turns

isWon :: World -> Bool
isWon world = worldProgress world == Escaped

-- | Validate every untrusted persisted field before admitting it as a World.
restoreWorld :: Int -> Int -> Integer -> Bool -> Either (NonEmpty InvariantViolation) World
restoreWorld column row turns won =
  let progress = if won then Escaped else Exploring
      world = World (Position (Column column) (Row row)) (Turn turns) progress
   in case invariantErrors world of
        [] -> Right world
        first : rest -> Left (first :| rest)

invariantErrors :: World -> [InvariantViolation]
invariantErrors world =
  let (column, row) = coordinates (position world)
   in [PositionOutsideBoard (column, row) | column < 0 || column >= worldWidth || row < 0 || row >= worldHeight]
        ++ [NegativeTurn (turnCount world) | turnCount world < 0]
        ++ [FinishedAwayFromExit | isWon world && (column, row) /= exitCell]
