{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}

module Garden.Runtime
#if defined(AFTERLIGHT_GAMEIO)
  (runGarden)
#else
  ( GardenApp,
    RenderQuality (..),
    StartupStage (..),
    startupProgress,
    gardenReady,
    beginGarden,
    previewGarden,
    setGardenActive,
    setGardenQuality,
    setGardenRenderOption,
    startupGarden,
    stepGarden,
    shouldCloseGarden,
    shutdownGarden,
    runGarden,
  )
#endif
where

#if defined(AFTERLIGHT_GAMEIO)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, evaluate, finally, mask_, try)
import Data.ByteString qualified as BS
import Data.Maybe (catMaybes, isJust)
import Data.Word (Word32)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (gc, gcdetails_live_bytes, getRTSStats, getRTSStatsEnabled, max_live_bytes)
import GameIO.Graphics qualified as GPU
import GameIO.Image (encodePng, rgbaImage)
import GameIO.Platform
import GameIO.Platform.Borderless (withBorderlessToggle)
import GameIO.Text.Render (AtlasTexture)
import Garden.Input.Native
import Garden.Render.HUD qualified as HUD
import Garden.Render.Native
import Garden.Render.NativeHUD
#else
import Control.Exception (IOException, bracket, bracketOnError, evaluate, finally, mask, mask_, onException, try)
import Data.Maybe (isJust)
import Garden.Input
import Garden.Render
import Garden.Render.Resources
import Raylib.Core
import Raylib.Core.Audio (closeAudioDevice)
import Raylib.Core.Text (drawText)
import Raylib.Types
import Raylib.Util (WindowResources, drawing)
#endif
import Control.Monad (replicateM_, unless, void, when)
import Data.IORef
import Data.List (sort)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import FRP.Yampa (ReactHandle, react, reactInit)
import Game.Arena qualified as Arena
import Garden.Arena (Afterlight (..), Gardener (..))
import Garden.Audio
import Garden.Checkpoint
import Garden.Host.Control
import Garden.Photo
import Garden.Render.Settings
import Garden.Rules
import Garden.Runtime.Control qualified as Control
import Garden.Session
import Garden.Signal
import Garden.Tour qualified as Tour
import Garden.Types
import Garden.View
import Garden.World
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory)
#if !defined(wasm32_HOST_ARCH)
import System.Mem (performMajorGC)
#endif
import Text.Printf (printf)
import Text.Read (readMaybe)

data Host = Host {hostPaused :: Bool, hostHidden :: Bool, hostDebug :: Bool, hostInvert :: Bool, hostSaved :: Maybe Bool, hostRecordUntil :: Double, hostPhoto :: Maybe Photo, hostPhotoMessage :: Maybe String, hostPhotoUntil :: Double}

data Timing = Timing !Int !Float !Double !Double !Double !Double !Double !Double !Double !(Maybe (Double, RenderTiming))

data RenderTiming = RenderTiming !Double !Double !Double !Double !Double !(Maybe Double)

data LightSignal = LightSignal !(ReactHandle [Cue] Float) !(IORef Float)

-- Host resources and run options have one lifetime, separate from simulation.
data Session = Session Resources AudioAssets LightSignal (IORef [Timing]) (Maybe Int) (Maybe Int) FilePath (Maybe String) !ControlMode !(IORef Bool)

data FrameState = FrameState !Simulation !Host !Int !Double

data RunOptions = RunOptions
  { optionScene :: Maybe String,
    optionFrameLimit :: Maybe Int,
    optionShotFrame :: Maybe Int,
    optionShotName :: FilePath,
    optionTour :: Maybe String,
    optionPaused :: Bool,
    optionHidden :: Bool,
    optionControl :: ControlMode
  }

readRunOptions :: IO (RunOptions, Int, Int)
readRunOptions = do
  scene <- lookupEnv "GARDEN_SCENE"
  frameLimit <- readEnv "GARDEN_FRAMES"
  shotFrame <- readEnv "GARDEN_SHOT"
  shotName <- maybe ".runtime/garden/screenshots/current.png" id <$> lookupEnv "GARDEN_IMAGE"
  tour <- lookupEnv "GARDEN_TOUR"
#if defined(wasm32_HOST_ARCH)
  width <- maybe 1600 (max 1) <$> readEnv "GARDEN_WIDTH"
  height <- maybe 900 (max 1) <$> readEnv "GARDEN_HEIGHT"
#else
  width <- maybe 1600 (max 960) <$> readEnv "GARDEN_WIDTH"
  height <- maybe 900 (max 600) <$> readEnv "GARDEN_HEIGHT"
#endif
  pausedAtStart <- (== Just "1") <$> lookupEnv "GARDEN_PAUSED"
  hiddenAtStart <- (== Just "0") <$> lookupEnv "GARDEN_HUD"
  requestedControl <- lookupEnv "GARDEN_INPUT"
  control <- either (ioError . userError) pure (controlMode requestedControl (any isJust [frameLimit, shotFrame] || isJust tour))
  pure (RunOptions scene frameLimit shotFrame shotName tour pausedAtStart hiddenAtStart control, width, height)

loadWorldFor :: RunOptions -> IO (World, SceneView)
loadWorldFor options = do
  began <- clockTime
  source <- if optionControl options == ObserveOnly then pure initialWorld else loadSaved
  world <- evaluate (chooseScene (optionScene options) source)
  view <- evaluate (Arena.observe Afterlight Gardener world)
  reportStartup "world" began
  pure (world, view)

