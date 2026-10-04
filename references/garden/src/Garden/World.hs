-- | Finite, immutable authoritative state. Coordinates and worlds cannot be
-- constructed with an invalid extent through this module's public API.
module Garden.World
  ( Cell (..), Material (..), materialCell, materials
  , Coord, coord, xy, coords, offset, width, height
  , Seed, seedFromText, seedCode, sample
  , World, emptyWorld, initialWorld, worldSeed, worldTick, cellAt
  , occupied, writeCells, advanceTime, fingerprint
  ) where

import Data.Bits (shiftR, xor)
import Data.Char (ord)
import Data.List (foldl')
import qualified Data.IntMap.Strict as IM
import Data.Word (Word32)
import Numeric (showHex)

width, height :: Int
width = 80
height = 44

data Cell = Empty | Stone | Water | Sand | SeedCell | Plant | Light | Flower
  deriving (Eq, Ord, Enum, Bounded, Show)

data Material = PourWater | PlaceStone | PourSand | SowSeed | PlaceLight | Erase
  deriving (Eq, Ord, Enum, Bounded, Show)

materials :: [Material]
materials = [minBound .. maxBound]

materialCell :: Material -> Cell
materialCell m = case m of
  PourWater -> Water
  PlaceStone -> Stone
  PourSand -> Sand
  SowSeed -> SeedCell
  PlaceLight -> Light
  Erase -> Empty

newtype Coord = Coord Int deriving (Eq, Ord, Show)

coord :: Int -> Int -> Maybe Coord
coord x y
  | x >= 0 && x < width && y >= 0 && y < height = Just (Coord (y * width + x))
  | otherwise = Nothing

xy :: Coord -> (Int, Int)
xy (Coord n) = (n `mod` width, n `div` width)

coords :: [Coord]
coords = map Coord [0 .. width * height - 1]

offset :: Coord -> (Int, Int) -> Maybe Coord
offset p (dx, dy) = let (x, y) = xy p in coord (x + dx) (y + dy)

newtype Seed = Seed Word32 deriving (Eq, Show)

seedFromText :: String -> Seed
seedFromText = Seed . foldl' (\h c -> (h `xor` fromIntegral (ord c)) * 16777619) 2166136261

seedCode :: Seed -> String
seedCode (Seed n) = let s = showHex n "" in replicate (8 - length s) '0' ++ s

-- | Stateless integer noise: seed, position and logical time are explicit.
sample :: Seed -> Coord -> Integer -> Word32
sample (Seed s) p t =
  let (x, y) = xy p
      h = s `xor` (fromIntegral (x + 1) * 374761393)
            `xor` (fromIntegral (y + 1) * 668265263)
            `xor` (fromInteger (t + 1) * 1274126177)
      h' = (h `xor` (h `shiftR` 13)) * 1274126177
   in h' `xor` (h' `shiftR` 16)

data World = World !Seed !Integer !(IM.IntMap Cell) deriving (Eq, Show)

emptyWorld :: Seed -> World
emptyWorld s = World s 0 IM.empty

worldSeed :: World -> Seed
worldSeed (World s _ _) = s

worldTick :: World -> Integer
worldTick (World _ t _) = t

cellAt :: World -> Coord -> Cell
cellAt (World _ _ cells) (Coord p) = IM.findWithDefault Empty p cells

occupied :: World -> [(Coord, Cell)]
occupied (World _ _ cells) = [(Coord p, c) | (p, c) <- IM.toAscList cells]

-- | Later writes win. Empty entries are removed, never stored.
writeCells :: [(Coord, Cell)] -> World -> World
writeCells edits (World s t cells) = World s t (foldl' write cells edits)
  where
    write m (Coord p, Empty) = IM.delete p m
    write m (Coord p, c) = IM.insert p c m

advanceTime :: World -> World
advanceTime (World s t cells) = World s (t + 1) cells

initialWorld :: Seed -> World
initialWorld s = writeCells [(p, terrain p) | p <- coords] (emptyWorld s)
  where
    terrain p
      | y >= ground + 2 = Stone
      | y >= ground = Sand
      | basin 7 30 21 || basin 46 68 30 = Stone
      | x >= 8 && x <= 29 && y >= 18 && y <= 20 = Water
      | x >= 47 && x <= 67 && y >= 27 && y <= 29 = Water
      | (x,y) `elem` [(13,17),(25,17),(51,26),(63,26)] = SeedCell
      | (x,y) `elem` [(19,13),(57,22),(36,31)] = Light
      | x >= 31 && x <= 43 && y == 28 = Stone
      | otherwise = Empty
      where
        (x,y) = xy p
        ground = 38 + (x `div` 11 + fromIntegral (sample s p 0 `mod` 2)) `mod` 3
        basin lo hi floorY = (y == floorY && x >= lo && x <= hi)
          || (y >= floorY - 4 && y < floorY && (x == lo || x == hi))

-- | Diagnostic checksum, not a collision-free identity or save format.
fingerprint :: World -> String
fingerprint w =
  let h = foldl' mix (2166136261 :: Word32) coords
      s = showHex h ""
   in replicate (8 - length s) '0' ++ s
  where
    mix h p = (h `xor` fromIntegral (fromEnum (cellAt w p))) * 16777619
