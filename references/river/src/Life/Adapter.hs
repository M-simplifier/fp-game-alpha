{-# LANGUAGE TypeFamilies #-}

-- | The village has one authoritative transition. Protocol admission decides
-- which kind of boundary is being submitted; it does not redo game rules.
module Life.Adapter
  ( River (..),
    riverStep,
    Player (..),
    Boundary (..),
    RiverArena (..),
    ProtocolError (..),
    RiverView (..),
    splitCommand,
  )
where

import Data.Text (Text)
import Game.Arena
import Game.Transition
import Life.Domain qualified as Domain

data River = River

-- | One complete fixed movement tick or one explicit interaction/build input.
riverStep :: Step Domain.Game Domain.Command [Domain.Effect]
riverStep = Step Domain.advance

instance Machine River where
  type State River = Domain.Game
  type Input River = Domain.Command
  type Output River = [Domain.Effect]
  machine _ = riverStep

data Player = Villager deriving (Eq, Ord, Show)

data Boundary = MovementTick | InteractionBoundary deriving (Eq, Show)

data ProtocolError = WrongBoundary | WrongParticipants deriving (Eq, Show)

data RiverArena = RiverArena

-- | Disposable player-facing information. The integer fields are projections
-- from the original domain, not new range-safe types or game authority.
data RiverView = RiverView
  { viewPosition :: (Int, Int),
    viewDay :: Int,
    viewDayTicks :: Int,
    viewWeather :: Domain.Weather,
    viewTurnips :: Int,
    viewDryWood :: Int,
    viewDinner :: Domain.DinnerStatus,
    viewBuildSelection :: Domain.BuildKind,
    viewInteraction :: Text,
    viewJournal :: [Text]
  }
  deriving (Eq, Show)

instance Machine RiverArena where
  type State RiverArena = Domain.Game
  type Input RiverArena = Domain.Command
  type Output RiverArena = [Domain.Effect]
  machine _ = riverStep

instance Arena RiverArena where
  type Agent RiverArena = Player
  type Action RiverArena = Domain.Command
  type Context RiverArena = Boundary
  type View RiverArena = RiverView
  type Rejection RiverArena = ProtocolError

  observe _ Villager game =
    RiverView
      { viewPosition = Domain.playerPosition game,
        viewDay = Domain.dayNumber game,
        viewDayTicks = Domain.dayTicks game,
        viewWeather = Domain.weather game,
        viewTurnips = Domain.turnipCount game,
        viewDryWood = Domain.dryWoodCount game,
        viewDinner = Domain.dinnerStatus game,
        viewBuildSelection = Domain.selectedBuild game,
        viewInteraction = Domain.interactionLabel game,
        viewJournal = Domain.journal game
      }

  admit _ boundary actions _ = case (boundary, submissions actions) of
    -- A no-input host tick still advances one authoritative logical step.
    (MovementTick, []) -> Right (Domain.Tick 0 0)
    (MovementTick, [(Villager, command@(Domain.Tick _ _))]) -> Right command
    (InteractionBoundary, [(Villager, command)]) -> case command of
      Domain.Tick _ _ -> Left WrongBoundary
      _ -> Right command
    _ -> Left WrongParticipants

-- | Reconstruct the protocol input for a command trace without reordering it.
splitCommand :: Domain.Command -> (Boundary, Joint Player Domain.Command)
splitCommand command =
  ( case command of Domain.Tick _ _ -> MovementTick; _ -> InteractionBoundary,
    singleton Villager command
  )