startSession :: Resources -> AudioAssets -> RunOptions -> IORef Bool -> World -> IO (Session, FrameState)
startSession resources audio options pointer world = do
  start <- clockTime
  timings <- newIORef []
  glow <- newIORef 0
  handle <- reactInit (pure []) (\_ _ value -> writeIORef glow value >> pure False) lightEnvelope
  let initialHost = Host (optionPaused options) (optionHidden options) False False Nothing 0 Nothing Nothing 0
      session = Session resources audio (LightSignal handle glow) timings (optionFrameLimit options) (optionShotFrame options) (optionShotName options) (optionTour options) (optionControl options) pointer
  putStrLn ("garden input=" <> show (optionControl options))
  pure (session, FrameState (beginSimulation world) initialHost 0 start)

reportStartup :: String -> Double -> IO ()
reportStartup label began = do
  now <- clockTime
  putStrLn (printf "garden startup %s_ms=%.2f" label ((now - began) * 1000))

#if defined(AFTERLIGHT_GAMEIO)
type KeyboardKey = Word32

data Resources = Resources
  { resourceWindow :: !Window
  , resourceQuality :: !(IORef RenderSettings)
  , resourceInput :: !NativeInput
  , resourceScene :: !NativeScene
  , resourceFont :: !AtlasTexture
  , toggleBorderless :: IO ()
  }

runGarden :: IO ()
runGarden = do
  createDirectoryIfMissing True ".runtime/garden/screenshots"
  ensureAudio
  (options, width, height) <- readRunOptions
  sampleHeap <- startupHeapProbe
  audioMetrics <- (== Just "1") <$> lookupEnv "GARDEN_AUDIO_METRICS"
  sampleHeap "initial"
  let mode = optionControl options
  withWindowVisibility (mode == Interactive) (WindowConfig "NOEMA - Garden of Afterlight" width height) $ \window -> do
    setWindowMinimumSize window 960 600
    withBorderlessToggle window $ \toggle ->
      bracket loadAudioAssets shutdownAudio $ \audio -> do
        sampleHeap "audio"
        began <- clockTime
        (world, view) <- loadWorldFor options
        sampleHeap "world"
        resourcesBegan <- clockTime
        input <- newNativeInput
        quality <- newIORef =<< desktopSettings
        withNativeScene window $ \scene -> do
          sampleHeap "shaders"
          withNativeHUD (nativeSceneRenderer scene) $ \font -> do
            sampleHeap "font"
            let resources = Resources window quality input scene font toggle
            reportStartup "resources" resourcesBegan
            chunksBegan <- clockTime
            pending <- beginNativeChunkLoading scene view
            sampleHeap "grouped"
            ready <- loadChunks resources pending
            when ready $ do
              sampleHeap "uploaded"
              reportStartup "chunks" chunksBegan
              warmupBegan <- clockTime
              replicateM_ 6 $ do
                when (mode == Interactive) (updateAudio audio (worldVeil world) False)
                void (drawFrame resources view Nothing 0 (WorldChrome (Just (False, 120)) Nothing Nothing Nothing) False)
              performMajorGC
              sampleHeap "warm"
              initial <- pollInputSample input window
              unless (inputClose initial) $ do
                pointer <- newIORef False
                applyPointer resources mode pointer (wantsPointer mode (inputFocused initial) (optionPaused options) False)
                (session, state) <- startSession resources audio options pointer world
                reportStartup "preview" warmupBegan
                reportStartup "total" began
                (do
                    loop session state
                    when audioMetrics (putStrLn . ("garden audio " <>) . show =<< audioSnapshot audio)
                    sampleHeap "finished"
                  ) `finally` (applyPointer resources mode pointer False `finally` logSessionTiming session)
  where
    loop session state = stepFrame session state >>= mapM_ (loop session)
    loadChunks resources pending = do
      event <- pollInputSample (resourceInput resources) (resourceWindow resources)
      if inputClose event then pure False else do
        progress <- nativeChunkLoadingProgress pending
        drawLoading (resourceWindow resources) (nativeSceneRenderer (resourceScene resources)) (resourceFont resources) (Just progress)
        done <- stepNativeChunkLoading 0.012 pending
        if done then pure True else loadChunks resources pending

desktopSettings :: IO RenderSettings
desktopSettings = do
  overrides <- mapM (\(key, env) -> fmap ((key,) <$>) (lookupEnv env))
    [("quality", "GARDEN_QUALITY"), ("scale", "GARDEN_SCALE"), ("shadows", "GARDEN_SHADOWS"), ("clouds", "GARDEN_CLOUDS"), ("ao", "GARDEN_AO"), ("bloom", "GARDEN_BLOOM")]
  either (ioError . userError) pure (parseSettings (catMaybes overrides))

startupHeapProbe :: IO (String -> IO ())
startupHeapProbe = do
  requested <- (== Just "1") <$> lookupEnv "GARDEN_STARTUP_HEAP"
  if not requested then pure (const (pure ())) else do
    enabled <- getRTSStatsEnabled
    unless enabled (ioError (userError "GARDEN_STARTUP_HEAP requires +RTS -T"))
    pure $ \stage -> do
      performMajorGC
      stats <- getRTSStats
      putStrLn (printf "garden heap %s live_bytes=%d peak_live_bytes=%d" stage (gcdetails_live_bytes (gc stats)) (max_live_bytes stats))

clockTime :: IO Double
clockTime = (/ 1e9) . fromIntegral <$> getMonotonicTimeNSec
#else
clockTime :: IO Double
clockTime = getTime

data Startup = Startup !WindowResources !AudioAssets !RunOptions !Double

