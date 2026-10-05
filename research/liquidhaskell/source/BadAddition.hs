module BadAddition where
{-@ badAddition :: x:{Integer | x >= 0} -> y:{Integer | y >= 0} -> {v:Integer | v == x + y} @-}
badAddition :: Integer -> Integer -> Integer
badAddition x y = x + y + 1
