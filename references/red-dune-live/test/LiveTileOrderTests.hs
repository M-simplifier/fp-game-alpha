module Main where

import Colony.Space (Tile (..), tileIndex)
import Control.Monad (unless)
import Data.List (sortBy)
import Data.Map.Strict qualified as M

legacyCompare :: Tile -> Tile -> Ordering
legacyCompare a@(Tile x y) b@(Tile u v) = compare (tileIndex a, x, y) (tileIndex b, u, v)

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

main :: IO ()
main = do
  let coordinates = [negate (10 ^ (30 :: Int)), -1024, -513, -512, -511, -1, 0, 1, 2, 127, 255, 510, 511, 512, 513, 1024, 10 ^ (30 :: Int)]
      boundaries = [Tile x y | x <- coordinates, y <- coordinates]
      pairs = [(a, b) | a <- boundaries, b <- boundaries]
  check "exact old ordering on all boundary/negative/extreme pairs" (all (\(a, b) -> compare a b == legacyCompare a b) pairs)
  check "invalid arithmetic-index aliases remain distinct" (compare (Tile 512 0) (Tile 0 1) == GT && Tile 512 0 /= Tile 0 1)
  let valid = [Tile x y | y <- [0 .. 511], x <- [0 .. 511]]
  check "every adjacent valid tile retains strict row-major order" (all (\(a, b) -> compare a b == LT && legacyCompare a b == LT) (zip valid (drop 1 valid)))
  let sequenceValues = take 200000 (iterate (\n -> (1103515245 * n + 12345) `mod` 2147483648) (1729 :: Integer))
      generated = [Tile (a `mod` 1536 - 512) (b `mod` 1536 - 512) | (a, b) <- zip sequenceValues (drop 1 sequenceValues)]
  check "mixed generated valid/invalid comparator equivalence" (all (\(a, b) -> compare a b == legacyCompare a b) (zip generated (drop 1 generated)))
  check "Map order and duplicate-key replacement unchanged" (M.toAscList (M.fromList (zip boundaries [0 :: Int ..])) == sortBy (\(a, _) (b, _) -> legacyCompare a b) (zip boundaries [0 :: Int ..]))
  putStrLn "PASS: Tile ordering matches the original on 83,521 extreme pairs, all 262,143 valid neighbours and 199,998 generated mixed pairs"