data Preparation
  = LoadWorld !Startup
  | LoadResources !Startup !World !SceneView
  | LoadChunks !Startup !Resources !World !SceneView !ChunkLoading !Double
  | Warmup !Startup !Resources !World !SceneView

data StartupStage = ReadyStage | WorldStage | ResourcesStage | ChunksStage | WarmupStage
  deriving (Eq, Enum)

data AppState = Loading !Preparation | Running !Session !FrameState | Finished !Session | Released

-- A single render thread owns this handle. Each callback returns after one
-- frame; the simulation clock and FRP continuation survive between callbacks.
newtype GardenApp = GardenApp (IORef AppState)

runGarden :: IO ()
runGarden = bracket startupGarden shutdownGarden loop
  where
    loop app = do
      stepGarden app
      close <- shouldCloseGarden app
      unless close (loop app)

-- | Native convenience wrapper. Browser hosts use 'beginGarden' and advance
-- preparation with 'stepGarden', returning to their event loop each time.
startupGarden :: IO GardenApp
startupGarden = bracketOnError beginGarden shutdownGarden $ \app -> do
  let prepare = do
        ready <- gardenReady app
        unless ready (stepGarden app >> prepare)
  prepare
  pure app

-- | Acquire only the window and audio host. World construction and uploads are
-- deferred to callbacks. This does not require a browser activation gesture;
-- the browser resumes its suspended AudioContext on the later play click.
-- CPP branches are formatted by scripts/check-cpp-format.py.
{- ORMOLU_DISABLE -}
beginGarden :: IO GardenApp
beginGarden = do
  createDirectoryIfMissing True ".runtime/garden/screenshots"
  ensureAudio
  (options, width, height) <- readRunOptions
  let control = optionControl options
#if defined(wasm32_HOST_ARCH)
  -- CSS fits this drawing buffer to the page; GLFW's window-resize callback
  -- otherwise replaces the requested resolution with the whole browser size.
  setConfigFlags [Msaa4xHint]
#else
  setConfigFlags ([Msaa4xHint, WindowResizable] <> if control == ObserveOnly then [WindowHidden, WindowUnfocused, WindowAlwaysRun] else [])
#endif
  bracketOnError (initWindow width height "NOEMA - Garden of Afterlight") (closeWindow . Just) $ \window -> do
#if defined(wasm32_HOST_ARCH)
    -- requestAnimationFrame owns pacing; a browser callback must return.
    setTargetFPS 0
#else
    setTargetFPS 120
    setWindowMinSize 960 600
#endif
    setExitKey KeyNull
    drawing $ clearBackground (Color 14 36 43 255) >> drawText "NOEMA / GARDEN OF AFTERLIGHT" 55 60 28 (Color 232 230 204 255) >> drawText "Growing the voxel garden..." 57 113 20 (Color 171 210 192 255)
    bracketOnError
      (acquireGardenAudio window)
      (releaseGardenAudio window)
      $ \audio -> do
        began <- getTime
        state <- newIORef (Loading (LoadWorld (Startup window audio options began)))
        pure (GardenApp state)

{- ORMOLU_ENABLE -}

acquireGardenAudio :: WindowResources -> IO AudioAssets
releaseGardenAudio :: WindowResources -> AudioAssets -> IO ()
acquireGardenAudio window = loadAudioAssets window `onException` closeAudioDevice (Just window)
releaseGardenAudio = shutdownAudio

-- | Real completed work, not a synthetic percentage. Stage changes delimit
-- world creation, common resources, chunk uploads, and the preview frame.
startupProgress :: GardenApp -> IO (StartupStage, Int, Int)
startupProgress (GardenApp stateRef) = do
  state <- readIORef stateRef
  case state of
    Loading (LoadWorld _) -> pure (WorldStage, 0, 1)
    Loading (LoadResources _ _ _) -> pure (ResourcesStage, 0, 1)
    Loading (LoadChunks _ _ _ _ pending _) -> do
      (done, total) <- chunkLoadingProgress pending
      pure (ChunksStage, done, total)
    Loading (Warmup _ _ _ _) -> pure (WarmupStage, 0, 1)
    _ -> pure (ReadyStage, 1, 1)

gardenReady :: GardenApp -> IO Bool
gardenReady (GardenApp stateRef) = do
  state <- readIORef stateRef
  pure $ case state of
    Running _ _ -> True
    Finished _ -> True
    _ -> False

-- CPP branches are formatted by scripts/check-cpp-format.py.
{- ORMOLU_DISABLE -}
advancePreparation :: Preparation -> IO AppState
advancePreparation (LoadWorld startup@(Startup _ _ options _)) = do
  (world, view) <- loadWorldFor options
  pure (Loading (LoadResources startup world view))
advancePreparation (LoadResources startup@(Startup window _ _ _) world view) = do
  began <- getTime
  bracketOnError (acquireResources window) releaseResources $ \resources -> do
    pending <- beginChunkLoading resources view
    reportStartup "resources" began
    chunksBegan <- getTime
    pure (Loading (LoadChunks startup resources world view pending chunksBegan))
advancePreparation preparation@(LoadChunks startup resources world view pending began) = do
  complete <- stepChunkLoading 0.012 pending
  if complete
    then reportStartup "chunks" began >> pure (Loading (Warmup startup resources world view))
    else pure (Loading preparation)
advancePreparation (Warmup (Startup _ audio options began) resources world view) = do
  warmupBegan <- getTime
  -- A single browser preview primes the same full-quality shaders. Repeated
  -- identical frames delay first play without presenting additional feedback.
#if defined(wasm32_HOST_ARCH)
  let warmupFrames = 1
#else
  let warmupFrames = 6
