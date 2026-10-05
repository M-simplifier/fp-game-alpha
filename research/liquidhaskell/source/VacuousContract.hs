module VacuousContract where
-- Expected SAFE only because the input refinement is uninhabited.
{-@ impossibleInput :: x:{Integer | x < 0 && x >= 0} -> {v:Integer | v == 42} @-}
impossibleInput :: Integer -> Integer
impossibleInput _ = 0
