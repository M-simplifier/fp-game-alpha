{-# LANGUAGE TypeFamilies #-}
-- | Thin, auditable adapters over the one authoritative 'Domain.frame' rule.
module Tapline.Adapter
  ( Tapline (..), tapline, TaplineArena (..), Player (..)
  , FrameContext (..), ProtocolError (..), splitTapline
  ) where

import Game.Arena
import Game.Transition
import qualified Tapline.Clock as Clock
import qualified Tapline.Domain as Domain
import qualified Tapline.Input as Input
import qualified Tapline.View as View

-- | The direct transition witness has no protocol or observation layer.
data Tapline = Tapline

tapline :: Step Domain.Session Domain.Frame [Domain.Effect]
tapline = Step Domain.frame

instance Machine Tapline where
  type State Tapline = Domain.Session
  type Input Tapline = Domain.Frame
  type Output Tapline = [Domain.Effect]
  machine _ = tapline

-- | One local participant; an empty joint action still advances host time.
data Player = LocalPlayer deriving (Eq, Ord, Show)

-- | Wall reading and focus are supplied by the host, never inferred from state.
data FrameContext = FrameContext Clock.Stamp Bool deriving (Eq, Show)
data ProtocolError = WrongParticipants deriving (Eq, Show)
data TaplineArena = TaplineArena

instance Machine TaplineArena where
  type State TaplineArena = Domain.Session
  type Input TaplineArena = Domain.Frame
  type Output TaplineArena = [Domain.Effect]
  machine _ = tapline

instance Arena TaplineArena where
  type Agent TaplineArena = Player
  type Action TaplineArena = [Input.Command]
  type Context TaplineArena = FrameContext
  type View TaplineArena = View.RenderModel
  type Rejection TaplineArena = ProtocolError

  observe _ LocalPlayer = View.project
  admit _ (FrameContext whenFocused hasFocus) submitted _ =
    case submissions submitted of
      [] -> Right (Domain.Frame whenFocused hasFocus [])
      [(LocalPlayer, commands)] -> Right (Domain.Frame whenFocused hasFocus commands)
      _ -> Left WrongParticipants

-- | A full frame maps to a context and one ordered command batch. In
-- particular, reset and repeated keys are never split into joint actions.
splitTapline :: Domain.Frame -> (FrameContext, Joint Player [Input.Command])
splitTapline input =
  (FrameContext (Domain.observedAt input) (Domain.hasFocus input),
   if null (Domain.commands input)
     then nobody
     else singleton LocalPlayer (Domain.commands input))
