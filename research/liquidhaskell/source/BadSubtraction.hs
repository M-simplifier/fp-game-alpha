module BadSubtraction where
{-@ badSubtraction :: x:{Integer | x >= 0} -> y:{Integer | y >= 0} -> {v:Integer | v >= 0} @-}
badSubtraction :: Integer -> Integer -> Integer
badSubtraction x y = x - y
