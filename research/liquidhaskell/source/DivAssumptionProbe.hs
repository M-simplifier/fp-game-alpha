module DivAssumptionProbe where
-- Diagnostic only. Runtime result at x=0 is 0, so v=99 is deliberately false.
-- Expected REJECT from a sound exact-integer div contract.
{-@ divZeroProbe :: x:{Integer | x == 0} -> {v:Integer | v == 99} @-}
divZeroProbe :: Integer -> Integer
divZeroProbe x = x `div` 2
