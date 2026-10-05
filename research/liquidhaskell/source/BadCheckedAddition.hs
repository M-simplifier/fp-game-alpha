module BadCheckedAddition where
import Contracts (isSome)
-- Returning Nothing for every input obeys only a weak Just-value condition;
-- the success-iff condition below is meant to reject this implementation.
{-@ badCheckedAddition :: x:{Integer | 0 <= x && x <= 9000000000000} -> y:{Integer | 0 <= y && y <= 9000000000000} -> {v:Maybe Integer | isSome v <=> x + y <= 9000000000000} @-}
badCheckedAddition :: Integer -> Integer -> Maybe Integer
badCheckedAddition _ _ = Nothing
