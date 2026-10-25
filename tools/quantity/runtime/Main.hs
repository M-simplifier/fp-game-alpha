module Main (main) where

import Colony.Units
import Data.Int (Int64)

-- This runner imports the byte-identical, unannotated production module.
-- Expected results are computed independently by oracle.py, not here.
data TestUnit

format :: Either String (Qty TestUnit) -> String
format (Left e) = "ERR\t" ++ e
format (Right q) = "OK\t" ++ show (qtyValue q)

run :: String -> String
run line = case words line of
  ["max"] -> "MAX\t" ++ show quantityMax
  ["zero"] -> "OK\t" ++ show (qtyValue (zeroQty :: Qty TestUnit))
  ["int64-min"] -> "MIN\t" ++ show (toInteger (minBound :: Int64))
  ["int64-max"] -> "MAX\t" ++ show (toInteger (maxBound :: Int64))
  ["mk", n] -> format (mkQty (read n))
  ["add", a, b] -> format $ do
    qa <- mkQty (read a)
    qb <- mkQty (read b)
    addQty qa qb
  ["sub", a, b] -> format $ do
    qa <- mkQty (read a)
    qb <- mkQty (read b)
    subQty qa qb
  _ -> error ("Bad runner input: " ++ line)

main :: IO ()
main = interact (unlines . map run . lines)
