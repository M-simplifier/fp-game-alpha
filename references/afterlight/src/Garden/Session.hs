{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeFamilies #-}

-- | frameの観測から本番tickへ進む純粋な境界。
-- pause/photo/背景復帰はContext、操作と再出発はAction。
-- GPU・音声handle・実時計・保存IOはこの状態に含まない。
module Garden.Session
  ( AfterlightSession (..),
    Simulation,
    beginSimulation,
    suspendSimulation,
    simulationWorld,
    simulationPilot,
    FrameMode (..),
    Driver (..),
    FrameBoundary (..),
    FrameAction (..),
    FrameEffects (..),
    SessionView (..),
    FrameRejection (..),
    frameChoices,
  )
where

import Game.Arena
import Game.Transition
import Garden.Arena
import Garden.Clock
import Garden.Tour qualified as Tour
import Garden.Types qualified as Garden
import Garden.View
import Garden.World (restartWorld)

data AfterlightSession = AfterlightSession

data FrameMode = Advancing | Frozen deriving (Eq, Show)

-- 診断pilotはWorld/saveへ混ぜない。原版と同じ入力だけを発行する。
data Driver = HumanDriver | StoryDriver | IslandDriver deriving (Eq, Show)

data FrameBoundary = FrameBoundary
  {elapsedSeconds :: Double, frameMode :: FrameMode, frameDriver :: Driver}
  deriving (Eq, Show)

data FrameAction = FrameAction
  {sampledControls :: Garden.Input, restartLost :: Bool}
  deriving (Eq, Show)

data Simulation = Simulation
  { currentWorld :: Garden.World,
    simulationClock :: Clock,
    previousTickEye :: Garden.V3,
    currentPilot :: Tour.Pilot
  }
  deriving (Eq)

-- These are queries, not record labels: changing the world or pilot alone
-- would retain an unrelated clock and interpolation history.
simulationWorld :: Simulation -> Garden.World
simulationWorld = currentWorld

simulationPilot :: Simulation -> Tour.Pilot
simulationPilot = currentPilot

-- Preserve the existing diagnostic vocabulary and precedence despite keeping
-- the actual fields private. Show is an observation, never a reconstruction.
instance Show Simulation where
  showsPrec precedence (Simulation world clock prior pilot) =
    showParen (precedence > 10) $
      showString "Simulation {simulationWorld = "
        . shows world
        . showString ", simulationClock = "
        . shows clock
        . showString ", previousTickEye = "
        . shows prior
        . showString ", simulationPilot = "
        . shows pilot
        . showChar '}'

-- 各tickの空cueも保持する。Yampaの時刻はcueの有無に関係なく進む。
newtype FrameEffects = FrameEffects {tickCues :: [[Garden.Cue]]}
  deriving (Eq, Show)

data SessionView = SessionView
  {exactScene :: SceneView, interpolatedScene :: SceneView}
  deriving (Eq, Show)

data FrameRejection = NonFiniteElapsed | TooLargeElapsed | FrameParticipants
  deriving (Eq, Show)

-- constructorはadmitだけが使う。無効な外部frame時刻をfloorへ流さない。
data AcceptedFrame = AcceptedFrame FrameBoundary FrameAction

beginSimulation :: Garden.World -> Simulation
beginSimulation world = Simulation world emptyClock (Garden.eye (Garden.worldPlayer world)) (Tour.Pilot 0 0)

suspendSimulation :: Simulation -> Simulation
suspendSimulation state = state {simulationClock = emptyClock}

frameChoices :: Garden.Input -> Bool -> Joint Gardener FrameAction
frameChoices controls restart = singleton Gardener (FrameAction controls restart)

instance Machine AfterlightSession where
  type State AfterlightSession = Simulation
  type Input AfterlightSession = AcceptedFrame
  type Output AfterlightSession = FrameEffects
  machine _ = Step advanceFrame

instance Arena AfterlightSession where
  type Agent AfterlightSession = Gardener
  type Action AfterlightSession = FrameAction
  type Context AfterlightSession = FrameBoundary
  type View AfterlightSession = SessionView
  type Rejection AfterlightSession = FrameRejection
  admit _ context choices _
    | isNaN dt || isInfinite dt = Left NonFiniteElapsed
    -- Keep the elapsed-input contract independently of the scheduler's
    -- bounded conversion: accumulated debt may exceed one admitted frame.
    | dt > fromIntegral (maxBound :: Int) / 120 = Left TooLargeElapsed
    | otherwise = case submissions choices of
        [] -> Right (AcceptedFrame context (FrameAction Garden.idleInput False))
        [(Gardener, action)] -> Right (AcceptedFrame context action)
        _ -> Left FrameParticipants
    where
      dt = elapsedSeconds context
  observe _ Gardener state = SessionView exact presented
    where
      exact = observe Afterlight Gardener (simulationWorld state)
      prior = previousTickEye state
      alpha = interpolation (simulationClock state)
      presented
        | Garden.distance prior (sceneEye exact) > 3 = exact
        | otherwise = exact {sceneEye = Garden.plus (Garden.scale (1 - alpha) prior) (Garden.scale alpha (sceneEye exact))}

advanceFrame :: AcceptedFrame -> Simulation -> (Simulation, FrameEffects)
advanceFrame (AcceptedFrame boundary action) state =
  let (inputs, clock) = case frameMode boundary of
        Frozen -> ([], emptyClock)
        Advancing -> schedule (elapsedSeconds boundary) (sampledControls action) (simulationClock state)
      original = simulationWorld state
      world = if restartLost action && Garden.worldChapter original == Garden.Lost then restartWorld original else original
      step (current, batches) controls =
        let (pilot, resolved) = case frameDriver boundary of
              HumanDriver -> (simulationPilot current, controls)
              StoryDriver -> (simulationPilot current, Tour.tourInput (simulationWorld current))
              IslandDriver -> Tour.expeditionInput (simulationPilot current) (simulationWorld current)
            before = simulationWorld current
            -- Frame admission owns the participant protocol. Each scheduled
            -- sample runs the same tick Machine as the tick Arena, preserving
            -- the original rules without a second admission/fallback ruleset.
            (after, cues) = stepMachine Afterlight resolved before
            updated =
              current
                { currentWorld = after,
                  currentPilot = pilot,
                  previousTickEye = Garden.eye (Garden.worldPlayer before)
                }
         in (updated, cues : batches)
      seeded = state {currentWorld = world, simulationClock = clock}
      (next, reversed) = foldl' step (seeded, []) inputs
   in (next, FrameEffects (reverse reversed))
