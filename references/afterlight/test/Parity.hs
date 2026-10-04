{-# LANGUAGE NamedFieldPuns #-}

module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString.Builder (toLazyByteString)
import Data.List (foldl')
import Data.Map.Strict qualified as M
import FRP.Yampa (embed)
import Game.Arena qualified as A
import Game.Transition qualified as T
import Garden.Arena
import Garden.Checkpoint qualified as Save
import Garden.Mesh qualified as Mesh
import Garden.Photo qualified as Photo
import Garden.Render.Settings qualified as Settings
import Garden.Session
import Garden.Signal (lightEnvelope)
import Garden.Soundscape qualified as Sound
import Garden.Tour qualified as Tour
import Garden.Types
import Garden.View
import Garden.World
import Original.Garden.Checkpoint qualified as OldSave
import Original.Garden.Clock qualified as OldClock
import Original.Garden.Mesh qualified as OldMesh
import Original.Garden.Photo qualified as OldPhoto
import Original.Garden.Render.Settings qualified as OldSettings
import Original.Garden.Rules qualified as OldRules
import Original.Garden.Signal qualified as OldSignal
import Original.Garden.Soundscape qualified as OldSound
import Original.Garden.Tour qualified as OldTour
import Original.Garden.View qualified as OldView
import Original.Garden.World qualified as OldWorld
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import Test.QuickCheck hiding (label, scale)
import Test.QuickCheck.Random (mkQCGen)

-- Independent copy of the original Runtime schedule/fold, using the pinned
-- oracle modules. Only immutable World/Input/Cue value types are shared.
data Legacy = Legacy World OldClock.Clock V3 Tour.Pilot deriving (Eq, Show)

type Frame = (FrameBoundary, FrameAction)

oldFrame :: Frame -> Legacy -> (Legacy, FrameEffects)
oldFrame (boundary, action) (Legacy before clock prior pilot) =
  let (inputs, nextClock) =
        if frameMode boundary == Frozen
          then ([], OldClock.emptyClock)
          else OldClock.schedule (elapsedSeconds boundary) (sampledControls action) clock
      world = if restartLost action && worldChapter before == Lost then OldWorld.restartWorld before else before
      tick (current, batches, _, currentPilot) input =
        let (nextPilot, resolved) = case frameDriver boundary of
              HumanDriver -> (currentPilot, input)
              StoryDriver -> (currentPilot, OldTour.tourInput current)
              IslandDriver ->
                let Tour.Pilot stop phase = currentPilot
                    (OldTour.Pilot nextStop nextPhase, controls) = OldTour.expeditionInput (OldTour.Pilot stop phase) current
                 in (Tour.Pilot nextStop nextPhase, controls)
            (advancedWorld, tickOutput) = OldRules.advance resolved current
         in (advancedWorld, batches <> [tickOutput], eye (worldPlayer current), nextPilot)
      (after, cues, oldEye, memory) = foldl' tick (world, [], prior, pilot) inputs
   in (Legacy after nextClock oldEye memory, FrameEffects cues)

oldView :: OldView.SceneView -> SceneView
oldView v =
  SceneView
    { sceneCells = OldView.sceneCells v,
      sceneRevision = OldView.sceneRevision v,
      sceneEdits = OldView.sceneEdits v,
      sceneEye = OldView.sceneEye v,
      sceneForward = OldView.sceneForward v,
      sceneFeet = OldView.sceneFeet v,
      sceneTime = OldView.sceneTime v,
      sceneVeil = OldView.sceneVeil v,
      sceneChapter = OldView.sceneChapter v,
      sceneLife = OldView.sceneLife v,
      sceneKin = [KinView p g b s | OldView.KinView p g b s <- OldView.sceneKin v],
      sceneEnemies = [EnemyView p h w k | OldView.EnemyView p h w k <- OldView.sceneEnemies v],
      sceneBursts = OldView.sceneBursts v,
      sceneTarget = target (OldView.sceneTarget v),
      sceneSlots = OldView.sceneSlots v,
      sceneSelection = OldView.sceneSelection v,
      sceneGems = OldView.sceneGems v,
      sceneCharges = OldView.sceneCharges v,
      sceneBonded = OldView.sceneBonded v,
      sceneSheltered = OldView.sceneSheltered v,
      sceneFlight = OldView.sceneFlight v,
      sceneObjective = OldView.sceneObjective v,
      sceneHint = OldView.sceneHint v,
      sceneNotice = OldView.sceneNotice v,
      sceneSpeed = OldView.sceneSpeed v,
      sceneDashRecovery = OldView.sceneDashRecovery v
    }
  where
    target OldView.NoTarget = NoTarget
    target OldView.EnemyTarget = EnemyTarget
    target (OldView.TerrainTarget c p m ready) = TerrainTarget c p m ready

legacyView :: Legacy -> SessionView
legacyView (Legacy world clock prior _) = SessionView exact presented
  where
    exact = oldView (OldView.project world)
    alpha = OldClock.interpolation clock
    presented =
      if distance prior (sceneEye exact) > 3
        then exact
        else exact {sceneEye = plus (scale (1 - alpha) prior) (scale alpha (sceneEye exact))}

seedLegacy :: World -> Legacy
seedLegacy world = Legacy world OldClock.emptyClock (eye (worldPlayer world)) (Tour.Pilot 0 0)

newFrame :: Frame -> Simulation -> Either FrameRejection (Simulation, FrameEffects)
newFrame (context, action) = A.play AfterlightSession context (A.singleton Gardener action)

matches :: Simulation -> Legacy -> Bool
matches current old@(Legacy world _ _ pilot) =
  simulationWorld current == world
    && simulationPilot current == pilot
    && A.observe AfterlightSession Gardener current == legacyView old

compareFrames :: [Frame] -> World -> Bool
compareFrames inputs initial = go (beginSimulation initial) (seedLegacy initial) inputs
  where
    go current old [] = matches current old
    go current old (input : rest) = case newFrame input current of
      Left _ -> False
      Right (next, output) ->
        let (expected, effects) = oldFrame input old
         in output == effects && matches next expected && go next expected rest

frame :: Double -> FrameMode -> Driver -> Input -> Bool -> Frame
frame dt mode driver controls restart = (FrameBoundary dt mode driver, FrameAction controls restart)

smallWorld :: World
smallWorld =
  initialWorld
    { worldCells = M.fromList [(Cell x 0 z, Pearl) | x <- [-9 .. 9], z <- [-9 .. 9]],
      worldPlayer = (worldPlayer initialWorld) {playerFeet = V3 0 1 0},
      worldKin = [],
      worldAdversaries = []
    }

controlsGen :: Gen Input
controlsGen = do
  side <- elements [-1, 0, 1]
  front <- elements [-1, 0, 1]
  yaw <- choose (-0.08, 0.08)
  pitch <- choose (-0.04, 0.04)
  switches <- vectorOf 11 (frequency [(4, pure False), (1, pure True)])
  selected <- frequency [(4, pure Nothing), (1, Just <$> choose (0, 11))]
  case switches of
    [j, held, down, sprint, mine, place, gift, charge, craft, night, dash] ->
      pure (Input side front yaw pitch j held down sprint mine place gift charge craft night selected dash)
    _ -> pure idleInput

frameProperty :: Property
frameProperty = forAll (resize 40 (listOf frameGen)) $ \inputs ->
  counterexample "full frame World/Cue/SceneView diverged" (compareFrames inputs smallWorld)
  where
    frameGen = do
      dt <- elements [0, 1 / 240, 1 / 120, 1 / 60, 1 / 30, 0.25]
      mode <- frequency [(7, pure Advancing), (1, pure Frozen)]
      controls <- controlsGen
      pure (frame dt mode HumanDriver controls False)

check :: String -> Bool -> IO ()
check label ok = if ok then putStrLn ("PASS " <> label) else putStrLn ("FAIL " <> label) >> exitFailure

crossSave :: String -> World -> IO ()
crossSave label world = do
  let bytes = Save.encode world
  check (label <> " checkpoint bytes") (bytes == OldSave.encode world)
  case (Save.decode (OldSave.encode world), OldSave.decode bytes) of
    (Right restored, Right oldRestored) -> do
      check (label <> " cross decode complete World") (restored == oldRestored)
      check
        (label <> " immediate reconstructed view")
        (A.observe Afterlight Gardener restored == oldView (OldView.project oldRestored))
      let inputs = [idleInput {moveSide = 1, lookYaw = 0.02}, idleInput {jumpEdge = True}, idleInput {mineHeld = True}]
      check
        (label <> " resumed trace")
        (T.firstDivergence (T.Step OldRules.advance) (T.machine Afterlight) (concat (replicate 10 inputs)) restored == Nothing)
    _ -> check (label <> " decode") False

tourRegression :: IO World
tourRegression = go (0 :: Int) (beginSimulation initialWorld) (seedLegacy OldWorld.initialWorld) ""
  where
    go count current old previousStage
      | count > 7000 = check "tour terminated within 7000 frames" False >> pure initialWorld
      | Tour.expeditionDone (simulationPilot current) = do
          let result = simulationWorld current
          check "story + four-island frame route completed" (worldRestored result && worldRevision result >= 10)
          putStrLn
            ( "ROUTE frames="
                <> show count
                <> " ticks="
                <> show (worldTick result)
                <> " revision="
                <> show (worldRevision result)
                <> " pilot="
                <> show (simulationPilot current)
            )
          crossSave "islands" result
          pure result
      | otherwise = do
          let dt = case count `mod` 6 of 0 -> 1 / 120; 1 -> 1 / 60; 2 -> 1 / 30; 3 -> 0; 4 -> 1 / 240; _ -> 1 / 10
              request = frame dt Advancing IslandDriver idleInput False
          case newFrame request current of
            Left _ -> check "tour admission" False >> pure initialWorld
            Right (next, output) -> do
              let (expected, effects) = oldFrame request old
                  stage = OldTour.tourStage (simulationWorld next) <> " " <> show (simulationPilot next)
              unless (output == effects && matches next expected) $
                check ("tour frame " <> show count) False
              if stage /= previousStage
                then do
                  putStrLn ("MILESTONE " <> stage <> " " <> show (worldTick (simulationWorld next)))
                  crossSave stage (simulationWorld next)
                else pure ()
              go (count + 1) next expected stage

photoParity :: Bool
photoParity = and [show current == show original | (current, original) <- take 1800 (iterate advance (first, oldFirst))]
  where
    first = Photo.beginPhoto (V3 3 8 (-2)) (V3 0 0 1)
    oldFirst = OldPhoto.beginPhoto (V3 3 8 (-2)) (V3 0 0 1)
    advance (p, old) =
      let i = Photo.PhotoInput (V3 35 9 15) (0.2, -0.1) 1 1 1 1 True True True True
          oi = OldPhoto.PhotoInput (V3 35 9 15) (0.2, -0.1) 1 1 1 1 True True True True
       in (Photo.stepPhoto 0.2 i p, OldPhoto.stepPhoto 0.2 oi old)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  check "entire authored terrain + initial World" (initialWorld == OldWorld.initialWorld)
  let cases =
        [ ( "zero-tick press survives release",
            smallWorld,
            [ frame 0.001 Advancing HumanDriver idleInput {jumpEdge = True} False,
              frame 0.001 Advancing HumanDriver idleInput False,
              frame 0.02 Advancing HumanDriver idleInput False
            ]
          ),
          ( "one-second stall drains all debt",
            smallWorld,
            frame 1 Advancing HumanDriver idleInput {lookYaw = 0.3, dodgeEdge = True} False
              : replicate 10 (frame 0 Advancing HumanDriver idleInput False)
          ),
          ( "pause/photo clears pending edge and time",
            smallWorld,
            [ frame 0.001 Advancing HumanDriver idleInput {jumpEdge = True} False,
              frame 10 Frozen HumanDriver idleInput False,
              frame (1 / 60) Advancing HumanDriver idleInput False
            ]
          ),
          ( "Lost restart even without a tick",
            initialWorld {worldChapter = Lost, worldLife = 0},
            [frame 0 Frozen HumanDriver idleInput True, frame (1 / 60) Advancing HumanDriver idleInput False]
          )
        ]
  forM_ cases $ \(name, world, inputs) -> check name (compareFrames inputs world)
  let initial = beginSimulation smallWorld
      badTime dt = A.attempt AfterlightSession (FrameBoundary dt Advancing HumanDriver) (frameChoices idleInput False) initial
  check "nonfinite time rejects and preserves state" (badTime (0 / 0) == A.Rejected NonFiniteElapsed initial && badTime (1 / 0) == A.Rejected NonFiniteElapsed initial)
  check "out-of-range time rejects before floor" (badTime 1e100 == A.Rejected TooLargeElapsed initial)
  check "duplicate gardener cannot construct Joint" (A.joint [(Gardener, idleInput), (Gardener, idleInput)] == Left (A.DuplicateParticipant Gardener))
  check "nobody is a legal idle tick" (A.play Afterlight FixedTick A.nobody smallWorld == Right (OldRules.advance idleInput smallWorld))
  check "tick Arena.play uses original rules" (A.play Afterlight FixedTick (tickChoices idleInput {jumpEdge = True}) smallWorld == Right (OldRules.advance idleInput {jumpEdge = True} smallWorld))
  let controls = [idleInput {jumpEdge = True}, idleInput, idleInput {moveForward = 1}]
      reference = T.Step OldRules.advance
      mutant = T.Step (\input world -> let (next, cues) = OldRules.advance input world in (next, reverse (Mine : cues)))
  check "shared trace preserves complete tick boundaries" (T.firstDivergence reference (T.machine Afterlight) controls smallWorld == Nothing)
  check "differential detects altered cue ordering" (case T.firstDivergence reference mutant controls smallWorld of Just d -> T.boundaryIndex d == 0; _ -> False)
  let frameInputs =
        [ frame 0.001 Advancing HumanDriver idleInput {craftEdge = True} False,
          frame (1 / 30) Advancing HumanDriver idleInput False
        ]
  accepted <-
    either (\problem -> print problem >> exitFailure) pure $
      traverse (\(context, action) -> A.admit AfterlightSession context (A.singleton Gardener action) initial) frameInputs
  check
    "shared frame trace includes zero-tick and two-tick batches"
    (map (length . tickCues . T.emitted) (T.trace (T.machine AfterlightSession) accepted initial) == [0, 2])
  generated <- quickCheckWithResult stdArgs {maxSuccess = 160, maxSize = 40, replay = Just (mkQCGen 20261003, 0)} frameProperty
  unless (isSuccess generated) exitFailure
  legacy <- readFile "tools/fixtures/garden-v3.txt"
  check "v3 fixture decoded by both codecs" (case (Save.decode legacy, OldSave.decode legacy) of (Right a, Right b) -> a == b; _ -> False)
  forM_ ["", "Checkpoint 2 [", take 30 (Save.encode initialWorld), Save.encode initialWorld <> " invalid"] $ \bad ->
    check "malformed/truncated checkpoint admission agrees" (show (Save.decode bad) == show (OldSave.decode bad))
  crossSave "edited/deleted terrain" (editCell (Cell 9 30 9) (Just Gold) (editCell (Cell 0 3 (-30)) Nothing initialWorld))
  check "photo movement/lens/grade/toggles/clamps" photoParity
  forM_ [(Settings.FullQuality, OldSettings.FullQuality), (Settings.BalancedQuality, OldSettings.BalancedQuality), (Settings.LightQuality, OldSettings.LightQuality)] $ \(quality, oldQuality) ->
    forM_ [(1280, 720), (1367, 769), (701, 1001), (1, 1), (10000, 9000)] $ \size ->
      check
        ("render plan " <> show quality <> " " <> show size)
        (show (Settings.renderPlan size (Settings.preset quality)) == show (OldSettings.renderPlan size (OldSettings.preset oldQuality)))
  let cells = M.fromList (zip [Cell n 0 0 | n <- [0 .. 11]] hotbar)
  check "terrain mesh attributes and ordering" (show (Mesh.terrainGeometry cells (M.toList cells)) == show (OldMesh.terrainGeometry cells (M.toList cells)))
  check "ornament geometry" (show (Mesh.ornamentGeometry cells (M.toList cells)) == show (OldMesh.ornamentGeometry cells (M.toList cells)))
  let cues = [Mine, Jewel, Build, Offering, Wound, Jump, Strike, Dusk, Wings, Return, Dash]
  forM_ cues $ \cue ->
    check
      ("full PCM WAV " <> show cue)
      ( Sound.cueLength cue == OldSound.cueLength cue
          && toLazyByteString (Sound.wave (Sound.cueLength cue) (Sound.cueSignal cue))
            == toLazyByteString (OldSound.wave (OldSound.cueLength cue) (OldSound.cueSignal cue))
      )
  forM_ [(Sound.Sunlit, OldSound.Sunlit), (Sound.Veiled, OldSound.Veiled)] $ \(mood, oldMood) ->
    check
      ("day/night samples " <> show mood)
      (and [Sound.ambience mood channel t == OldSound.ambience oldMood channel t | channel <- [0, 1], t <- [0, 0.01 .. 48]])
  let signalInputs = [([], [(1 / 60, Just cs) | cs <- [[Offering], [], [], [Wings], [], [Return], []]])]
  check "Yampa light envelope per-tick output" (all (\input -> embed lightEnvelope input == embed OldSignal.lightEnvelope input) signalInputs)
  _ <- tourRegression
  putStrLn "All full Afterlight parity checks passed."
