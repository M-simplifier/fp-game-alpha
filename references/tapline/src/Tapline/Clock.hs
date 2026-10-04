module Tapline.Clock (Stamp, stamp, micros, Clock, anchor, observe) where

-- | Nonnegative observed wall time in microseconds, distinct from game time.
newtype Stamp = Stamp Integer deriving (Eq, Ord, Show)
newtype Clock = Clock Stamp deriving (Eq, Show)

-- | Clamp an external clock reading at zero; 'observe' also clamps regressions.
stamp :: Integer -> Stamp
stamp = Stamp . max 0

micros :: Stamp -> Integer
micros (Stamp n) = n

anchor :: Stamp -> Clock
anchor = Clock

-- Wall time is remembered even when active time is resting.
observe :: Bool -> Stamp -> Clock -> (Integer, Clock)
observe advancing observed (Clock previous) =
  let now = max previous observed
      dt = if advancing then micros now - micros previous else 0
  in (dt, Clock now)
