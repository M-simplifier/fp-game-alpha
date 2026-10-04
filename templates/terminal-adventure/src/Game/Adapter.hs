{-# LANGUAGE TypeFamilies #-}

-- | Admission validates who submitted; the original rules resolve the attempt.
module Game.Adapter (Adventure (..), Player (..)) where

import Game.Arena
import Game.Model
import Game.Rules (adventureStep)
import Game.Transition
import Game.View (render)

data Adventure = Adventure
data Player = LocalPlayer deriving (Eq, Show)

instance Machine Adventure where
  type State Adventure = World
  type Input Adventure = Command
  type Output Adventure = [Event]
  machine _ = adventureStep

instance Arena Adventure where
  type Agent Adventure = Player
  type Action Adventure = Command
  type Context Adventure = ()
  type View Adventure = String
  type Rejection Adventure = String
  observe _ LocalPlayer = render
  admit _ () choices _ = case submissions choices of
    [(LocalPlayer, command)] -> Right command
    _ -> Left "One local-player action is required."
