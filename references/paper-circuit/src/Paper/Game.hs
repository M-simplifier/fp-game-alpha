{-# LANGUAGE TypeFamilies #-}

module Paper.Game
  ( Cell,
    cell,
    cellNumber,
    Direction (..),
    Piece (..),
    Command (..),
    Outcome (..),
    Phase (..),
    World,
    initial,
    Level,
    LevelError (..),
    level,
    defaultLevel,
    initialWith,
    movesLeft,
    phase,
    tiles,
    wetCells,
    goals,
    ports,
    canUndo,
    step,
    Circuit (..),
    Player (..),
    Scene (..),
  )
where

import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Game.Arena
import Game.Transition

-- The constructor stays private: callers must validate a board position with cell.
newtype Cell = Cell Int deriving (Eq, Ord, Show)

cell :: Integer -> Maybe Cell
cell number
  | number >= 0 && number < 16 = Just (Cell (fromInteger number))
  | otherwise = Nothing

cellNumber :: Cell -> Int
cellNumber (Cell number) = number

data Direction = North | East | South | West deriving (Eq, Ord, Show, Enum, Bounded)

data Piece = Straight | Elbow deriving (Eq, Show)

data Command = Rotate Cell | Restart | Undo deriving (Eq, Show)

data Outcome = Turned Cell | Restarted | Undone | Refused deriving (Eq, Show)

data Phase = Playing | Won | OutOfMoves deriving (Eq, Show)

-- A rotation counts clockwise quarter-turns; stored rotations are always 0..3.
-- This alias documents the role without changing the public Int-based API.
type Rotation = Int

type Grid = M.Map Cell (Piece, Rotation)

data Position = Position
  { positionGrid :: Grid,
    positionMoves :: Int
  }
  deriving (Eq, Show)

data UndoUse = Available | Spent deriving (Eq, Show)

-- None of these record selectors are exported. Only step can change a World.
-- History stores one position, not another World, so undo cannot restore its use.
data World = World
  { sessionLevel :: Level,
    currentPosition :: Position,
    previousPosition :: Maybe Position,
    undoUse :: UndoUse
  }
  deriving (Eq, Show)

-- This bounded level family changes the budget and inlet scramble only.
-- Keep the constructor private: every non-default level has a checked witness.
data Level = Level Int Int deriving (Eq, Show)

data LevelError = BudgetRange | RotationRange | WitnessFailed deriving (Eq, Show)

defaultLevel :: Level
defaultLevel = Level 18 1

level :: Integer -> Integer -> Either LevelError Level
level budget inletRotation
  | budget < 1 || budget > 100 = Left BudgetRange
  | inletRotation < 0 || inletRotation > 3 = Left RotationRange
  | phase solved /= Won = Left WitnessFailed
  | otherwise = Right candidate
  where
    -- Bounds above are checked before either conversion is demanded.
    candidate = Level (fromInteger budget) (fromInteger inletRotation)
    witness = replicate (fromInteger ((2 - inletRotation) `mod` 4)) (Cell 0) ++ map Cell [2, 2, 11, 11]
    solved = foldl (\world location -> fst (step (Rotate location) world)) (initialWith candidate) witness

initial :: World
initial = initialWith defaultLevel

-- A designed route is scrambled; decoys are not part of the witness solution.
initialWith :: Level -> World
initialWith config@(Level budget inletRotation) =
  World
    { sessionLevel = config,
      currentPosition = Position startingGrid budget,
      previousPosition = Nothing,
      undoUse = Available
    }
  where
    startingGrid = M.fromList [(Cell number, (kind number, spin number)) | number <- [0 .. 15]]
    kind number
      | number `elem` [2, 10, 11, 15] = Elbow
      | otherwise = Straight
    spin number = M.findWithDefault 1 number startingRotations
    startingRotations = M.fromList [(0, inletRotation), (1, 0), (2, 2), (6, 1), (10, 0), (11, 2), (15, 3)]

movesLeft :: World -> Int
movesLeft = positionMoves . currentPosition

tiles :: World -> [(Cell, Piece, Int)]
tiles world =
  [(location, piece, rotation) | (location, (piece, rotation)) <- M.toAscList grid]
  where
    grid = positionGrid (currentPosition world)

goals :: [Cell]
goals = [Cell 10, Cell 15]

basePorts :: Cell -> Piece -> [Direction]
basePorts _ Straight = [West, East]
basePorts (Cell number) Elbow
  | number `elem` [2, 11] = [West, South]
  | otherwise = [North, East]

ports :: Cell -> Piece -> Int -> [Direction]
ports location piece rotation = map rotateDirection (basePorts location piece)
  where
    rotateDirection direction = toEnum ((fromEnum direction + rotation) `mod` 4)

neighbor :: Cell -> Direction -> Maybe Cell
neighbor (Cell number) direction = case direction of
  North | number >= 4 -> Just (Cell (number - 4))
  East | number `mod` 4 < 3 -> Just (Cell (number + 1))
  South | number < 12 -> Just (Cell (number + 4))
  West | number `mod` 4 > 0 -> Just (Cell (number - 1))
  _ -> Nothing

opposite :: Direction -> Direction
opposite direction = toEnum ((fromEnum direction + 2) `mod` 4)

-- Follow only pipes whose openings meet. The seen set stops cycles.
wetCells :: World -> S.Set Cell
wetCells world
  | West `elem` openings inlet = visit S.empty [inlet]
  | otherwise = S.empty
  where
    inlet = Cell 0
    grid = positionGrid (currentPosition world)
    openings location = maybe [] (uncurry (ports location)) (M.lookup location grid)
    connectedNeighbors location =
      [ next
      | direction <- openings location,
        Just next <- [neighbor location direction],
        opposite direction `elem` openings next
      ]
    visit seen [] = seen
    visit seen (location : remaining)
      | location `S.member` seen = visit seen remaining
      | otherwise = visit (S.insert location seen) (connectedNeighbors location ++ remaining)

-- Winning on the last move counts as a win, so check gardens before the budget.
phase :: World -> Phase
phase world
  | all (`S.member` wetCells world) goals = Won
  | movesLeft world == 0 = OutOfMoves
  | otherwise = Playing

-- Read this dispatcher first: restart and undo are allowed even after game over.
step :: Command -> World -> (World, [Outcome])
step Restart world = (initialWith (sessionLevel world), [Restarted])
step Undo world = undoPrevious world
step (Rotate location) world = rotateTile location world

undoPrevious :: World -> (World, [Outcome])
undoPrevious world = case (undoUse world, previousPosition world) of
  (Available, Just previous) ->
    (world {currentPosition = previous, previousPosition = Nothing, undoUse = Spent}, [Undone])
  _ -> (world, [Refused])

rotateTile :: Cell -> World -> (World, [Outcome])
rotateTile location world
  | phase world /= Playing = (world, [Refused])
  | otherwise = case M.lookup location grid of
      Nothing -> (world, [Refused])
      Just (piece, rotation) ->
        let turnedGrid = M.insert location (piece, clockwise rotation) grid
            nextPosition = Position turnedGrid (positionMoves before - 1)
            nextWorld =
              world
                { currentPosition = nextPosition,
                  previousPosition = Just before
                }
         in (nextWorld, [Turned location])
  where
    before = currentPosition world
    grid = positionGrid before
    clockwise rotation = (rotation + 1) `mod` 4

canUndo :: World -> Bool
canUndo world = case (undoUse world, previousPosition world) of
  (Available, Just _) -> True
  _ -> False

-- The adapters below reuse the same pure transition; they do not duplicate rules.
data Circuit = Circuit

data Player = Gardener deriving (Eq, Show)

data Scene = Scene
  { sceneTiles :: [(Cell, Piece, Int)],
    sceneWet :: S.Set Cell,
    sceneMoves :: Int,
    scenePhase :: Phase,
    sceneUndo :: Bool
  }
  deriving (Eq, Show)

instance Machine Circuit where
  type State Circuit = World
  type Input Circuit = Command
  type Output Circuit = [Outcome]
  machine _ = Step step

instance Arena Circuit where
  type Agent Circuit = Player
  type Action Circuit = Command
  type Context Circuit = ()
  type View Circuit = Scene
  type Rejection Circuit = ()
  observe _ _ world = Scene (tiles world) (wetCells world) (movesLeft world) (phase world) (canUndo world)
  admit _ _ choices _ = case submissions choices of
    [(Gardener, action)] -> Right action
    _ -> Left ()
