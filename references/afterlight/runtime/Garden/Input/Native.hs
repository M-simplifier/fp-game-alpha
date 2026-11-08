{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE PatternSynonyms #-}

module Garden.Input.Native
  ( NativeInput
  , InputSample
  , newNativeInput
  , pollInputSample
  , inputTime
  , inputClose
  , inputFocused
  , focusInterrupted
  , captureInterrupted
  , inputPresses
  , sampleGameInput
  , samplePhotoInput
  , data KeyEscape, data KeyEnter, data KeyF2, data KeyF3
  , data KeyF4, data KeyF5, data KeyF6, data KeyF11
  , data KeyF12, data KeyI, data KeyR
  ) where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Word (Word32)
import GHC.Clock (getMonotonicTimeNSec)
import qualified GameIO.Input as IO
import GameIO.Input.Event
import GameIO.Platform (Window, pollWindowEventsStamped)
import Garden.Photo (PhotoInput(..))
import Garden.Types

data NativeInput = NativeInput !(IORef (IO.InputTimeline, IO.InputState))

data InputSample = InputSample
  { inputTime :: !Double
  , inputClose :: !Bool
  , inputFocused :: !Bool
  , focusInterrupted :: !Bool
  , captureInterrupted :: !Bool
  , inputPresses :: ![Word32]
  , heldInput :: !IO.InputState
  , motion :: !(Float, Float)
  , wheel :: !Float
  }

newNativeInput :: IO NativeInput
newNativeInput = NativeInput <$> newIORef (IO.initialTimeline, IO.initialInput)

-- The host samples once per frame. The game's existing Clock then apportions
-- motion and carries edges across observations that produced no 60 Hz tick.
pollInputSample :: NativeInput -> Window -> IO InputSample
pollInputSample (NativeInput cell) window = do
  incoming <- pollWindowEventsStamped window
  now <- getMonotonicTimeNSec
  (timeline, old) <- readIORef cell
  (events, waiting) <- either (ioError . userError . show) pure $
    IO.acceptEvents incoming timeline >>= IO.takeThrough now
  let (current, stamped) = IO.reduceInput old events
      changes = map snd stamped
      (x, y, scroll) = foldl' accumulate (0, 0, 0) changes
  writeIORef cell (waiting, current)
  pure InputSample
    { inputTime = fromIntegral now / 1e9
    , inputClose = IO.InputClose `elem` changes
    , inputFocused = IO.hasFocus current
    , focusInterrupted = IO.InputCancel IO.FocusLost `elem` changes
    , captureInterrupted = any cancelled changes
    , inputPresses = [keyVirtual message | IO.InputKey IO.KeyPressed message <- changes]
    , heldInput = current
    , motion = (x, y)
    , wheel = scroll / 120
    }
  where
    accumulate (!x, !y, !scroll) change = case change of
      IO.InputDelta dx dy -> (x + fromIntegral dx, y + fromIntegral dy, scroll)
      IO.InputWheel _ dy _ _ -> (x, y, scroll + fromIntegral dy)
      IO.InputCancel _ -> (0, 0, 0)
      _ -> (x, y, scroll)
    cancelled (IO.InputCancel _) = True
    cancelled _ = False

pattern KeyEscape, KeyEnter, KeyF2, KeyF3, KeyF4, KeyF5, KeyF6, KeyF11, KeyF12, KeyI, KeyR :: Word32
pattern KeyEscape = 0x1b
pattern KeyEnter = 0x0d
pattern KeyF2 = 0x71
pattern KeyF3 = 0x72
pattern KeyF4 = 0x73
pattern KeyF5 = 0x74
pattern KeyF6 = 0x75
pattern KeyF11 = 0x7a
pattern KeyF12 = 0x7b
pattern KeyI = 0x49
pattern KeyR = 0x52

sampleGameInput :: Bool -> Int -> InputSample -> Input
sampleGameInput invertY currentSlot sample =
  Input (axis sample 0x44 0x41) (axis sample 0x57 0x53)
    (-mx * 0.0018) (my * (if invertY then 0.0018 else -0.0018))
    (edge 0x20) (held sample 0x20) (leftControl sample) (leftShift sample)
    (IO.pointerHeld state PointerLeft) (IO.pointerHeld state PointerRight)
    (edge 0x46) (edge 0x51) (edge 0x43) (edge 0x4e) slot (edge 0x45)
  where
    state = heldInput sample
    edge key = key `elem` inputPresses sample
    (mx, my) = motion sample
    slot = case [n | (n, key) <- zip [0 ..] [0x31 .. 0x36], edge key] of
      n : _ -> Just (currentSlot `div` 6 * 6 + n)
      [] | edge 0x09 -> Just ((currentSlot + 6) `mod` length hotbar)
         | wheel sample /= 0 -> Just ((currentSlot - if wheel sample > 0 then 1 else -1) `mod` length hotbar)
         | otherwise -> Nothing

samplePhotoInput :: InputSample -> PhotoInput
samplePhotoInput sample = PhotoInput
  velocity (-mx * 0.0018, -my * 0.0018) (wheel sample)
  (axis sample 0x45 0x51) (axis sample 0x26 0x28)
  (number (edge 0x27 || edge 0x09) - number (edge 0x25))
  (edge 0x42) (edge 0x56) (edge 0x47) (edge 0x43)
  where
    edge key = key `elem` inputPresses sample
    (mx, my) = motion sample
    direction = V3 (axis sample 0x44 0x41) (number (held sample 0x20) - number (leftControl sample)) (axis sample 0x57 0x53)
    speed | physical sample 0x12 0x38 = 1.5
          | leftShift sample = 35
          | otherwise = 9
    velocity = scale speed (if magnitude direction > 1 then unit direction else direction)

axis :: InputSample -> Word32 -> Word32 -> Float
axis sample positive negative = number (held sample positive) - number (held sample negative)

held :: InputSample -> Word32 -> Bool
held = IO.virtualKeyHeld . heldInput

leftShift, leftControl :: InputSample -> Bool
leftShift sample = physical sample 0x10 0x2a
leftControl sample = physical sample 0x11 0x1d

physical :: InputSample -> Word32 -> Word32 -> Bool
physical sample vk scan = IO.keyHeld (heldInput sample) (KeyMessage vk scan False True False)

number :: Num a => Bool -> a
number down = if down then 1 else 0
