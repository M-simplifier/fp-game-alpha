module Contracts where

-- Integer-carrier experiment only; production Qty has an Int64 representation.
{-@ type QtyValue = {v:Integer | 0 <= v && v <= 9000000000000} @-}

{-@ addQty :: x:{Integer | x >= 0} -> y:{Integer | y >= 0} -> {v:Integer | v == x + y && v >= 0} @-}
addQty :: Integer -> Integer -> Integer
addQty x y = x + y

{-@ subQty :: x:{Integer | x >= 0} -> y:{Integer | 0 <= y && y <= x} -> {v:Integer | v == x - y && v >= 0} @-}
subQty :: Integer -> Integer -> Integer
subQty x y = x - y

{-@ measure isSome @-}
isSome :: Maybe a -> Bool
isSome Nothing = False
isSome (Just _) = True

{-@ checkedAdd :: x:QtyValue -> y:QtyValue -> {v:Maybe {n:QtyValue | n == x + y} | isSome v <=> x + y <= 9000000000000} @-}
checkedAdd :: Integer -> Integer -> Maybe Integer
checkedAdd x y
  | x + y > 9000000000000 = Nothing
  | otherwise = Just (x + y)

{-@ checkedSub :: x:QtyValue -> y:QtyValue -> {v:Maybe {n:QtyValue | n == x - y} | isSome v <=> y <= x} @-}
checkedSub :: Integer -> Integer -> Maybe Integer
checkedSub x y
  | x < y = Nothing
  | otherwise = Just (x - y)

{-@ addFits :: x:QtyValue -> y:{QtyValue | y <= 9000000000000 - x} -> {v:QtyValue | v == x + y} @-}
addFits :: Integer -> Integer -> Integer
addFits x y = x + y