#endif
  replicateM_ warmupFrames $ do
    when (optionControl options == Interactive) (updateAudio audio (worldVeil world) False)
    drawing $ renderScene resources view 0 >> renderInterface resources view False 120
#if !defined(wasm32_HOST_ARCH)
  performMajorGC
#endif
  pointer <- newIORef False
  focused <- isWindowFocused
  applyPointer resources (optionControl options) pointer (wantsPointer (optionControl options) focused (optionPaused options) False)
  (session, frame) <- startSession resources audio options pointer world
  reportStartup "preview" warmupBegan
  reportStartup "total" began
  pure (Running session frame)

{- ORMOLU_ENABLE -}

-- | Run at most one frame. A completed or released application is a no-op.
stepGarden :: GardenApp -> IO ()
stepGarden (GardenApp stateRef) = mask $ \restore -> do
  state <- readIORef stateRef
  case state of
    Loading preparation -> do
      -- Newly acquired Resources must become owned by the app before an async
      -- exception can escape. Other phases already have all resources owned.
      next <- case preparation of
        LoadResources _ _ _ -> advancePreparation preparation
        _ -> restore (advancePreparation preparation)
      writeIORef stateRef next
    Running session frame -> do
      next <- restore (stepFrame session frame)
      writeIORef stateRef (maybe (Finished session) (Running session) next)
    Finished _ -> pure ()
    Released -> pure ()

-- | Redraw a ready preview after a host resize without consuming input,
-- advancing simulation, updating audio, or changing the application state.
previewGarden :: GardenApp -> IO ()
previewGarden (GardenApp stateRef) = do
  state <- readIORef stateRef
  case state of
    Running (Session resources _ _ _ _ _ _ _ _ _) (FrameState simulation _ _ _) -> do
      let view = exactScene (Arena.observe AfterlightSession Gardener simulation)
      drawing $ renderScene resources view 0 >> renderInterface resources view False 120
    _ -> pure ()

-- | Presentation-only preference. Apply after resource acquisition and before
-- warmup to include it in the first preview; earlier calls are a no-op.
setGardenQuality :: GardenApp -> RenderQuality -> IO ()
setGardenQuality app quality = void (changeSettings app (const (Right (preset quality))))

setGardenRenderOption :: GardenApp -> String -> String -> IO Bool
setGardenRenderOption app key value = changeSettings app (setOption key value)

changeSettings :: GardenApp -> (RenderSettings -> Either String RenderSettings) -> IO Bool
changeSettings (GardenApp stateRef) change = do
  state <- readIORef stateRef
  case state of
    Loading (LoadChunks _ resources _ _ _ _) -> apply resources
    Loading (Warmup _ resources _ _) -> apply resources
    Running (Session resources _ _ _ _ _ _ _ _ _) _ -> apply resources
    _ -> pure False
  where
    apply resources = do
      previous <- readIORef (resourceQuality resources)
      case change previous of
        Left message -> putStrLn message >> pure False
        Right settings -> writeIORef (resourceQuality resources) settings >> pure True

-- | A browser activation changes only host control. Preserve the photo camera
-- and world, and discard elapsed loading/background time before resuming.
setGardenActive :: GardenApp -> Bool -> IO ()
setGardenActive (GardenApp stateRef) active = mask_ $ do
  state <- readIORef stateRef
  case state of
    Running session (FrameState simulation host frame _) -> do
      let Session resources _ _ _ _ _ _ _ control pointer = session
      focused <- isWindowFocused
      applyPointer resources control pointer (wantsPointer control focused (not active) False)
      now <- getTime
      writeIORef stateRef (Running session (FrameState (suspendSimulation simulation) (host {hostPaused = not active}) frame now))
    _ -> pure ()

-- | True after a frame has handled a close request, tour completion, frame
-- limit, or successful save-and-exit. This query does not poll input twice.
shouldCloseGarden :: GardenApp -> IO Bool
shouldCloseGarden (GardenApp stateRef) = do
  state <- readIORef stateRef
  pure $ case state of
    Loading _ -> False
    Running _ _ -> False
    Finished _ -> True
    Released -> True

-- | Release a session once. Hosts must stop scheduling frames before calling.
shutdownGarden :: GardenApp -> IO ()
shutdownGarden (GardenApp stateRef) = mask_ $ do
  state <- atomicModifyIORef' stateRef (\old -> (Released, old))
  case state of
    Released -> pure ()
    Loading preparation -> case preparation of
      LoadWorld startup -> releaseStartup startup Nothing
      LoadResources startup _ _ -> releaseStartup startup Nothing
      LoadChunks startup resources _ _ _ _ -> releaseStartup startup (Just resources)
      Warmup startup resources _ _ -> releaseStartup startup (Just resources)
    Running session _ -> releaseSession session
    Finished session -> releaseSession session

releaseStartup :: Startup -> Maybe Resources -> IO ()
releaseStartup (Startup window audio options _) resources =
  when (optionControl options == Interactive) enableCursor
    `finally` releaseGardenAudio window audio
    `finally` mapM_ releaseResources resources
    `finally` closeWindow (Just window)

releaseSession :: Session -> IO ()
releaseSession session@(Session resources audio _ _ _ _ _ _ control pointer) =
  let window = resourceWindow resources
   in applyPointer resources control pointer False
        `finally` releaseGardenAudio window audio
        `finally` logSessionTiming session
        `finally` releaseResources resources
        `finally` closeWindow (Just window)
#endif

logSessionTiming :: Session -> IO ()
logSessionTiming (Session _ _ _ timingRef _ _ _ _ _ _) = do
  rows <- reverse <$> readIORef timingRef
  unless (null rows) (writeTiming rows)

