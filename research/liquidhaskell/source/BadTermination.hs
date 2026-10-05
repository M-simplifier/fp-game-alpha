module BadTermination where
{-@ loop :: x:{Integer | 0 <= x} -> {v:Integer | 0 <= v} @-}
loop :: Integer -> Integer
loop x = loop x
