module Life.Clock (Clock, initialClock, schedule, clearClock, debtMicros) where

-- Host time allocation; no game law reads rendering FPS. Excess remains debt.
newtype Clock = Clock Integer deriving (Eq, Show)

initialClock :: Clock
initialClock = Clock 0

clearClock :: Clock -> Clock
clearClock _ = initialClock

debtMicros :: Clock -> Integer
debtMicros (Clock n) = n

schedule :: Integer -> Clock -> (Int, Clock)
schedule elapsed (Clock old) =
  let total = old + max 0 elapsed
      count = min 8 (total `div` 33333)
   in (fromInteger count, Clock (total - count * 33333))
