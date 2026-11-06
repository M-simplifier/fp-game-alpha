module PureFall.Time
  ( TickNo,
    TickSpan,
    FrameMicros,
    DebtUnits,
    tickNo,
    tickCount,
    tickSpan,
    tickSpanCount,
    frameMicros,
    frameMicroCount,
    debtUnitsFromCount,
    debtUnitCount,
  )
where

newtype TickNo = TickNo Int deriving (Eq, Ord, Show)

newtype TickSpan = TickSpan Int deriving (Eq, Ord, Show)

newtype FrameMicros = FrameMicros Integer deriving (Eq, Ord, Show)

newtype DebtUnits = DebtUnits Integer deriving (Eq, Ord, Show)

tickNo :: Int -> TickNo
tickNo = TickNo . max 0

tickCount :: TickNo -> Int
tickCount (TickNo count) = count

tickSpan :: Int -> TickSpan
tickSpan = TickSpan . max 0

tickSpanCount :: TickSpan -> Int
tickSpanCount (TickSpan count) = count

frameMicros :: Integer -> FrameMicros
frameMicros = FrameMicros . max 0

frameMicroCount :: FrameMicros -> Integer
frameMicroCount (FrameMicros count) = count

debtUnitsFromCount :: Integer -> DebtUnits
debtUnitsFromCount = DebtUnits . max 0

debtUnitCount :: DebtUnits -> Integer
debtUnitCount (DebtUnits count) = count
