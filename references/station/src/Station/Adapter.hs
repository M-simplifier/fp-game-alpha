{-# LANGUAGE TypeFamilies #-}
-- | Protocol boundary for the original six-order dispatch rules.
module Station.Adapter
  ( Station (..), stationStep, Dispatch (..), Outcome (..)
  , Clerk (..), StationArena (..), ProtocolError (..), StationView (..)
  ) where

import Game.Arena
import Game.Transition
import qualified Station.Domain as Domain

-- | An atomic command carries the visible turn token and a chosen service.
-- The token constructor is private in 'Station.Domain'; stale tokens remain
-- possible by replay and are rejected by the authoritative game rule.
data Dispatch = Dispatch Domain.TurnId Domain.Choice deriving (Eq, Show)
data Outcome = Accepted Domain.Stats | Refused Domain.DomainError
  deriving (Eq, Show)
data Station = Station

-- | Preserve a failed choice as an output while leaving state unchanged.
-- This uses 'Domain.step' rather than duplicating its cost or stale-turn rule.
stationStep :: Step Domain.GameState Dispatch [Outcome]
stationStep = Step $ \(Dispatch turn choice) game ->
  case Domain.step turn choice game of
    Left problem -> (game, [Refused problem])
    Right next -> (next, [Accepted (Domain.stats next)])

instance Machine Station where
  type State Station = Domain.GameState
  type Input Station = Dispatch
  type Output Station = [Outcome]
  machine _ = stationStep

data Clerk = LocalClerk deriving (Eq, Ord, Show)
data ProtocolError = WrongParticipants deriving (Eq, Show)
data StationArena = StationArena

-- | A disposable screen summary, including the same option results used by
-- the domain transition. Updating a view cannot alter a GameState.
data StationView = StationView
  { viewTurn :: Maybe Domain.TurnId
  , viewResources :: Domain.Stats
  , viewOptions :: [Domain.ChoiceOption]
  , viewEnding :: Maybe Domain.Ending
  , viewCompleted :: Int
  } deriving (Eq, Show)

instance Machine StationArena where
  type State StationArena = Domain.GameState
  type Input StationArena = Dispatch
  type Output StationArena = [Outcome]
  machine _ = stationStep

instance Arena StationArena where
  type Agent StationArena = Clerk
  type Action StationArena = Dispatch
  type Context StationArena = ()
  type View StationArena = StationView
  type Rejection StationArena = ProtocolError

  observe _ LocalClerk game = StationView
    { viewTurn = Domain.currentTurn game
    , viewResources = Domain.stats game
    , viewOptions = Domain.choices game
    , viewEnding = Domain.ending game
    , viewCompleted = Domain.completedTurns game
    }

  -- A stale turn is an attempted game choice, not a protocol-shape error.
  admit _ _ actions _ = case submissions actions of
    [(LocalClerk, command)] -> Right command
    _ -> Left WrongParticipants
