module Main (main) where

import Control.Monad (forM_, unless)
import Game.Arena qualified as Arena
import Garden.Clock
import Garden.Host.Control
import Garden.Runtime.Control qualified as Control
import Garden.Session
import Garden.Types
import Garden.World (initialWorld)

check :: String -> Bool -> IO ()
check name passed = do
  unless passed (fail name)
  putStrLn ("PASS " <> name)

main :: IO ()
main = do
  clockExtremes
  clockEdges
  sessionContinuation
  modalScenarios
  modalParity

-- Observe a bounded prefix: this fails promptly on the original overflow,
-- whose second batch is effectively unbounded, rather than hanging the test.
clockExtremes :: IO ()
clockExtremes = do
  let admitted = fromIntegral (maxBound :: Int) / 120
      observations = take 4 (iterate (snd . schedule admitted idleInput) emptyClock)
      batches = map (take 9 . fst . schedule admitted idleInput) observations
  check "repeated admitted extreme durations stay within eight ticks" (map length batches == replicate 4 8)

clockEdges :: IO ()
clockEdges = do
  let first = idleInput {moveSide = 1, lookYaw = 1, jumpEdge = True, slotEdge = Just 2, dodgeEdge = True}
      second = idleInput {moveForward = -1, lookYaw = 1, lookPitch = 0.75, chargeEdge = True}
      latest = idleInput {moveSide = -1, moveForward = 1, lookYaw = 2, mineHeld = True, craftEdge = True, slotEdge = Just 4}
      (none1, clock1) = schedule 0.004 first emptyClock
      (none2, clock2) = schedule 0.004 second clock1
      (batch, clock3) = schedule 0.05 latest clock2
      expected = latest {lookYaw = 4 / 3, lookPitch = 0.25, jumpEdge = True, chargeEdge = True, dodgeEdge = True}
      held = expected {jumpEdge = False, chargeEdge = False, craftEdge = False, slotEdge = Nothing, dodgeEdge = False}
      (next, clock4) = schedule 0.01 idleInput clock3
      (negative, clock5) = schedule (-1) first clock4
      (queued, _) = schedule 0.0155 idleInput clock5
  check "zero-tick frames retain controls" (null none1 && null none2)
  check "latest held controls, combined look, and latest slot retain their order" (batch == [expected, held, held])
  check "fractional debt continues without replaying edges or look" (next == [idleInput])
  check "negative elapsed time adds no ticks and retains the new edge" (null negative && queued == [first {moveSide = 0}])

sessionContinuation :: IO ()
sessionContinuation = do
  let admitted = fromIntegral (maxBound :: Int) / 120
      initial = beginSimulation initialWorld
      play dt mode state = case Arena.play AfterlightSession (FrameBoundary dt mode HumanDriver) (frameChoices idleInput False) state of
        Left rejection -> fail ("Unexpected frame rejection: " <> show rejection)
        Right result -> pure result
  (first, FrameEffects firstCues) <- play admitted Advancing initial
  (second, FrameEffects secondCues) <- play admitted Advancing first
  (drained, FrameEffects drainCues) <- play 0 Advancing second
  (suspended, FrameEffects pauseCues) <- play 0 Frozen drained
  (resumed, FrameEffects resumeCues) <- play (1 / 60) Advancing suspended
  check "extreme-debt session continues, pauses, and resumes" $
    map length [firstCues, secondCues, drainCues, pauseCues, resumeCues] == [8, 8, 8, 0, 1]
      && worldTick (simulationWorld resumed) == Tick 25
  check "elapsed admission still rejects the original upper boundary" $
    Arena.play AfterlightSession (FrameBoundary (admitted * 2) Advancing HumanDriver) (frameChoices idleInput False) resumed == Left TooLargeElapsed

