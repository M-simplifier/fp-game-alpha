module Main (main) where

import Control.Monad (unless)
import Data.List (foldl')
import Game.Arena (Attempt (..), attempt, nobody, observe, play)
import Game.Transition (Divergence (..), Step (..), firstDivergence, replay)
import Garden.Adapter
import Garden.Clock qualified as Clock
import Garden.Input qualified as Input
import Garden.Session qualified as Session
import Garden.Simulation qualified as Simulation
import Garden.View qualified as View
import Garden.World qualified as World
import System.Exit (exitFailure)

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

eventArenaReplay ::
  [Session.Event] ->
  Session.Session ->
  Either ProtocolError (Session.Session, [Simulation.Effect])
eventArenaReplay inputs start = foldl' advance (Right (start, [])) inputs
  where
    advance previous input = do
      (session, prior) <- previous
      let (boundary, actions) = splitGarden input
      (next, effects) <- play GardenArena boundary actions session
      pure (next, prior ++ effects)

frameArenaReplay ::
  [GardenFrame] ->
  (Session.Session, Clock.Clock) ->
  Either ProtocolError ((Session.Session, Clock.Clock), [Simulation.Effect])
frameArenaReplay inputs start = foldl' advance (Right (start, [])) inputs
  where
    advance previous input = do
      (state, prior) <- previous
      let (elapsed, actions) = splitGardenFrame input
      (next, effects) <- play GardenClockArena elapsed actions state
      pure (next, prior ++ effects)

main :: IO ()
main = do
  let seed = World.seedFromText "alpha-garden"
      start = Session.newSession seed
      seedWorld = Session.sessionWorld start
  check "finite coordinates reject edges" $
    World.coord (-1) 0 == Nothing
      && World.coord World.width 0 == Nothing
      && World.coord 0 World.height == Nothing
  check "extreme screen pixels cannot wrap into the board" $
    Input.screenCoord (minBound :: Int) View.boardY == Nothing
      && Input.screenCoord (maxBound :: Int) View.boardY == Nothing
      && Input.screenCoord View.boardX View.boardY == World.coord 0 0
  check "same seed gives the same immutable world" $
    seedWorld == World.initialWorld seed
  let eventTrace =
        [ Session.Input Session.TogglePause,
          Session.Tick,
          Session.Input (Session.Select World.SowSeed),
          Session.Tick,
          Session.Input Session.TogglePause,
          Session.Input Session.StepOnce,
          Session.Input Session.ResetSameSeed
        ]
      direct = Session.applyEvents eventTrace start
  check "event Step replays original authoritative rule" $
    replay garden eventTrace start == direct
  check "event Arena admits exactly that rule" $
    eventArenaReplay eventTrace start == Right direct
  check "wrong event protocol rejects without state change" $
    attempt GardenArena PlayerBoundary nobody start == Rejected WrongBoundary start
  let ignoreTick = Step $ \event session -> case event of
        Session.Tick -> (session, [] :: [Simulation.Effect])
        _ -> Session.advance event session
  check "deleting ticks diverges at boundary one" $
    fmap boundaryIndex (firstDivergence garden ignoreTick eventTrace start) == Just 1
  let (resetSession, _) = direct
  check "reset reuses seed and pauses" $
    Session.sessionWorld resetSession == seedWorld && Session.isPaused resetSession
  check "view is derived from the session" $
    observe GardenArena Gardener resetSession == View.project resetSession
      && View.shownFingerprint (View.project resetSession) == World.fingerprint seedWorld
  let (running, _) = Session.advance (Session.Input Session.TogglePause) start
      (fiveTicks, debt, _) = Clock.frame 600000 [] running Clock.emptyClock
      (sixTicks, drained, _) = Clock.frame 0 [] fiveTicks debt
  check "scheduler caps at five and carries exact debt" $
    World.worldTick (Session.sessionWorld fiveTicks) == 5
      && Clock.debtMicros debt == 100000
      && World.worldTick (Session.sessionWorld sixTicks) == 6
      && Clock.debtMicros drained == 0
  let (paused, clearedDebt, _) = Clock.frame 900000 [Session.TogglePause] sixTicks drained
      (resumed, resumedDebt, _) = Clock.frame 900000 [Session.TogglePause] paused clearedDebt
      (negativeElapsed, _, _) = Clock.frame (-100) [] resumed resumedDebt
  check "pause/resume clear debt and negative time is zero" $
    Session.isPaused paused
      && not (Session.isPaused resumed)
      && Clock.debtMicros clearedDebt == 0
      && Clock.debtMicros resumedDebt == 0
      && World.worldTick (Session.sessionWorld negativeElapsed) == 6
  let frames =
        [ GardenFrame (ElapsedMicros 0) [Session.TogglePause],
          GardenFrame (ElapsedMicros 100000) [],
          GardenFrame (ElapsedMicros 0) [Session.Select World.SowSeed],
          GardenFrame (ElapsedMicros 200000) [],
          GardenFrame (ElapsedMicros 0) [Session.TogglePause]
        ]
      frameStart = (start, Clock.emptyClock)
      frameDirect = foldl' step (frameStart, []) frames
      step ((session, clock), prior) (GardenFrame (ElapsedMicros elapsed) commands) =
        let (next, nextClock, effects) = Clock.frame elapsed commands session clock
         in ((next, nextClock), prior ++ effects)
  check "clock Step and Arena preserve scheduler outcomes" $
    replay gardenClock frames frameStart == frameDirect
      && frameArenaReplay frames frameStart == Right frameDirect
  check "splitting at a control edge changes scheduling" $
    replay gardenClock [GardenFrame (ElapsedMicros 100000) [Session.TogglePause]] (running, Clock.emptyClock)
      /= replay
        gardenClock
        [ GardenFrame (ElapsedMicros 100000) [],
          GardenFrame (ElapsedMicros 0) [Session.TogglePause]
        ]
        (running, Clock.emptyClock)
  putStrLn "garden-laws: PASS (seed/reset, event and clock arenas, 5-tick debt, pause, input bounds, mutation)"
