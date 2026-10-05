module DivNonzeroProbe where
-- Matched control: same false postcondition, but the two suspect clauses
-- are consistent for x=2, y=2. Expected UNSAFE.
{-@ divNonzeroProbe :: x:{Integer | x == 2} -> {v:Integer | v == 99} @-}
divNonzeroProbe :: Integer -> Integer
divNonzeroProbe x = x `div` 2