modalScenarios :: IO ()
modalScenarios = do
  let playing = Control.FrameContext Interactive True False False True
      noKeys = Control.FrameKeys False False False False
      pause = Control.FrameKeys True False False False
      photo = Control.FrameKeys False True False False
      enter = Control.FrameKeys False False True False
      expected = Control.FramePlan False Control.KeepPhoto False False Advancing True False
      scenario name context keys result = check name (Control.planFrame context keys == result)
  scenario "ordinary play accepts game input" playing noKeys expected
  scenario "focus loss pauses free play" (playing {Control.windowFocused = False}) noKeys $
    expected {Control.pausedAfter = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "bounded run does not auto-pause on focus loss" (playing {Control.windowFocused = False, Control.freePlay = False}) noKeys expected
  scenario "focus pause wins over Escape" (playing {Control.windowFocused = False, Control.pausedBefore = True}) pause $
    expected {Control.pausedAfter = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "closing pause freezes one frame while restoring audio" (playing {Control.pausedBefore = True}) pause $
    expected {Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "entering photo freezes the world without changing pause" playing photo $
    expected {Control.photoTransition = Control.EnterPhoto, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "photo entry takes precedence over Escape and focus loss" (playing {Control.windowFocused = False}) (photo {Control.escapePressed = True}) $
    expected {Control.photoTransition = Control.EnterPhoto, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "Enter in photo captures without exiting" (playing {Control.photoOpen = True}) enter $
    expected {Control.captureRequested = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "photo exit suppresses Enter capture and menu exit" (playing {Control.photoOpen = True, Control.pausedBefore = True}) (enter {Control.escapePressed = True}) $
    expected {Control.pausedAfter = True, Control.photoTransition = Control.LeavePhoto, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "F12 still captures on photo exit" (playing {Control.photoOpen = True}) (photo {Control.capturePressed = True}) $
    expected {Control.photoTransition = Control.LeavePhoto, Control.captureRequested = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "photo entry with Enter does not save and exit" (playing {Control.pausedBefore = True}) (photo {Control.enterPressed = True}) $
    expected {Control.pausedAfter = True, Control.photoTransition = Control.EnterPhoto, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False}
  scenario "paused Enter saves and exits" (playing {Control.pausedBefore = True}) enter $
    expected {Control.pausedAfter = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False, Control.saveAndExit = True}
  scenario "Escape and Enter can pause and save in one frame" playing (enter {Control.escapePressed = True}) $
    expected {Control.pausedAfter = True, Control.audioPaused = True, Control.simulationMode = Frozen, Control.acceptsGameInput = False, Control.saveAndExit = True}
  scenario "observer mode never polls game controls" (playing {Control.controlMode = ObserveOnly}) noKeys $
    expected {Control.acceptsGameInput = False}

-- Frozen host expressions from before this extraction. Authored scenarios
-- above fix the modal meaning; this exhaustive comparison covers all 512
-- combinations, including combinations the real observer never emits.
modalParity :: IO ()
modalParity = do
  let bools = [False, True]
      contexts = [Control.FrameContext mode focused paused photo free | mode <- [Interactive, ObserveOnly], focused <- bools, paused <- bools, photo <- bools, free <- bools]
      keys = [Control.FrameKeys escape photo enter capture | escape <- bools, photo <- bools, enter <- bools, capture <- bools]
  forM_ [(context, pressed) | context <- contexts, pressed <- keys] $ \(context, pressed) ->
    unless (Control.planFrame context pressed == originalDecision context pressed) $
      fail ("Modal precedence changed: " <> show (context, pressed))
  check "all 512 modal combinations match the previous host" (length contexts * length keys == 512)

originalDecision :: Control.FrameContext -> Control.FrameKeys -> Control.FramePlan
originalDecision context keys = Control.FramePlan paused transition capture frozen mode acceptsInput exit
  where
    wasPhoto = Control.photoOpen context
    photoExit = wasPhoto && (Control.photoPressed keys || Control.escapePressed keys)
    photoEnter = not wasPhoto && Control.photoPressed keys
    capture = Control.capturePressed keys || wasPhoto && Control.enterPressed keys && not photoExit
    paused = if wasPhoto || photoEnter then Control.pausedBefore context else if Control.controlMode context == Interactive && not (Control.windowFocused context) && Control.freePlay context then True else if Control.escapePressed keys then not (Control.pausedBefore context) else Control.pausedBefore context
    startingPhoto = if photoExit then False else if photoEnter then True else wasPhoto
    frozen = paused || startingPhoto || photoExit
    mode = if frozen || Control.escapePressed keys then Frozen else Advancing
    acceptsInput = not (Control.controlMode context == ObserveOnly || frozen || Control.escapePressed keys)
    exit = paused && Control.enterPressed keys && not wasPhoto && not photoEnter
    transition = if photoExit then Control.LeavePhoto else if photoEnter then Control.EnterPhoto else Control.KeepPhoto