data FrameSource = FrameSource
  { frameTime :: !Double
  , frameClosing :: !Bool
  , frameCaptureLost :: !Bool
  , readFramePresses :: IO [KeyboardKey]
  , readFrameFocus :: IO Bool
  , readFramePhoto :: [KeyboardKey] -> IO PhotoInput
  , readFrameGame :: Bool -> Int -> [KeyboardKey] -> IO Input
  }

data FrameChrome
  = NoChrome
  | PhotoChrome !Photo !(Maybe String)
  | WorldChrome !(Maybe (Bool, Float)) !(Maybe Bool) !(Maybe (Maybe Bool, Bool)) !(Maybe String)

data DrawResult = DrawResult !Double !Double !Double !(Maybe RenderTiming) (FilePath -> IO ())

#if defined(AFTERLIGHT_GAMEIO)
frameSource :: Resources -> ControlMode -> IO FrameSource
frameSource resources mode = do
  sample <- pollInputSample (resourceInput resources) (resourceWindow resources)
  pure FrameSource
    { frameTime = inputTime sample
    , frameClosing = inputClose sample
    , frameCaptureLost = captureInterrupted sample
    , readFramePresses = pure (if mode == Interactive then inputPresses sample else [])
    , readFrameFocus = pure (inputFocused sample && not (focusInterrupted sample))
    , readFramePhoto = \_ -> pure (samplePhotoInput sample)
    , readFrameGame = \invert slot _ -> pure (sampleGameInput invert slot sample)
    }

switchDisplay :: Resources -> IO ()
switchDisplay = toggleBorderless

syncPresentation :: Resources -> SceneView -> IO ()
syncPresentation = warmNativeScene . resourceScene

drawFrame :: Resources -> SceneView -> Maybe Photo -> Float -> FrameChrome -> Bool -> IO DrawResult
drawFrame resources view portrait pulse chrome needPixels = do
  started <- clockTime
  settings <- readIORef (resourceQuality resources)
  extent@(width, height) <- windowFramebufferSize (resourceWindow resources)
  overlays <- if width == 0 || height == 0 then pure [] else
    recordHUD extent (resourceFont resources) (Just view) $ \pixel scaled -> do
      mapM_ (HUD.renderPhotoFrame pixel) portrait
      case chrome of
        NoChrome -> pure ()
        PhotoChrome photo message -> HUD.renderPhotoChrome scaled photo message
        WorldChrome interface feedback menu toast -> do
          mapM_ (uncurry (HUD.renderInterface scaled ("F4  " <> qualityName (renderQuality settings)) view)) interface
          HUD.renderSaveFeedback scaled feedback
          mapM_ (uncurry (HUD.renderMenu scaled "ESC  旅を続ける")) menu
          mapM_ (HUD.renderPhotoToast scaled) toast
  prepared <- clockTime
  let scene = resourceScene resources
  (status, pixels) <- if needPixels
    then readNativeScene scene settings portrait view pulse overlays
    else (,Nothing) <$> drawNativeScene scene settings portrait view pulse overlays
  submitted <- clockTime
  metrics <- if status == GPU.FramePresented then nativeSceneMetrics scene else pure Nothing
  let milliseconds value = fromIntegral value / 1e6
      renderTiming measured = RenderTiming
        (milliseconds (GPU.framePrepareNSec measured))
        (milliseconds (GPU.frameEncodeNSec measured))
        (milliseconds (GPU.frameFenceWaitNSec measured))
        (milliseconds (GPU.frameSubmitNSec measured))
        (milliseconds (GPU.framePresentCallNSec measured))
        ((/ 1e6) <$> GPU.frameGPUNSec measured)
      present = maybe 0 ((/ 1000) . milliseconds . GPU.framePresentCallNSec) metrics
      writeSnapshot path = case pixels of
        Nothing -> ioError (userError ("Frame unavailable for screenshot: " <> show status))
        Just (GPU.FramePixels pixelWidth pixelHeight rgba) -> do
          image <- either (ioError . userError . show) pure (rgbaImage pixelWidth pixelHeight rgba)
          BS.writeFile path (encodePng image)
  pure (DrawResult (max 0 (submitted - prepared - present)) (prepared - started) present (renderTiming <$> metrics) writeSnapshot)

paceFrame :: Double -> IO Double
paceFrame began = do
  now <- clockTime
  let delay = floor ((1 / 120 - (now - began)) * 1e6)
  if delay <= 0 then pure 0 else do
    threadDelay delay
    subtract now <$> clockTime

#else
frameSource :: Resources -> ControlMode -> IO FrameSource
frameSource _ mode = do
  now <- clockTime
#if defined(wasm32_HOST_ARCH)
  let close = False
#else
  close <- windowShouldClose
#endif
  pure (FrameSource now close False (if mode == Interactive then readPresses else pure []) isWindowFocused pollPhotoInput pollInput)

switchDisplay :: Resources -> IO ()
switchDisplay _ = toggleBorderlessWindowed

syncPresentation :: Resources -> SceneView -> IO ()
syncPresentation = syncChunks

drawFrame :: Resources -> SceneView -> Maybe Photo -> Float -> FrameChrome -> Bool -> IO DrawResult
drawFrame resources view portrait pulse chrome _ = do
  started <- clockTime
  (world, ui) <- drawing $ do
    renderSceneWith portrait resources view pulse
    mapM_ renderPhotoFrame portrait
    rendered <- clockTime
    case chrome of
      NoChrome -> pure ()
      PhotoChrome photo message -> renderPhotoChrome resources photo message
      WorldChrome interface feedback menu toast -> do
        mapM_ (uncurry (renderInterface resources view)) interface
        renderSaveFeedback resources feedback
        mapM_ (uncurry (renderMenu resources)) menu
        mapM_ (renderPhotoToast resources) toast
    presented <- clockTime
    pure (rendered, presented)
  ended <- clockTime
  pure (DrawResult (world - started) (ui - world) (ended - ui) Nothing takeScreenshot)

