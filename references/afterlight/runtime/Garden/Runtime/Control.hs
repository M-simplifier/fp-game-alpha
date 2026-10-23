-- | Frame-local host decisions. The runtime still owns polling and effects;
-- this policy owns the precedence of simultaneous modal controls.
module Garden.Runtime.Control
  ( FrameContext (..),
    FrameKeys (..),
    PhotoTransition (..),
    FramePlan (..),
    planFrame,
  )
where

import Garden.Host.Control (ControlMode (..))
import Garden.Session (FrameMode (..))

data FrameContext = FrameContext
  { controlMode :: ControlMode,
    windowFocused :: Bool,
    pausedBefore :: Bool,
    photoOpen :: Bool,
    freePlay :: Bool
  }
  deriving (Eq, Show)

data FrameKeys = FrameKeys
  { escapePressed :: Bool,
    photoPressed :: Bool,
    enterPressed :: Bool,
    capturePressed :: Bool
  }
  deriving (Eq, Show)

data PhotoTransition = KeepPhoto | EnterPhoto | LeavePhoto deriving (Eq, Show)

data FramePlan = FramePlan
  { pausedAfter :: Bool,
    photoTransition :: PhotoTransition,
    captureRequested :: Bool,
    audioPaused :: Bool,
    simulationMode :: FrameMode,
    acceptsGameInput :: Bool,
    saveAndExit :: Bool
  }
  deriving (Eq, Show)

planFrame :: FrameContext -> FrameKeys -> FramePlan
planFrame context keys =
  FramePlan paused photo capture frozen mode acceptsInput exit
  where
    wasPhoto = photoOpen context
    leavingPhoto = wasPhoto && (photoPressed keys || escapePressed keys)
    enteringPhoto = not wasPhoto && photoPressed keys
    photo
      | leavingPhoto = LeavePhoto
      | enteringPhoto = EnterPhoto
      | otherwise = KeepPhoto
    paused
      | wasPhoto || enteringPhoto = pausedBefore context
      | controlMode context == Interactive && not (windowFocused context) && freePlay context = True
      | escapePressed keys = not (pausedBefore context)
      | otherwise = pausedBefore context
    capture = capturePressed keys || wasPhoto && enterPressed keys && not leavingPhoto
    photoDuringFrame = enteringPhoto || wasPhoto && not leavingPhoto
    frozen = paused || photoDuringFrame || leavingPhoto
    -- Closing pause with Escape freezes this one simulation frame while
    -- restoring live audio, exactly as the original host did.
    mode = if frozen || escapePressed keys then Frozen else Advancing
    acceptsInput = controlMode context == Interactive && mode == Advancing
    exit = paused && enterPressed keys && not wasPhoto && not enteringPhoto
