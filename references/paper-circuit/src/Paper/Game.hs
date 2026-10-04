{-# LANGUAGE TypeFamilies #-}
module Paper.Game
  ( Cell, cell, cellNumber, Direction(..), Piece(..), Command(..), Outcome(..)
  , Phase(..), World, initial, movesLeft, phase, tiles, wetCells, goals
  , ports, canUndo, step, Circuit(..), Player(..), Scene(..)
  ) where
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Game.Arena
import Game.Transition

newtype Cell = Cell Int deriving (Eq,Ord,Show)
cell :: Integer -> Maybe Cell
cell n | n >= 0 && n < 16 = Just (Cell (fromInteger n))
       | otherwise = Nothing
cellNumber :: Cell -> Int
cellNumber (Cell n) = n

data Direction = North | East | South | West deriving (Eq,Ord,Show,Enum,Bounded)
data Piece = Straight | Elbow deriving (Eq,Show)
data Command = Rotate Cell | Restart | Undo deriving (Eq,Show)
data Outcome = Turned Cell | Restarted | Undone | Refused deriving (Eq,Show)
data Phase = Playing | Won | OutOfMoves deriving (Eq,Show)
type Grid = M.Map Cell (Piece,Int)
data World = World Grid Int (Maybe (Grid,Int)) Bool deriving (Eq,Show)

-- A designed route is scrambled; decoys are not part of the witness solution.
initial :: World
initial = World (M.fromList [(Cell n, (kind n, spin n)) | n <- [0..15]]) 18 Nothing False
  where
    kind n | n `elem` [2,10,11,15] = Elbow
           | otherwise = Straight
    spin n = M.findWithDefault 1 n (M.fromList [(0,1),(1,0),(2,2),(6,1),(10,0),(11,2),(15,3)])

movesLeft :: World -> Int
movesLeft (World _ moves _ _) = moves
tiles :: World -> [(Cell,Piece,Int)]
tiles (World grid _ _ _) = [(c,p,r) | (c,(p,r)) <- M.toAscList grid]
goals :: [Cell]
goals = [Cell 10,Cell 15]

basePorts :: Cell -> Piece -> [Direction]
basePorts _ Straight = [West,East]
basePorts (Cell n) Elbow | n `elem` [2,11] = [West,South]
                        | otherwise = [North,East]
ports :: Cell -> Piece -> Int -> [Direction]
ports c p rotation = map (toEnum . (`mod` 4) . (+rotation) . fromEnum) (basePorts c p)

neighbor :: Cell -> Direction -> Maybe Cell
neighbor (Cell n) direction = case direction of
  North | n >= 4 -> Just (Cell (n-4))
  East | n `mod` 4 < 3 -> Just (Cell (n+1))
  South | n < 12 -> Just (Cell (n+4))
  West | n `mod` 4 > 0 -> Just (Cell (n-1))
  _ -> Nothing
opposite :: Direction -> Direction
opposite d = toEnum ((fromEnum d + 2) `mod` 4)

wetCells :: World -> S.Set Cell
wetCells (World grid _ _ _) =
  if West `elem` openings (Cell 0) then visit S.empty [Cell 0] else S.empty
  where
    openings c = maybe [] (uncurry (ports c)) (M.lookup c grid)
    adjacent c = [n | d <- openings c, Just n <- [neighbor c d], opposite d `elem` openings n]
    visit seen [] = seen
    visit seen (c:rest)
      | c `S.member` seen = visit seen rest
      | otherwise = visit (S.insert c seen) (adjacent c ++ rest)

phase :: World -> Phase
phase world
  | all (`S.member` wetCells world) goals = Won
  | movesLeft world == 0 = OutOfMoves
  | otherwise = Playing

step :: Command -> World -> (World,[Outcome])
step Restart _ = (initial,[Restarted])
step Undo (World _ _ (Just (grid,moves)) False) = (World grid moves Nothing True,[Undone])
step Undo world = (world,[Refused])
step (Rotate c) world@(World grid moves _ usedUndo)
  | phase world /= Playing = (world,[Refused])
  | otherwise = case M.lookup c grid of
      Nothing -> (world,[Refused])
      Just (piece,rotation) -> (World (M.insert c (piece,(rotation+1) `mod` 4) grid) (moves-1) (Just (grid,moves)) usedUndo,[Turned c])

canUndo :: World -> Bool
canUndo (World _ _ previous used) = maybe False (const (not used)) previous

data Circuit = Circuit
data Player = Gardener deriving (Eq,Show)
data Scene = Scene { sceneTiles :: [(Cell,Piece,Int)], sceneWet :: S.Set Cell
                   , sceneMoves :: Int, scenePhase :: Phase, sceneUndo :: Bool } deriving (Eq,Show)
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
  observe _ _ w = Scene (tiles w) (wetCells w) (movesLeft w) (phase w) (canUndo w)
  admit _ _ choices _ = case submissions choices of
    [(Gardener,a)] -> Right a
    _ -> Left ()