paceFrame :: Double -> IO Double
paceFrame _ = pure 0
#endif

-- CPP branches are formatted by scripts/check-cpp-format.py.
{- ORMOLU_DISABLE -}
stepFrame :: Session -> FrameState -> IO (Maybe FrameState)
stepFrame (Session resources audio (LightSignal handle glow) timingRef limit shotFrame shotName tour control pointer) (FrameState simulation host frame previousTime) = do
  let w = simulationWorld simulation
      pilotBefore = simulationPilot simulation
  source <- frameSource resources control
  let now = frameTime source
      close = frameClosing source
  let completed = if tour == Just "islands" then Tour.expeditionDone pilotBefore else isJust tour && worldRestored w && null (worldBursts w)
  if close || completed || maybe False (frame >=) limit
    then do
      when (control == Interactive && limit == Nothing && tour == Nothing) (void (saveCurrent w))
      when (isJust tour) $
        writeFile
          ".runtime/garden/tour-result.txt"
          ( unlines
              ["pilot=" <> show pilotBefore, "feet=" <> show (playerFeet (worldPlayer w)), "stage=" <> Tour.tourStage w, "semantic_ticks=" <> show (worldTick w), "revision=" <> show (worldRevision w), "life=" <> show (worldLife w), "kin=" <> show (worldKin w)]
          )
      pure Nothing
    else do
      pressed <- readFramePresses source
      let esc = KeyEscape `elem` pressed
          f2 = KeyF2 `elem` pressed
          f3 = KeyF3 `elem` pressed
          f11 = KeyF11 `elem` pressed
          f5 = KeyF5 `elem` pressed
          enter = KeyEnter `elem` pressed
          invert = KeyI `elem` pressed
          restart = KeyR `elem` pressed
          photoToggle = KeyF6 `elem` pressed
          wasPhoto = isJust (hostPhoto host)
      when f11 (switchDisplay resources)
#if !defined(wasm32_HOST_ARCH)
      when (KeyF4 `elem` pressed) $ modifyIORef' (resourceQuality resources) (preset . nextQuality . renderQuality)
#endif
      focused <- readFrameFocus source
      let plan = Control.planFrame (Control.FrameContext control focused (hostPaused host) wasPhoto (tour == Nothing && limit == Nothing)) (Control.FrameKeys esc photoToggle enter (KeyF12 `elem` pressed))
          paused = Control.pausedAfter plan
          photoEnter = Control.photoTransition plan == Control.EnterPhoto
          capture = Control.captureRequested plan
          startingPhoto = case Control.photoTransition plan of
            Control.LeavePhoto -> Nothing
            Control.EnterPhoto -> Just (beginPhoto (eye (worldPlayer w)) (forward (worldPlayer w)))
            Control.KeepPhoto -> hostPhoto host
          frozen = Control.audioPaused plan
      portrait <- case startingPhoto of
        Nothing -> pure Nothing
        Just p | photoEnter -> pure (Just p)
        Just p -> do
          controls <- readFramePhoto source pressed
          -- Focus activation and a short key press can share a frame. Keep
          -- queued button edges, while ignoring background camera motion.
          let cameraActive =
#if defined(wasm32_HOST_ARCH)
                focused && not paused
#else
                focused
