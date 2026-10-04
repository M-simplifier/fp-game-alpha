{-# LANGUAGE TypeFamilies #-}

-- | Finite puzzle: one cart move clears a fish row, causing one departure.
-- Admission shares the original 'advance' rule; the game is fully observed.
module Lantern
  ( Axis (..),
    Cart (..),
    Board,
    BoardError (..),
    mkBoard,
    initial,
    World,
    positions,
    remaining,
    Move (..),
    Departed (..),
    Lantern (..),
    wellFormed,
    legal,
    advance,
    allMoves,
    successors,
  )
where

import Data.Bits (clearBit, testBit)
import Data.List (nub)
import Game.Arena
import Game.Transition

data Axis = H | V deriving (Eq, Ord, Show, Read)

-- | The fixed lane and length; the variable coordinate is a board position.
data Cart = Cart {axis :: Axis, lane :: Int, size :: Int} deriving (Eq, Ord, Show, Read)

data Board = Board {carts :: [Cart], initialPositions :: [Int], fishRows :: [Int]} deriving (Eq, Ord, Show)

-- | Belongs to one checked board. Constructor and update fields stay private.
data World = World
  {worldBoard :: Board, worldPositions :: [Int], worldRemaining :: Int}
  deriving (Eq, Ord, Show)

data Move = Move Int Int deriving (Eq, Ord, Show, Read)

-- | Departed rows in board order. The monoid appends outputs chronologically.
newtype Departed = Departed [Int] deriving (Eq, Show)

newtype Lantern = Lantern Board

instance Semigroup Departed where
  Departed earlier <> Departed later = Departed (earlier ++ later)

instance Monoid Departed where
  mempty = Departed []

data BoardError
  = CartPositionCountMismatch
  | InvalidCart Int
  | InvalidFishRows
  | InitialCollision
  | InitiallyClearFishRow
  deriving (Eq, Show)

-- | Read-only projection. Exporting a record selector would also allow an
-- external record update even when the constructor is hidden.
positions :: World -> [Int]
positions = worldPositions

-- | The finite mask of fish still present, not an arbitrary score.
remaining :: World -> Int
remaining = worldRemaining

-- | Test the size before subtracting it from the board width. This avoids
-- accepting @maxBound :: Int@ through overflow in @p + size@.
validCartPosition :: Cart -> Int -> Bool
validCartPosition cart p =
  size cart >= 2
    && size cart <= 3
    && lane cart >= 0
    && lane cart < 6
    && p >= 0
    && p <= 6 - size cart

-- | Check board geometry before creating a World. Distinct fish rows inside
-- the six-by-six board also bound the bit mask to six bits.
mkBoard :: [Cart] -> [Int] -> [Int] -> Either BoardError Board
mkBoard vehicles starts fish
  | length vehicles /= length starts = Left CartPositionCountMismatch
  | invalid : _ <-
      [ i
      | (i, cart, p) <- zip3 [0 ..] vehicles starts,
        not (validCartPosition cart p)
      ] =
      Left (InvalidCart invalid)
  | null fish || length fish /= length (nub fish) || any (\row -> row < 0 || row >= 6) fish = Left InvalidFishRows
  | length initialCells /= length (nub initialCells) = Left InitialCollision
  | any (\row -> all ((/= row) . snd) initialCells) fish = Left InitiallyClearFishRow
  | otherwise = Right proposed
  where
    proposed = Board vehicles starts fish
    initialCells = occupied proposed (World proposed starts 0)

initial :: Board -> World
initial b = World b (initialPositions b) (2 ^ length (fishRows b) - 1)

cells :: Cart -> Int -> [(Int, Int)]
cells (Cart H row n) p = [(p + i, row) | i <- [0 .. n - 1]]
cells (Cart V col n) p = [(col, p + i) | i <- [0 .. n - 1]]

occupied :: Board -> World -> [(Int, Int)]
occupied b s = concat (zipWith cells (carts b) (positions s))

wellFormed :: Board -> World -> Bool
wellFormed b s =
  worldBoard s == b
    && length (positions s) == length (carts b)
    && all (uncurry validCartPosition) (zip (carts b) (positions s))
    && length cs == length (nub cs)
    && remaining s >= 0
    && remaining s < 2 ^ length (fishRows b)
  where
    cs = occupied b s

allMoves :: Board -> [Move]
allMoves b = [Move i d | i <- [0 .. length (carts b) - 1], d <- [-1, 1]]

replaceAt :: Int -> a -> [a] -> [a]
replaceAt i a xs = take i xs ++ [a] ++ drop (i + 1) xs

legal :: Board -> World -> Move -> Bool
legal b s (Move i d) =
  wellFormed b s
    && remaining s /= 0
    && i >= 0
    && i < length (carts b)
    && d `elem` [-1, 1]
    && wellFormed b shifted
  where
    shifted = s {worldPositions = replaceAt i ((positions s !! i) + d) (positions s)}

-- | The only collision/departure implementation. Invalid moves preserve state
-- and emit no rows; 'admit' rejects the same moves before the rule runs.
advance :: Board -> Move -> World -> (World, Departed)
advance b action@(Move i d) s
  | not (legal b s action) = (s, Departed [])
  | otherwise = (shifted {worldRemaining = foldl clearBit (remaining s) departing}, Departed [fishRows b !! j | j <- departing])
  where
    shifted = s {worldPositions = replaceAt i ((positions s !! i) + d) (positions s)}
    departing =
      [ j
      | (j, row) <- zip [0 ..] (fishRows b),
        testBit (remaining s) j,
        all ((/= row) . snd) (occupied b shifted)
      ]

instance Machine Lantern where
  type State Lantern = World
  type Input Lantern = Move
  type Output Lantern = Departed
  machine (Lantern b) = Step (advance b)

instance Arena Lantern where
  type Agent Lantern = ()
  type Action Lantern = Move
  type Context Lantern = ()
  type View Lantern = World
  type Rejection Lantern = String
  observe _ _ = id
  admit (Lantern b) _ choices s = case submissions choices of
    [((), m)] | legal b s m -> Right m
    _ -> Left "This trolley cannot move that way."

-- | Enumerate admitted successors using the original transition in 'play'.
successors :: Board -> World -> [(Move, World, Departed)]
successors b s = [(m, t, o) | m <- allMoves b, Right (t, o) <- [play (Lantern b) () (singleton () m) s]]
