{-# LANGUAGE TypeFamilies #-}
-- | Two protocol layers over the original pure session and scheduler rules.
module Garden.Adapter
  ( Garden (..), garden, Player (..), Boundary (..), GardenArena (..)
  , ProtocolError (..), splitGarden
  , ElapsedMicros (..), GardenFrame (..), GardenClock (..), gardenClock
  , GardenClockArena (..), splitGardenFrame
  ) where

import Game.Arena
import Game.Transition
import qualified Garden.Clock as Clock
import qualified Garden.Session as Session
import qualified Garden.Simulation as Simulation
import qualified Garden.View as View

-- | One explicit command or simulation tick is a complete kernel boundary.
data Garden = Garden

garden :: Step Session.Session Session.Event [Simulation.Effect]
garden = Step Session.advance

instance Machine Garden where
  type State Garden = Session.Session
  type Input Garden = Session.Event
  type Output Garden = [Simulation.Effect]
  machine _ = garden

data Player = Gardener deriving (Eq, Ord, Show)
data Boundary = PlayerBoundary | SimulationTick deriving (Eq, Show)
data ProtocolError = WrongBoundary | WrongParticipants deriving (Eq, Show)
data GardenArena = GardenArena

instance Machine GardenArena where
  type State GardenArena = Session.Session
  type Input GardenArena = Session.Event
  type Output GardenArena = [Simulation.Effect]
  machine _ = garden

instance Arena GardenArena where
  type Agent GardenArena = Player
  type Action GardenArena = Session.Command
  type Context GardenArena = Boundary
  type View GardenArena = View.RenderModel
  type Rejection GardenArena = ProtocolError

  observe _ Gardener = View.project
  admit _ boundary actions _ = case (boundary, submissions actions) of
    (PlayerBoundary, [(Gardener, command)]) -> Right (Session.Input command)
    (SimulationTick, []) -> Right Session.Tick
    _ -> Left WrongBoundary

-- | A tick has no player action; an input boundary has exactly one.
splitGarden :: Session.Event -> (Boundary, Joint Player Session.Command)
splitGarden Session.Tick = (SimulationTick, nobody)
splitGarden (Session.Input command) = (PlayerBoundary, singleton Gardener command)

-- | Distinguishes host elapsed microseconds from logical world ticks. The
-- scheduler clamps negative readings and applies its own five-tick cap.
newtype ElapsedMicros = ElapsedMicros Integer deriving (Eq, Ord, Show)
data GardenFrame = GardenFrame ElapsedMicros [Session.Command] deriving (Eq, Show)
data GardenClock = GardenClock

-- | Owns both the session and scheduler debt. Control commands and elapsed
-- time remain in one indivisible frame, so pause/resume cannot move tick debt.
gardenClock :: Step (Session.Session, Clock.Clock) GardenFrame [Simulation.Effect]
gardenClock = Step $ \(GardenFrame (ElapsedMicros elapsed) commands) (session, clock) ->
  let (next, nextClock, effects) = Clock.frame elapsed commands session clock
  in ((next, nextClock), effects)

instance Machine GardenClock where
  type State GardenClock = (Session.Session, Clock.Clock)
  type Input GardenClock = GardenFrame
  type Output GardenClock = [Simulation.Effect]
  machine _ = gardenClock

data GardenClockArena = GardenClockArena

instance Machine GardenClockArena where
  type State GardenClockArena = (Session.Session, Clock.Clock)
  type Input GardenClockArena = GardenFrame
  type Output GardenClockArena = [Simulation.Effect]
  machine _ = gardenClock

instance Arena GardenClockArena where
  type Agent GardenClockArena = Player
  type Action GardenClockArena = [Session.Command]
  type Context GardenClockArena = ElapsedMicros
  type View GardenClockArena = View.RenderModel
  type Rejection GardenClockArena = ProtocolError

  observe _ Gardener = View.project . fst
  admit _ elapsed actions _ = case submissions actions of
    [] -> Right (GardenFrame elapsed [])
    [(Gardener, commands)] -> Right (GardenFrame elapsed commands)
    _ -> Left WrongParticipants

-- | Preserve the ordered batch. A frame without commands still runs time.
splitGardenFrame :: GardenFrame -> (ElapsedMicros, Joint Player [Session.Command])
splitGardenFrame (GardenFrame elapsed commands) =
  (elapsed, if null commands then nobody else singleton Gardener commands)