#endif
              activeControls = if cameraActive then controls else controls {photoMove = V3 0 0 0, photoLook = (0, 0), photoZoom = 0, photoTilt = 0, photoLight = 0}
          pure (Just (if restart then beginPhoto (eye (worldPlayer w)) (forward (worldPlayer w)) else stepPhoto (realToFrac (now - previousTime)) activeControls p))
      let updatedHost =
            host
              { hostPaused = paused,
                hostHidden = hostHidden host /= f2,
                hostDebug = hostDebug host /= f3,
                hostInvert = if paused && invert && not wasPhoto then not (hostInvert host) else hostInvert host,
                hostPhoto = portrait,
                hostPhotoMessage = if photoEnter then Nothing else hostPhotoMessage host
              }
      when (frameCaptureLost source) (applyPointer resources control pointer False)
      applyPointer resources control pointer (wantsPointer control focused paused (isJust portrait))
      observed <- if Control.acceptsGameInput plan then readFrameGame source (hostInvert updatedHost) (playerSlot (worldPlayer w)) pressed else pure idleInput
      let driver = if tour == Just "islands" then IslandDriver else if isJust tour then StoryDriver else HumanDriver
          boundary = FrameBoundary (now - previousTime) (Control.simulationMode plan) driver
      (nextSimulation, FrameEffects batches) <-
        either (ioError . userError . ("Afterlight frame rejected: " <>) . show) pure $
          Arena.play AfterlightSession boundary (frameChoices observed (restart && not wasPhoto)) simulation
      -- Consume every tick, including ticks with no cues, in chronological order.
      mapM_ (\out -> void (react handle (1 / 60, Just out))) batches
      let nextWorld = simulationWorld nextSimulation
          cues = concat batches
      nextPulse <- readIORef glow
      afterSim <- clockTime
      let SessionView projected gameView = Arena.observe AfterlightSession Gardener nextSimulation
          view = case portrait of
            Nothing -> if capture then gameView {sceneTarget = NoTarget} else gameView
            Just p -> projected {sceneEye = photoEye p, sceneForward = photoForward p, sceneTarget = NoTarget, sceneBursts = filter (\b -> burstCue b /= Return && burstCue b /= Wound) (sceneBursts projected)}
      syncPresentation resources view
      afterMesh <- clockTime
      when (control == Interactive) $ do
        updateAudio audio (sceneVeil view) frozen
        playCues audio cues
      let shouldSave = control == Interactive && (f5 || tour == Nothing && limit == Nothing && unTick (worldTick nextWorld) `div` 1800 > unTick (worldTick w) `div` 1800)
      saved <- if shouldSave then saveCurrent nextWorld else pure False
      let status = if shouldSave then Just saved else hostSaved updatedHost
          recordUntil = if shouldSave then now + 3 else hostRecordUntil updatedHost
      afterAudio <- clockTime
      let pilotAfter = simulationPilot nextSimulation
          expeditionShot = tour == Just "islands" && pilotBefore /= pilotAfter
          milestoneShot = isJust tour && milestone w /= milestone nextWorld
          needPixels = capture || Just frame == shotFrame || expeditionShot || milestoneShot
          chrome
            | capture = NoChrome
            | Just p <- portrait = if hostHidden updatedHost then NoChrome else PhotoChrome p (hostPhotoMessage updatedHost)
            | otherwise =
                WorldChrome
                  (if hostHidden updatedHost then Nothing else Just (hostDebug updatedHost, realToFrac (1 / max 0.0001 (now - previousTime))))
                  (if not paused && now < recordUntil then status else Nothing)
                  (if paused && control == Interactive then Just (status, hostInvert updatedHost) else Nothing)
                  (if now < hostPhotoUntil updatedHost then hostPhotoMessage updatedHost else Nothing)
      DrawResult worldDraw uiDraw presentDraw nativeTiming writeSnapshot <- drawFrame resources view portrait (if isJust portrait then 0 else nextPulse) chrome needPixels
      paced <- paceFrame now
      afterPresent <- clockTime
      let present = presentDraw + paced
      photoMessage <- if capture then Just <$> capturePhoto writeSnapshot portrait else pure (hostPhotoMessage updatedHost)
      when (afterPresent - now > 0.03) $
        putStrLn (printf "slow frame=%d audio=%.2f world=%.2f ui=%.2f present=%.2f ms" frame ((afterAudio - afterMesh) * 1000) (worldDraw * 1000) (uiDraw * 1000) (present * 1000))
      when (Just frame == shotFrame) (writeSnapshot shotName)
      when expeditionShot $ do
        writeSnapshot (".runtime/garden/screenshots/expedition-" <> show pilotAfter <> ".png")
        putStrLn ("Expedition " <> show pilotAfter <> " feet=" <> show (playerFeet (worldPlayer nextWorld)))
      when milestoneShot $ do
        writeSnapshot (".runtime/garden/screenshots/tour-" <> milestone nextWorld <> ".png")
        putStrLn ("Tour " <> show (worldTick nextWorld) <> " " <> milestone nextWorld)
      when ((isJust limit || isJust tour) && frame < 60000) $ do
        let timing = Timing frame (sceneTime view) ((afterSim - now) * 1000) ((afterMesh - afterSim) * 1000) ((afterAudio - afterMesh) * 1000) (worldDraw * 1000) (uiDraw * 1000) (present * 1000) ((afterPresent - now) * 1000) (((now - previousTime) * 1000,) <$> nativeTiming)
        modifyIORef' timingRef (timing :)
      let continuedHost = updatedHost {hostSaved = status, hostRecordUntil = recordUntil, hostPhotoMessage = photoMessage, hostPhotoUntil = if capture then now + 4 else hostPhotoUntil updatedHost}
          continue nextHost = Just (FrameState nextSimulation nextHost (frame + 1) now)
      if Control.saveAndExit plan
        then do
          success <- saveCurrent nextWorld
          pure (if success then Nothing else continue (updatedHost {hostSaved = Just False, hostRecordUntil = now + 3}))
        else pure (continue continuedHost)
  where
    milestone world = Tour.tourStage world <> "-" <> show (bonded world) <> "-" <> show (sheltered world)

{- ORMOLU_ENABLE -}

capturePhoto :: (FilePath -> IO ()) -> Maybe Photo -> IO String
capturePhoto writeSnapshot portrait = do
  stamp <- formatTime defaultTimeLocale "%Y%m%d-%H%M%S" <$> getZonedTime
  result <-
    try
      ( do
          createDirectoryIfMissing True "Screenshots"
          path <- available ("Screenshots/Garden-" <> stamp) (0 :: Int)
          writeSnapshot path
          exists <- doesFileExist path
          size <- if exists then getFileSize path else pure 0
          unless (size > 8) (ioError (userError "PNG export failed"))
          writeFile (path <> ".txt") ("Garden of Afterlight / Photo settings\n" <> maybe "Gameplay camera" show portrait <> "\n")
          pure path
      ) ::
      IO (Either IOException FilePath)
  case result of
    Right path -> putStrLn ("Photo saved: " <> path) >> pure ("撮影しました  " <> path)
    Left problem -> putStrLn ("Photo failed: " <> show problem) >> pure "撮影できませんでした。保存先の空き容量と書き込み権限を確認してください。"
  where
    available stem n = do
      let path = stem <> (if n == 0 then "" else "-" <> show n) <> ".png"
      exists <- doesPathExist path
      if exists then available stem (n + 1) else pure path

