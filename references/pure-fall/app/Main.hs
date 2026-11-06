{-# LANGUAGE PatternSynonyms #-}

module Main (main) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (foldM, void, when)
import Data.ByteString.Char8 qualified as BS
import Data.Maybe (mapMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Foreign (castPtr)
import Foreign.C (withCString)
import PureFall.Core
import PureFall.Host.Audio
import PureFall.Host.Font (Fonts, withFonts)
import PureFall.Host.Render
import PureFall.Host.Save
import PureFall.Session
import PureFall.Time
import PureFall.View
import Raylib.Core
import Raylib.Core.Textures (c'exportImage, c'loadImageFromScreen, c'unloadImage)
import Raylib.Internal.Foreign (c'free)
import Raylib.Types (ConfigFlag (..), KeyboardKey (..), MouseButton (..), Vector2)
import Raylib.Util (drawing, withWindow)
import Raylib.Util.RLGL (c'rlDrawRenderBatchActive)
import System.Directory (XdgDirectory (XdgData), createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getXdgDirectory)
import System.Environment (getArgs, getExecutablePath)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

data LaunchOptions = LaunchOptions
  { optionFrames :: Maybe Int,
    optionShots :: Maybe FilePath,
    optionFixture :: Maybe Fixture,
    optionSmoke :: Bool,
    optionMode :: Maybe Mode,
    optionSeed :: Maybe Word64,
    optionGenerate :: Bool,
    optionAudio :: Maybe FilePath,
    optionData :: Maybe FilePath
  }

defaultOptions :: LaunchOptions
defaultOptions = LaunchOptions Nothing Nothing Nothing False Nothing Nothing False Nothing Nothing

parseOptions :: LaunchOptions -> [String] -> Either String LaunchOptions
parseOptions options [] = Right options
parseOptions options ("--frames" : value : rest) = case readMaybe value of
  Just count | count > 0 && count <= 1000000 -> parseOptions options {optionFrames = Just count} rest
  _ -> Left "--frames expects an integer from 1 to 1000000"
parseOptions options ("--shots" : path : rest) = parseOptions options {optionShots = Just path} rest
parseOptions options ("--fixture" : value : rest) = case readMaybe value of
  Just chosen -> parseOptions options {optionFixture = Just chosen} rest
  Nothing -> Left "Unknown fixture: FourLine / SpinSingle / Cavity / NearSprint / NearUltra / TopOut"
parseOptions options ("--mode" : value : rest) = case readMaybe value of
  Just chosen -> parseOptions options {optionMode = Just chosen} rest
  Nothing -> Left "Unknown mode: Marathon / Sprint / Ultra / Practice"
parseOptions options ("--seed" : value : rest) = case readMaybe value of
  Just chosen -> parseOptions options {optionSeed = Just chosen} rest
  Nothing -> Left "--seed expects an unsigned integer"
parseOptions options ("--audio-dir" : path : rest) = parseOptions options {optionAudio = Just path} rest
parseOptions options ("--data-dir" : path : rest) = parseOptions options {optionData = Just path} rest
parseOptions options ("--smoke" : rest) = parseOptions options {optionSmoke = True} rest
parseOptions options ("--generate-audio" : rest) = parseOptions options {optionGenerate = True} rest
parseOptions _ _ = Left "Usage: pure-fall [--frames N] [--shots DIR] [--mode Practice] [--fixture FourLine] [--smoke] [--generate-audio --audio-dir DIR]"

data Best = Best Mode Int Int deriving (Eq, Show, Read)

data Local = Local {localVolume :: Int, localMusic :: Bool, localDas :: Int, localArr :: Int, localBests :: [Best]}
  deriving (Eq, Show, Read)

defaultLocal :: Local
defaultLocal = Local 55 True 9 2 []

loadLocal :: FilePath -> IO Local
loadLocal directory = do
  contents <- readSafe (directory </> "settings.dat")
  pure $ case contents >>= readMaybe of
    Just local
      | localVolume local >= 0
          && localVolume local <= 100
          && localDas local >= 1
          && localDas local <= 30
          && localArr local >= 0
          && localArr local <= 10
          && all validBest (localBests local)
          && length (localBests local) <= 4 ->
          local
    _ -> defaultLocal
  where
    validBest (Best chosen points time) = chosen /= Practice && points >= 0 && time >= 0

saveLocal :: FilePath -> Local -> IO ()
saveLocal directory local = writeSafe (directory </> "settings.dat") (show local)

readSafe :: FilePath -> IO (Maybe String)
readSafe path = do
  result <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
  pure (either (const Nothing) (Just . BS.unpack) result)

writeSafe :: FilePath -> String -> IO ()
writeSafe path value = void (writeSafeResult path value)

writeSafeResult :: FilePath -> String -> IO Bool
writeSafeResult path value = do
  result <- try (BS.writeFile path (BS.pack value)) :: IO (Either IOException ())
  case result of
    Left issue -> putStrLn ("Could not write " ++ path ++ ": " ++ show issue) >> pure False
    Right () -> pure True

data Action
  = Accept
  | MenuUp
  | MenuDown
  | MenuLeft
  | MenuRight
  | PauseKey
  | HelpKey
  | OptionsKey
  | SaveKey
  | LoadKey
  | MuteKey
  | FullscreenKey
  | QuitToTitle
  | ReplayKey
  | RewindKey
  | StudyKey
  | PreviousLanding
  | NextLanding
  deriving (Eq, Show)

data PressEvent = PressEvent (Maybe Command) (Maybe Action)

data FrameInput = FrameInput
  { frameCommands :: [Command],
    frameHeld :: Held,
    frameActions :: [Action],
    frameFocused :: Bool,
    frameMouse :: Maybe Vector2,
    framePresses :: [PressEvent]
  }

readInput :: IO FrameInput
readInput = do
  pressed <- drainKeyPresses
  left <- isKeyDown KeyLeft
  right <- isKeyDown KeyRight
  soft <- isKeyDown KeyDown
  focused <- isWindowFocused
  click <- isMouseButtonPressed MouseButtonLeft
  mouse <- if click then Just <$> getMousePosition else pure Nothing
  let direction | left && not right = Leftward | right && not left = Rightward | otherwise = Neutral
      command key = case key of
        KeyLeft | not right -> Just MoveLeft
        KeyRight | not left -> Just MoveRight
        KeyDown -> Just MoveDown
        KeyX -> Just Clockwise
        KeyUp -> Just Clockwise
        KeyZ -> Just Counterclockwise
        KeySpace -> Just HardDrop
        KeyC -> Just SwapHold
        KeyLeftShift -> Just SwapHold
        KeyRightShift -> Just SwapHold
        _ -> Nothing
      commands = mapMaybe command pressed
      actions = mapMaybe (`lookup` bindings) pressed
      events = [PressEvent (command key) (lookup key bindings) | key <- pressed]
  pure (FrameInput commands (Held direction soft) actions focused mouse events)
  where
    bindings =
      [ (KeyEnter, Accept),
        (KeyUp, MenuUp),
        (KeyDown, MenuDown),
        (KeyLeft, MenuLeft),
        (KeyRight, MenuRight),
        (KeyP, PauseKey),
        (KeyEscape, PauseKey),
        (KeyF1, HelpKey),
        (KeyO, OptionsKey),
        (KeyF5, SaveKey),
        (KeyF9, LoadKey),
        (KeyM, MuteKey),
        (KeyF11, FullscreenKey),
        (KeyT, QuitToTitle),
        (KeyR, ReplayKey),
        (KeyBackspace, RewindKey),
        (KeyQ, StudyKey),
        (KeyPageUp, PreviousLanding),
        (KeyPageDown, NextLanding)
      ]

drainKeyPresses :: IO [KeyboardKey]
drainKeyPresses = do
  key <- getKeyPressed
  if key == KeyNull then pure [] else (key :) <$> drainKeyPresses

data Runtime = Runtime
  { runtimeSession :: Session,
    runtimeScreen :: Screen,
    runtimeBack :: Screen,
    runtimeMenu :: Int,
    runtimeSetting :: Int,
    runtimeLocal :: Local,
    runtimeStudy :: Int,
    runtimeEffects :: Effects,
    runtimeFrame :: Int,
    runtimeResultAge :: Float,
    runtimeResultStored :: Bool,
    runtimeSaved :: Bool,
    runtimeMessage :: String,
    runtimeMessageAge :: Float,
    runtimeReplay :: Bool,
    runtimePlaybackDebt :: Integer,
    runtimeWitness :: [Command],
    runtimeCaptures :: [String],
    runtimeOsCommands :: Int,
    runtimeOsHeldFrames :: Int,
    runtimeFocusLosses :: Int,
    runtimeSkipFrame :: Bool,
    runtimeView :: RenderModel,
    runtimeViewGame :: Game,
    runtimeViewStudy :: Int,
    runtimeInputCues :: [Cue],
    runtimeUiEvents :: [Action]
  }

newRuntime :: Session -> Screen -> Local -> Bool -> Runtime
newRuntime session screen local saved = Runtime session screen Title 0 0 local 0 emptyEffects 0 0 False saved "" 0 False 0 [] [] 0 0 0 False (renderModel 0 game) game 0 [] []
  where
    game = sessionGame session

main :: IO ()
main = do
  arguments <- getArgs
  options <- either (ioError . userError) pure (parseOptions defaultOptions arguments)
  if optionGenerate options
    then generateAudio (maybe "assets/audio" id (optionAudio options))
    else run options

run :: LaunchOptions -> IO ()
run options = do
  directory <- case optionData options of
    Just path -> pure path
    Nothing -> case (optionSmoke options, optionShots options) of
      (True, Just path) -> pure (path </> "user-data")
      _ -> getXdgDirectory XdgData "PureFall"
  createDirectoryIfMissing True directory
  local <- loadLocal directory
  saved <- doesFileExist (directory </> "session.dat")
  clock <- getPOSIXTime
  let seed = maybe (floor (clock * 1000000)) id (optionSeed options)
      chosen = maybe Marathon id (optionMode options)
      initialGame = maybe (configuredGame chosen seed local) fixture (optionFixture options)
      initialScreen = if optionFixture options /= Nothing || optionMode options /= Nothing then Playing else Title
      initial = newRuntime (start initialGame) initialScreen local saved
  audioRoot <- resolveAudio directory options
  forMOptional (optionShots options) (createDirectoryIfMissing True)
  setConfigFlags [WindowResizable, Msaa4xHint, VsyncHint]
  withWindow 1296 900 "PURE / FALL" 120 $ \resources -> do
    setWindowMinSize 860 650
    setExitKey KeyNull
    when (optionSmoke options) (setTargetFPS 0)
    withFonts $ \fonts -> withAudio resources audioRoot $ \audio -> loop fonts audio directory options seed initial

resolveAudio :: FilePath -> LaunchOptions -> IO FilePath
resolveAudio directory options = case optionAudio options of
  Just path -> pure path
  Nothing -> do
    executable <- getExecutablePath
    let packaged = takeDirectory executable </> "assets/audio"
    currentExists <- doesDirectoryExist "assets/audio"
    packagedExists <- doesDirectoryExist packaged
    pure (if packagedExists then packaged else if currentExists then "assets/audio" else directory </> "audio")

configuredGame :: Mode -> Word64 -> Local -> Game
configuredGame chosen seed local = case settings (localDas local) (localArr local) of
  Right config -> seededGame chosen seed config
  Left _ -> fresh chosen seed

forMOptional :: Maybe a -> (a -> IO ()) -> IO ()
forMOptional value action = maybe (pure ()) action value

loop :: Fonts -> Audio -> FilePath -> LaunchOptions -> Word64 -> Runtime -> IO ()
loop fonts audio directory options seed state = do
  closing <- windowShouldClose
  let frame = runtimeFrame state
      frameLimit = case optionFrames options of Just count -> Just count; Nothing -> if optionSmoke options then Just 600 else Nothing
      bounded = maybe False (frame >=) frameLimit
  if closing || bounded
    then finishReport audio options state
    else do
      observed <- readInput
      seconds <- if optionSmoke options then pure (1 / 60) else getFrameTime
      width <- getScreenWidth
      height <- getScreenHeight
      let input = if optionSmoke options then harnessInput options frame else observed
          prepared = if optionSmoke options then harnessState options frame state else state
          elapsed = if optionSmoke options then 16667 else max 0 (round (realToFrac seconds * (1000000 :: Double)))
      controlled <- controlUi directory seed width height input prepared {runtimeInputCues = []}
      let (advanced, clockCues) = advanceRuntime elapsed input controlled
          cues = runtimeInputCues controlled ++ clockCues
          resultPhase = phase (sessionGame (runtimeSession advanced))
          resultAge = if resultPhase `elem` [Won, Lost] then runtimeResultAge advanced + seconds else 0
          countOs = if optionSmoke options then 0 else length (frameCommands input)
          heldOs = if not (optionSmoke options) && frameHeld input /= Held Neutral False then 1 else 0
          focusOs = if not (frameFocused input) && phase (sessionGame (runtimeSession prepared)) == Falling then 1 else 0
          next =
            advanced
              { runtimeEffects = advanceEffects seconds cues (runtimeEffects advanced),
                runtimeFrame = frame + 1,
                runtimeResultAge = resultAge,
                runtimeMessageAge = max 0 (runtimeMessageAge advanced - seconds),
                runtimeOsCommands = runtimeOsCommands advanced + countOs,
                runtimeOsHeldFrames = runtimeOsHeldFrames advanced + heldOs,
                runtimeFocusLosses = runtimeFocusLosses advanced + focusOs
              }
      resultStored <- storeResult directory next
      let stored = refreshView resultStored
          view = runtimeView stored
          ui = uiModel options stored view
          shot = captureLabel stored cues view
      playCues audio cues
      updateAudio audio (localVolume (runtimeLocal stored)) (localMusic (runtimeLocal stored)) (viewPhase view /= Falling)
      drawing $ do
        render fonts width height ui (runtimeEffects stored) view
        case (optionShots options, shot) of
          (Just shots, Just name) -> capture (shots </> name ++ ".png")
          _ -> pure ()
      let captured = maybe stored (\name -> stored {runtimeCaptures = name : runtimeCaptures stored}) shot
      loop fonts audio directory options seed captured

refreshView :: Runtime -> Runtime
refreshView state
  | game == runtimeViewGame state && runtimeStudy state == runtimeViewStudy state = state
  | otherwise = state {runtimeView = renderModel (runtimeStudy state) game, runtimeViewGame = game, runtimeViewStudy = runtimeStudy state}
  where
    game = sessionGame (runtimeSession state)

controlUi :: FilePath -> Word64 -> Int -> Int -> FrameInput -> Runtime -> IO Runtime
controlUi directory seed width height input state
  | not (frameFocused input) = pure state
  | otherwise = do
      keyed <- foldM processPress state (framePresses input)
      case frameMouse input of
        Nothing -> pure keyed
        Just _ -> controlUiAction directory seed width height input {frameActions = [], frameCommands = [], framePresses = []} keyed
  where
    -- Key events retain OS queue order; a click follows those keys. Pause and
    -- study are Session barriers, so later UI events observe their new phase.
    processPress current (PressEvent command action) = do
      let beforeScreen = runtimeScreen current
          recorded = case action of
            Nothing -> current
            Just value -> current {runtimeUiEvents = take 128 (value : runtimeUiEvents current)}
      afterUi <- case action of
        Nothing -> pure recorded
        Just value -> controlUiAction directory seed width height input {frameActions = [value], frameCommands = [], frameMouse = Nothing, framePresses = []} recorded
      let semantic = case command of
            Just value -> Just value
            Nothing -> case action of Just PauseKey -> Just Pause; Just StudyKey -> Just Study; _ -> Nothing
      pure $ case (beforeScreen, semantic) of
        (Playing, Just value) -> enqueueCommand input value afterUi
        _ -> afterUi

enqueueCommand :: FrameInput -> Command -> Runtime -> Runtime
enqueueCommand input command state
  | runtimeScreen state /= Playing || runtimeReplay state = state
  | not (null (runtimeWitness state)) && command `notElem` [Pause, Study] = state
  | otherwise =
      let (session, cues) = advanceFrame (frameMicros 0) [command] (frameHeld input) (frameFocused input) (runtimeSession state)
          boundary = command `elem` [Pause, Study]
       in state
            { runtimeSession = session,
              runtimeInputCues = runtimeInputCues state ++ cues,
              runtimeSkipFrame = runtimeSkipFrame state || boundary,
              runtimeWitness = if boundary then [] else runtimeWitness state
            }

controlUiAction :: FilePath -> Word64 -> Int -> Int -> FrameInput -> Runtime -> IO Runtime
controlUiAction directory seed width height input state = do
  when (has FullscreenKey) toggleFullscreen
  let soundChanged = if has MuteKey then state {runtimeLocal = (runtimeLocal state) {localVolume = if localVolume (runtimeLocal state) == 0 then 55 else 0}} else state
  loaded <- if has LoadKey && not (runtimeReplay soundChanged) then loadRun directory soundChanged else pure soundChanged
  saved <- if has SaveKey && runtimeScreen loaded /= Title && not (runtimeReplay loaded) then saveRun directory loaded else pure loaded
  let currentScreen = runtimeScreen saved
      oldGame = sessionGame (runtimeSession saved)
      paused = phase oldGame == Paused
      result = phase oldGame `elem` [Won, Lost]
      mouseMenu = frameMouse input >>= menuHit width height
      mouseSetting = frameMouse input >>= settingsHit width height
      menuDelta = fromEnum (has MenuDown) - fromEnum (has MenuUp)
      chosenIndex = maybe ((runtimeMenu saved + menuDelta) `mod` 4) id mouseMenu
      next = case currentScreen of
        Title
          | has HelpKey -> openOverlay Help saved
          | has OptionsKey -> openOverlay Options saved
          | has Accept || mouseMenu /= Nothing -> beginRun seed (toEnum chosenIndex) saved
          | otherwise -> saved {runtimeMenu = chosenIndex}
        Help
          | has HelpKey || has PauseKey -> saved {runtimeScreen = runtimeBack saved}
          | otherwise -> saved
        Options
          | has OptionsKey || has PauseKey -> saved {runtimeScreen = runtimeBack saved}
          | otherwise -> changeSettings menuDelta mouseSetting input saved
        Playing
          | has HelpKey -> openOverlay Help saved
          | has OptionsKey -> openOverlay Options saved
          | has QuitToTitle && (paused || result || runtimeReplay saved) -> saved {runtimeScreen = Title, runtimeReplay = False, runtimeWitness = []}
          | result && runtimeResultAge saved >= 0.45 && has Accept -> beginRun seed (mode oldGame) saved
          | result && runtimeResultAge saved >= 0.45 && has ReplayKey -> saved {runtimeSession = restartReplay (runtimeSession saved), runtimeReplay = True, runtimePlaybackDebt = 0, runtimeResultStored = False, runtimeResultAge = 0}
          | has RewindKey && mode oldGame == Practice && not (runtimeReplay saved) -> notify "CHECKPOINT RESTORED / A NEW BRANCH" saved {runtimeSession = rewindPiece (runtimeSession saved), runtimeWitness = [], runtimeStudy = 0}
          | has Accept && phase oldGame == Studying && null (runtimeWitness saved) -> case studySelect (viewStudyIndex (runtimeView (refreshView saved))) oldGame of
              Nothing -> saved
              Just entry -> saved {runtimeWitness = landingPath entry ++ [HardDrop], runtimePlaybackDebt = 0}
          | otherwise -> saved {runtimeStudy = runtimeStudy saved + fromEnum (has NextLanding) - fromEnum (has PreviousLanding)}
  when (runtimeLocal next /= runtimeLocal state) (saveLocal directory (runtimeLocal next))
  pure next
  where
    has action = action `elem` frameActions input

openOverlay :: Screen -> Runtime -> Runtime
openOverlay target state =
  let game = sessionGame (runtimeSession state)
      (session, _) =
        if runtimeScreen state == Playing && not (runtimeReplay state) && phase game `elem` [Falling, Studying]
          then advanceFrame (frameMicros 0) [Pause] (Held Neutral False) True (runtimeSession state)
          else (runtimeSession state, [])
   in state {runtimeSession = session, runtimeBack = runtimeScreen state, runtimeScreen = target, runtimeWitness = [], runtimeSkipFrame = True}

beginRun :: Word64 -> Mode -> Runtime -> Runtime
beginRun seed chosen state =
  state
    { runtimeSession = start (configuredGame chosen (seed + fromIntegral (runtimeFrame state)) (runtimeLocal state)),
      runtimeScreen = Playing,
      runtimeStudy = 0,
      runtimeEffects = emptyEffects,
      runtimeReplay = False,
      runtimeWitness = [],
      runtimeResultAge = 0,
      runtimeResultStored = False,
      runtimePlaybackDebt = 0,
      runtimeSkipFrame = True
    }

changeSettings :: Int -> Maybe Int -> FrameInput -> Runtime -> Runtime
changeSettings delta mouse input state = state {runtimeSetting = row, runtimeLocal = changed}
  where
    row = maybe ((runtimeSetting state + delta) `mod` 4) id mouse
    direction = fromEnum (MenuRight `elem` frameActions input) - fromEnum (MenuLeft `elem` frameActions input)
    local = runtimeLocal state
    changed = case row of
      0 -> local {localVolume = max 0 (min 100 (localVolume local + direction * 5))}
      1 -> if direction /= 0 || Accept `elem` frameActions input then local {localMusic = not (localMusic local)} else local
      2 -> local {localDas = max 1 (min 30 (localDas local + direction))}
      _ -> local {localArr = max 0 (min 10 (localArr local + direction))}

advanceRuntime :: Integer -> FrameInput -> Runtime -> (Runtime, [Cue])
advanceRuntime elapsed input state
  | runtimeSkipFrame state = (state {runtimeSkipFrame = False}, [])
  | runtimeScreen state /= Playing = (state, [])
  | runtimeReplay state =
      if frameFocused input then replayTicks state {runtimePlaybackDebt = runtimePlaybackDebt state + elapsed * 60} [] else (state, [])
  | not (null (runtimeWitness state)) =
      if not (frameFocused input)
        then normal state {runtimeWitness = []} []
        else witnessTicks state {runtimePlaybackDebt = runtimePlaybackDebt state + elapsed} []
  | otherwise = normal state []
  where
    normal current verbs =
      let (session, cues) = advanceFrame (frameMicros elapsed) verbs (frameHeld input) (frameFocused input) (runtimeSession current)
       in (current {runtimeSession = session}, cues)
    replayTicks current cues
      | runtimePlaybackDebt current < 1000000 || not (replayAvailable (runtimeSession current)) = (current, cues)
      | otherwise =
          let (session, more) = replayNext (runtimeSession current)
           in replayTicks current {runtimeSession = session, runtimePlaybackDebt = runtimePlaybackDebt current - 1000000} (cues ++ more)
    witnessTicks current cues
      | runtimePlaybackDebt current < frameMicroCount pathStepMicros = (current, cues)
      | otherwise = case runtimeWitness current of
          [] -> (current {runtimePlaybackDebt = 0}, cues)
          command : rest ->
            let (session, more) = tickSession (TickInput [command] (Held Neutral False)) (runtimeSession current)
             in witnessTicks current {runtimeSession = session, runtimeWitness = rest, runtimePlaybackDebt = runtimePlaybackDebt current - frameMicroCount pathStepMicros} (cues ++ more)

saveRun :: FilePath -> Runtime -> IO Runtime
saveRun directory state = case hostCheckpoint (runtimeSession state) (runtimeStudy state) (runtimeWitness state) (frameMicros (runtimePlaybackDebt state)) of
  Left _ -> pure (notify "SESSION CANNOT BE SAVED / DATA LIMIT OR INVALID STATE" state)
  Right encoded -> do
    success <- writeSafeResult (directory </> "session.dat") encoded
    pure (notify (if success then "SESSION SAVED / F9 TO RESTORE" else "SAVE COULD NOT BE WRITTEN") state {runtimeSaved = runtimeSaved state || success})

loadRun :: FilePath -> Runtime -> IO Runtime
loadRun directory state = do
  saved <- readSafe (directory </> "session.dat")
  pure $ case saved of
    Nothing -> notify "NO SAVED SESSION FOUND" state
    Just encoded -> case restoreHostCheckpoint encoded of
      Left _ -> notify "SAVE REJECTED / INVALID SESSION DATA" state
      Right restored ->
        notify
          "SESSION RESTORED"
          state
            { runtimeSession = restoredSession restored,
              runtimeScreen = Playing,
              runtimeReplay = False,
              runtimeStudy = restoredStudyIndex restored,
              runtimeWitness = restoredMoves restored,
              runtimePlaybackDebt = frameMicroCount (restoredMoveDebt restored),
              runtimeEffects = emptyEffects,
              runtimeResultAge = 0,
              runtimeResultStored = False,
              runtimeSkipFrame = True
            }

notify :: String -> Runtime -> Runtime
notify message state = state {runtimeMessage = message, runtimeMessageAge = 3}

storeResult :: FilePath -> Runtime -> IO Runtime
storeResult directory state
  | runtimeResultStored state || runtimeReplay state || phase game `notElem` [Won, Lost] = pure state
  | otherwise = do
      let local = runtimeLocal state
          candidates = localBests local
          chosen = mode game
          eligible = chosen /= Practice && (chosen /= Sprint || phase game == Won)
          old = lookupBest chosen candidates
          better = case old of Nothing -> True; Just (Best _ oldScore oldTime) -> if chosen == Sprint then tickCount (ticks game) < oldTime else score game > oldScore
          updated = if eligible && better then Best chosen (score game) (tickCount (ticks game)) : filter (\(Best m _ _) -> m /= chosen) candidates else candidates
          next = state {runtimeResultStored = True, runtimeLocal = local {localBests = updated}}
      when (updated /= candidates) (saveLocal directory (runtimeLocal next))
      pure next
  where
    game = sessionGame (runtimeSession state)

lookupBest :: Mode -> [Best] -> Maybe Best
lookupBest chosen = foldl' (\found entry@(Best entryMode _ _) -> if entryMode == chosen then Just entry else found) Nothing

bestText :: Mode -> Local -> String
bestText chosen local = case lookupBest chosen (localBests local) of
  Nothing -> "--"
  Just (Best _ points time) -> if chosen == Sprint then timeLabel (tickNo time) else show points

uiModel :: LaunchOptions -> Runtime -> RenderModel -> Ui
uiModel options state view =
  Ui
    (runtimeScreen state)
    (runtimeMenu state)
    (runtimeSetting state)
    (localVolume local)
    (localMusic local)
    (localDas local)
    (localArr local)
    (bestText (if runtimeScreen state == Title then toEnum (runtimeMenu state) else viewMode view) local)
    (runtimeSaved state)
    (if runtimeMessageAge state > 0 then runtimeMessage state else "")
    (runtimeReplay state)
    (not (null (runtimeWitness state)))
    (optionSmoke options)
    (runtimeResultAge state >= 0.45)
  where
    local = runtimeLocal state

harnessInput :: LaunchOptions -> Int -> FrameInput
harnessInput options frame = FrameInput commands (Held Neutral False) actions True Nothing events
  where
    events = map (\command -> PressEvent (Just command) Nothing) commands ++ map (\action -> PressEvent Nothing (Just action)) actions
    commands = case optionFixture options of
      Just Cavity -> []
      Just _ -> [HardDrop | frame == 30]
      Nothing -> [HardDrop | frame `elem` [46, 70, 92, 431]]
    actions = case optionFixture options of
      Just Cavity -> [StudyKey | frame == 25] ++ [NextLanding | frame == 55] ++ [Accept | frame == 90]
      Just _ -> []
      Nothing -> [Accept | frame == 18] ++ [PauseKey | frame == 165] ++ [StudyKey | frame == 230] ++ [NextLanding | frame == 255] ++ [Accept | frame == 290]

harnessState :: LaunchOptions -> Int -> Runtime -> Runtime
harnessState options frame state
  | optionFixture options /= Nothing = state
  | frame == 18 = state {runtimeMenu = 3}
  | frame == 45 = state {runtimeSession = start (fixture FourLine), runtimeEffects = emptyEffects}
  | frame == 225 = state {runtimeSession = start (fixture Cavity), runtimeEffects = emptyEffects}
  | frame == 430 = state {runtimeSession = start (fixture NearSprint), runtimeEffects = emptyEffects, runtimeResultStored = False}
  | otherwise = state

captureLabel :: Runtime -> [Cue] -> RenderModel -> Maybe String
captureLabel state cues view
  | runtimeFrame state < 2 = Nothing
  | otherwise = case wanted of
      Just label | label `notElem` runtimeCaptures state -> Just label
      _ -> Nothing
  where
    wanted
      | runtimeScreen state == Title = Just "01-title"
      | runtimeScreen state == Help = Just "07-controls"
      | runtimeScreen state == Options = Just "08-settings"
      | any isClear cues = Just "03-clear"
      | viewPhase view == Paused = Just "04-pause"
      | viewPhase view == Studying = Just "05-study"
      | viewPhase view `elem` [Won, Lost] && runtimeResultAge state > 0.5 = Just "06-results"
      | runtimeScreen state == Playing && viewPhase view == Falling = Just "02-play"
      | otherwise = Nothing
    isClear cue = case cue of Cleared _ -> True; _ -> False

capture :: FilePath -> IO ()
capture path = do
  c'rlDrawRenderBatchActive
  bracket c'loadImageFromScreen (\image -> c'unloadImage image >> c'free (castPtr image)) $ \image ->
    withCString path $ \destination -> void (c'exportImage image destination)

finishReport :: Audio -> LaunchOptions -> Runtime -> IO ()
finishReport audio options state = do
  audioStats <- audioReport audio
  let game = sessionGame (runtimeSession state)
      report =
        "source="
          ++ (if optionSmoke options then "harness-injected" else "native-os-polling")
          ++ "\nframes="
          ++ show (runtimeFrame state)
          ++ "\nphase="
          ++ show (phase game)
          ++ "\nscore="
          ++ show (score game)
          ++ "\nlines="
          ++ show (linesCleared game)
          ++ "\npieces="
          ++ show (piecesLocked game)
          ++ "\nsemantic_ticks="
          ++ show (tickCount (ticks game))
          ++ "\ntrace_inputs="
          ++ show (length (traceInputs (runtimeSession state)))
          ++ "\nos_command_edges="
          ++ show (runtimeOsCommands state)
          ++ "\nos_held_frames="
          ++ show (runtimeOsHeldFrames state)
          ++ "\nfocus_loss_pauses="
          ++ show (runtimeFocusLosses state)
          ++ "\nsettings_volume="
          ++ show (localVolume (runtimeLocal state))
          ++ "\nsettings_music="
          ++ show (localMusic (runtimeLocal state))
          ++ "\nsettings_das="
          ++ show (localDas (runtimeLocal state))
          ++ "\nsettings_arr="
          ++ show (localArr (runtimeLocal state))
          ++ "\nui_event_order="
          ++ show (reverse (runtimeUiEvents state))
          ++ "\n"
          ++ audioStats
  putStrLn report
  forMOptional (optionShots options) (\directory -> writeSafe (directory </> "native-report.txt") report)
