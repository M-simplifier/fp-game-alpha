-- | 10 Hz integer-microsecond scheduling. Commands are resolved once, before
-- scheduled ticks. Control edges clear debt; paused time never catches up.
module Garden.Clock (Clock, emptyClock, debtMicros, frame) where

import Garden.Session
import Garden.Simulation (Effect)

-- | Unspent elapsed microseconds; host time is separate from world ticks.
newtype Clock = Clock Integer deriving (Eq, Show)

emptyClock :: Clock
emptyClock = Clock 0

debtMicros :: Clock -> Integer
debtMicros (Clock n) = n

-- | Negative elapsed input is zero. Running debt is retained, drained at most
-- 5 ticks/frame. A pause, step, reset or resume discards pre-command elapsed
-- time explicitly so a control edge cannot accidentally add another tick.
frame :: Integer -> [Command] -> Session -> Clock -> (Session, Clock, [Effect])
frame elapsed commands initial (Clock debt) =
  let (controlled, inputEffects) = applyEvents (map Input commands) initial
      boundary = any control commands
      total = if isPaused controlled || boundary then 0 else debt + max 0 elapsed
      count = fromInteger (min 5 (total `div` 100000))
      (advanced, tickEffects) = applyEvents (replicate count Tick) controlled
   in (advanced, Clock (total - fromIntegral count * 100000), inputEffects ++ tickEffects)
  where
    control TogglePause = True
    control StepOnce = True
    control ResetSameSeed = True
    control _ = False
