module CancelLoss where
-- Body and Haskell type copied verbatim from frozen 0.4 Colony.Jobs.
-- A successful check is conditional on imported div assumptions; see DivAssumptionProbe.
{-@ cancelLoss :: progress:{Integer | 0 <= progress} -> required:{Integer | 0 < required && progress <= required} -> quantity:{Integer | 0 <= quantity} -> {v:Integer | 0 <= v && v <= quantity} @-}
cancelLoss :: Integer -> Integer -> Integer -> Integer
cancelLoss progress required quantity=if required==0 then 0 else quantity*progress `div` required