saveCurrent :: World -> IO Bool
saveCurrent w = do
  path <- savePath
  let temp = path <> ".next"
  result <-
    try
      ( do
          createDirectoryIfMissing True (takeDirectory path)
          writeFile temp (encode w)
          exists <- doesFileExist path
          when exists (copyFile path (path <> ".previous"))
          renameFile temp path
      ) ::
      IO (Either IOException ())
  case result of
    Right () -> putStrLn "Garden checkpoint saved." >> pure True
    Left problem -> putStrLn ("Could not save; previous checkpoint retained: " <> show problem) >> pure False

savePath :: IO FilePath
savePath = maybe ".runtime/garden/save-v2.txt" id <$> lookupEnv "GARDEN_SAVE_PATH"

loadSaved :: IO World
loadSaved = do
  path <- savePath
  exists <- doesFileExist path
  if not exists
    then pure initialWorld
    else do
      raw <- readFile path
      -- Finish lazy IO before a rejected file is copied: Windows holds a read
      -- lock until EOF, and a parser may reject after only the first character.
      _ <- evaluate (length raw)
      case decode raw of
        Right world -> putStrLn ("Loaded checkpoint: " <> show (worldTick world) <> " feet=" <> show (playerFeet (worldPlayer world))) >> pure world
        Left problem -> do
          backup <- unusedBackup path (0 :: Int)
          copyFile path backup
          putStrLn ("Unreadable checkpoint preserved at " <> backup <> ": " <> show problem)
          pure initialWorld {worldNotice = RecordRecovered, worldNoticeUntil = Tick 600}
  where
    unusedBackup path n = do
      let backup = path <> ".rejected" <> (if n == 0 then "" else "." <> show n)
      exists <- doesFileExist backup
      if exists then unusedBackup path (n + 1) else pure backup

readEnv :: (Read a) => String -> IO (Maybe a)
readEnv name = do value <- lookupEnv name; pure (value >>= readMaybe)

chooseScene :: Maybe String -> World -> World
chooseScene Nothing w = w
chooseScene (Just label) _ = case label of
  "night" -> base {worldVeil = 0.94, worldChapter = Nightfall, worldTick = Tick 30000, worldJourney = NightInvited}
  "dusk" -> base {worldVeil = 0.56, worldChapter = LongDusk, worldTick = Tick 16000}
  "sky" -> viewFrom (V3 0 500 0) (V3 0 540 70) base
  "high" -> viewFrom (V3 (-37) 29 (-26)) (V3 0 13 38) base
  "kin" -> viewFrom (V3 (-16) 5 (-5)) (V3 (-12) 5 1) base
  "return" -> viewFrom (V3 (-8) 19 32) (V3 0 22 54) base {worldJourney = GardenRenewed, worldChapter = Homecoming}
  _ -> base
  where
    base = initialWorld

viewFrom :: V3 -> V3 -> World -> World
viewFrom feet target w = w {worldPlayer = p {playerFeet = feet, playerYaw = atan2 x z, playerPitch = atan2 y (sqrt (x * x + z * z)), playerMotion = Flying}, worldJourney = if worldRestored w then GardenRenewed else Lightborne}
  where
    p = worldPlayer w; V3 x y z = minus target (plus feet (V3 0 1.65 0))

writeTiming :: [Timing] -> IO ()
writeTiming rows = do
  writeFile ".runtime/garden/frame-times.csv" ("frame,semantic_seconds,simulation_ms,mesh_ms,audio_save_ms,render_ms,ui_ms,present_ms,frame_including_present_ms\n" <> concat [printf "%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f\n" f t s m a r u q p | Timing f t s m a r u q p _ <- rows])
  let nativeRows =
        [ printf "%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s\n" f interval prepare command fence submit present (maybe "" (printf "%.4f") gpu)
        | Timing f _ _ _ _ _ _ _ _ (Just (interval, RenderTiming prepare command fence submit present gpu)) <- rows
        ]
  unless (null nativeRows) $
    writeFile ".runtime/garden/native-frame-times.csv" ("frame,interval_ms,renderer_prepare_ms,encode_ms,fence_ms,submit_ms,present_call_ms,gpu_ms\n" <> concat nativeRows)
  let times = sort [p | Timing _ _ _ _ _ _ _ _ p _ <- rows]
      percentile :: Double -> Double
      percentile ratio = case drop (floor (ratio * fromIntegral (length times - 1))) times of x : _ -> x; [] -> 0
  putStrLn (printf "garden frames=%d frame p50=%.3f p95=%.3f max=%.3f ms (includes paced present)" (length rows) (percentile 0.5) (percentile 0.95) (percentile 1))

-- Only transitions touch the OS. Observers never read or change pointer state,
-- including startup, focus loss, photo mode and teardown.
applyPointer :: Resources -> ControlMode -> IORef Bool -> Bool -> IO ()
applyPointer _ ObserveOnly _ _ = pure ()
#if defined(AFTERLIGHT_GAMEIO)
applyPointer resources Interactive state wanted = mask_ $ do
  previous <- readIORef state
  when (previous /= wanted) $ do
    let window = resourceWindow resources
    if wanted
      then do
        setPointerCapture window True
        captured <- windowPointerCaptured window
        when captured (setPointerVisible window False)
        writeIORef state captured
      else do
        setPointerVisible window True
        setPointerCapture window False
        writeIORef state False
#else
applyPointer _ Interactive state wanted = do
  previous <- readIORef state
  when (previous /= wanted) $ do
    if wanted then disableCursor else enableCursor
    writeIORef state wanted
    _ <- getMouseDelta
    pure ()
#endif
