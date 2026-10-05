module NoDivFalseProbe where
-- Matched control: x=0 and false postcondition, without calling div.
{-@ noDivFalseProbe :: x:{Integer | x == 0} -> {v:Integer | v == 99} @-}
noDivFalseProbe :: Integer -> Integer
noDivFalseProbe x = x + 0
