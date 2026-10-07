{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Colony.Content
import Colony.Presentation (encodeJSON)
import Colony.Space qualified as Space
import Colony.Units (Resource (Stone))
import Colony.World
import Control.DeepSeq (force)
import Control.Exception (IOException, bracket, catch, evaluate)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.List (find, intercalate, nub)
import Data.Map.Strict qualified as M
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Foreign (castPtr)
import Foreign.C (withCString)
import GHC.IO.Encoding (setForeignEncoding, setLocaleEncoding, utf8)
import Raylib.Core
import Raylib.Core.Textures (c'exportImage, c'loadImageFromScreen, c'unloadImage, loadImage)
import Raylib.Internal.Foreign (c'free)
import Raylib.Types (ConfigFlag (..), KeyboardKey (..), MouseButton (..), Vector2, pattern Vector2)
import Raylib.Util (drawing, withWindow)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.Native.Font (NativeFont, fontFace, loadNativeFont, unloadNativeFont)
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.Native.View
import System.Directory
import System.Environment
import System.Exit (exitFailure)
import System.FilePath
import Text.Read (readMaybe)

data Options = Options {optionStore :: !FilePath, optionQa :: !(Maybe FilePath), optionFrames :: !(Maybe Int), optionPack :: !(Maybe FilePath), optionNew :: !(Maybe String), optionHidden :: !Bool}

data App = App {appScreen :: !Screen, appDebt :: !Double, appSavedRevision :: !Word64, appSaveTime :: !Double, appQaRead :: !Int, appFrames :: !Int, appQuit :: !Bool, appStarted :: !Bool, appNewPack :: !ContentPack}

main :: IO ()
main =
  do
    setLocaleEncoding utf8
    setForeignEncoding utf8
    arguments <- getArgs
    executable <- getExecutablePath
    let root = takeDirectory executable
    local <- lookupEnv "LOCALAPPDATA"
    configured <- lookupEnv "RED_DUNE_NATIVE_STORE"
    let fallback = maybe (root </> "saves") (\path -> path </> "RedDune" </> "saves") local
    options <- either (ioError . userError) pure (parseOptions (Options (maybe fallback id configured) Nothing Nothing Nothing Nothing False) arguments)
    pack <- case optionPack options of
      Nothing -> pure defaultPack
      Just path -> do
        bytes <- BS.readFile path
        source <- either (ioError . userError . show) pure (TE.decodeUtf8' bytes)
        checked <- evaluate (force (decodePack (T.unpack source)))
        either (ioError . userError) pure checked
    let scenario = maybe "settlement" id (optionNew options)
    Store.withStore (optionStore options) $ \store -> do
      catalog <- Store.latestCheckpointCatalog store
      initial <- either (ioError . userError) pure (startGame scenario pack)
      game <- Store.prepareGame store initial
      let started = optionNew options /= Nothing || null (Store.catalogEntries catalog)
      when started (Store.saveGame store game >> pure ())
      let screen = (newScreen game (if started then Introduction scenario else Welcome catalog)) {screenSaved = started}
      setConfigFlags ([Msaa4xHint, WindowResizable, VsyncHint] ++ [WindowHidden | optionHidden options])
      withWindow 1440 940 "Red Dune" 60 $ \_resources -> do
        setWindowMinSize 1280 880
        setExitKey KeyNull
        let iconPath = root </> "assets" </> "icon.png"
        iconExists <- doesFileExist iconPath
        when iconExists (loadImage iconPath >>= setWindowIcon)
        glyphText <- readFile (root </> "assets" </> "glyphs.txt")
        let glyphs = nub ([32 .. 126] ++ map ord glyphText)
        fontFile <- findFont
        fontBytes <- BS.readFile fontFile >>= either (ioError . userError) pure . fontFace
        bracket (loadNativeFont fontBytes glyphs) unloadNativeFont $ \font -> do
          loop root options store font (App screen 0 (gameRevision game) 0 0 0 False started pack)
    `catch` ( \(errorValue :: IOException) -> do
                temp <- getTemporaryDirectory
                writeFile (temp </> "red-dune-startup-error.txt") (show errorValue)
                Store.showNativeError ("Red Dune を起動できませんでした。\n保存先がほかのウィンドウで使用中なら、その開拓を閉じてから再度起動してください。\n\n" ++ show errorValue)
                exitFailure
            )

parseOptions :: Options -> [String] -> Either String Options
parseOptions options [] = Right options
parseOptions options ("--store" : path : rest) = parseOptions options {optionStore = path} rest
parseOptions options ("--qa-dir" : path : rest) = parseOptions options {optionQa = Just path} rest
parseOptions options ("--pack" : path : rest) = parseOptions options {optionPack = Just path} rest
parseOptions options ("--new" : scenario : rest)
  | scenario `elem` ["settlement", "recovery"] = parseOptions options {optionNew = Just scenario} rest
  | otherwise = Left "Unknown scenario"
parseOptions options ("--hidden" : rest) = parseOptions options {optionHidden = True} rest
parseOptions options ("--frames" : number : rest) = case readMaybe number of Just n | n > 0 -> parseOptions options {optionFrames = Just n} rest; _ -> Left "Invalid frame limit"
parseOptions _ _ = Left "Red Dune: --store DIRECTORY [--pack FILE] [--new settlement|recovery] [--qa-dir DIRECTORY] [--frames NUMBER] [--hidden]"

findFont :: IO FilePath
findFont = do
  system <- lookupEnv "WINDIR"
  let root = maybe "C:/Windows" id system
  choices <- filterMFile [root </> "Fonts" </> "meiryo.ttc", root </> "Fonts" </> "YuGothM.ttc", root </> "Fonts" </> "msgothic.ttc"]
  case choices of { path : _ -> pure path; _ -> ioError (userError "A Windows Japanese system font is required") }
  where
    filterMFile [] = pure []; filterMFile (path : rest) = do present <- doesFileExist path; remaining <- filterMFile rest; pure ([path | present] ++ remaining)

loop :: FilePath -> Options -> Store.Store -> NativeFont -> App -> IO ()
loop root options store font previous = do
  width <- getScreenWidth
  height <- getScreenHeight
  dt <- realToFrac <$> getFrameTime
  time <- getTime
  mouse <- getMousePosition
  nativeClick <- isMouseButtonPressed MouseButtonLeft
  close <- windowShouldClose
  focused <- isWindowFocused
  qa <- readQa options (appQaRead previous)
  let (qaCount, qaLine) = qa
      qaClick = case words qaLine of ["click", x, y] -> Vector2 <$> readMaybe x <*> readMaybe y; _ -> Nothing
      usedMouse = maybe mouse id qaClick
  case words qaLine of
    ["window", w, h]
      | Just newWidth <- readMaybe w,
        Just newHeight <- readMaybe h,
        newWidth >= 1280,
        newHeight >= 880,
        newWidth <= 3840,
        newHeight <= 2160 ->
          setWindowSize newWidth newHeight
    _ -> pure ()
  buttons <- drawing (drawView font width height time usedMouse (appScreen previous))
  let click = nativeClick || qaClick /= Nothing
      command = if click then buttonCommand <$> find (inside usedMouse . buttonRect) (reverse buttons) else Nothing
  keyCommand <- keyboard (appScreen previous)
  let rawQaKey = case words qaLine of
        ["key", "space"] -> Just (Choose ToggleTime)
        ["key", "save"] -> Just SaveNow
        ["key", "escape"] -> Just CloseDialog
        ["key", "quit"] -> Just QuitGame
        _ -> Nothing
      qaKey = if isNoDialog (screenDialog (appScreen previous)) || rawQaKey `elem` [Just CloseDialog, Just QuitGame] then rawQaKey else Nothing
      requested = firstJust [command, keyCommand, qaKey]
      stamped = previous {appQaRead = qaCount, appFrames = appFrames previous + 1}
  operated <- maybe (pure stamped) (perform store stamped) requested
  cameraScreen <- cameraInput (max 0 (min 0.1 dt)) (appScreen operated)
  selected <-
    if click && command == Nothing && isNoDialog (screenDialog cameraScreen) && usedMouseInMap width height usedMouse
      then case screenBuild cameraScreen of
        Just prototype -> do
          let tile = unproject width height (screenCamera cameraScreen) usedMouse
              shape = if prototype == "road" then Space.RoadShape tile else Space.BuildingShape prototype tile (screenBuildRotation cameraScreen)
          perform store operated {appScreen = cameraScreen} (Choose (Plan shape))
        Nothing -> pure operated {appScreen = cameraScreen {screenSelected = placementAt (screenGame cameraScreen) (unproject width height (screenCamera cameraScreen) usedMouse), screenTab = ColonyTab}}
      else pure operated {appScreen = cameraScreen}
  attended <-
    -- Opt-in replay runs while build tools have focus. Ordinary owner play
    -- pauses on focus loss; replay still uses the same real-time clock.
    if not focused && optionQa options == Nothing && worldMode (gameWorld (screenGame (appScreen selected))) == Active
      then do
        paused <- pauseGame (screenGame (appScreen selected))
        pure selected {appScreen = (appScreen selected) {screenGame = paused, screenSaved = False, screenNotice = "ウィンドウを離れたため、一時停止しました。"}, appDebt = 0}
      else pure selected
  advanced <- advanceFrame (max 0 (min 0.1 dt)) attended
  saved <- autoSave store advanced
  case (optionQa options, words qaLine) of
    (Just folder, ["capture", name]) | takeFileName name == name && takeExtension name == ".png" -> do
      createDirectoryIfMissing True folder
      _ <- drawing (drawView font width height time usedMouse (appScreen saved))
      captureFrame (folder </> name)
      writeFile (folder </> replaceExtension name "json") (encodeJSON (observeGame (screenGame (appScreen saved))))
      writeFile (folder </> replaceExtension name "meta.txt") (unlines ["Actual native GPU capture; synthetic pointer/key replay", "size=" ++ show width ++ "x" ++ show height, "frameSeconds=" ++ show dt, "windowSeconds=" ++ show time, "frames=" ++ show (appFrames saved), "focused=" ++ show focused, "replay suspends automatic focus pausing; default owner play pauses"])
    _ -> pure ()
  let finished = appQuit saved || close || maybe False (appFrames saved >=) (optionFrames options)
  if finished
    then do
      result <- ioResult (when (appStarted saved && not (screenSaved (appScreen saved))) (Store.saveGame store (screenGame (appScreen saved)) >> pure ()))
      case result of
        Right () -> pure ()
        Left failure -> do
          paused <- pauseGame (screenGame (appScreen saved))
          loop root options store font saved {appQuit = False, appScreen = (appScreen saved) {screenGame = paused, screenNotice = "保存できないため、終了を止めました。F5で再試行してください：" ++ take 60 failure}}
    else loop root options store font saved

-- TakeScreenshot prefixes raylib's fixed startup path. Export the actual
-- framebuffer directly, retaining its native buffer for this bounded QA call.
captureFrame :: FilePath -> IO ()
captureFrame path = bracket c'loadImageFromScreen (\frame -> c'unloadImage frame >> c'free (castPtr frame)) $ \frame ->
  withCString path $ \filename -> do
    exported <- c'exportImage frame filename
    when (exported == 0) (ioError (userError "Native GPU capture could not be saved"))

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (_ : rest) = firstJust rest

isNoDialog :: Dialog -> Bool
isNoDialog NoDialog = True
isNoDialog _ = False

usedMouseInMap :: Int -> Int -> Vector2 -> Bool
usedMouseInMap width height (Vector2 x y) = x >= 0 && x < fromIntegral (width - 370) && y >= 85 && y < fromIntegral (height - 150)

keyboard :: Screen -> IO (Maybe UiCommand)
keyboard screen = do
  space <- isKeyPressed KeySpace
  save <- isKeyPressed KeyF5
  load <- isKeyPressed KeyF9
  escape <- isKeyPressed KeyEscape
  rotate <- isKeyPressed KeyR
  speeds <- mapM isKeyPressed [KeyOne, KeyTwo, KeyThree, KeyFour]
  pure (if escape then Just CloseDialog else if not (isNoDialog (screenDialog screen)) then Nothing else if space then Just (Choose ToggleTime) else if save then Just SaveNow else if load then Just ShowLibrary else if rotate then Just RotateBuilding else ChangeSpeed . snd <$> find fst (zip speeds [1, 2, 4, 8]))

cameraInput :: Double -> Screen -> IO Screen
cameraInput dt screen
  | not (isNoDialog (screenDialog screen)) = pure screen
  | otherwise = do
      up <- isKeyDown KeyW
      down <- isKeyDown KeyS
      left <- isKeyDown KeyA
      right <- isKeyDown KeyD
      q <- isKeyPressed KeyQ
      e <- isKeyPressed KeyE
      f <- isKeyPressed KeyF
      zoom <- getMouseWheelMove
      let camera = screenCamera screen
          next =
            if f
              then homeCamera
              else
                camera
                  { cameraX = cameraX camera + realToFrac dt * 25 * (if right then 1 else 0) - realToFrac dt * 25 * (if left then 1 else 0),
                    cameraY = cameraY camera + realToFrac dt * 25 * (if down then 1 else 0) - realToFrac dt * 25 * (if up then 1 else 0),
                    cameraRotation = cameraRotation camera + (if q then -1 else 0) + (if e then 1 else 0),
                    cameraScale = max 4 (min 30 (cameraScale camera + zoom))
                  }
      pure screen {screenCamera = next}

perform :: Store.Store -> App -> UiCommand -> IO App
perform store app command = do
  result <- ioResult (performUnchecked store app command)
  pure (either (\message -> app {appScreen = (appScreen app) {screenNotice = "操作を完了できませんでした：" ++ take 100 message}}) id result)

ioResult :: IO a -> IO (Either String a)
ioResult work = (Right <$> work) `catch` (\(errorValue :: IOException) -> pure (Left (show errorValue)))

performUnchecked :: Store.Store -> App -> UiCommand -> IO App
performUnchecked store app command = case command of
  Choose decision -> case decide decision game of
    Left failure -> pure (update screen {screenNotice = friendlyFailure failure})
    Right candidate -> do
      forced <- evaluate (force candidate)
      pure (update screen {screenGame = forced, screenNotice = decisionMessage decision, screenSaved = False})
  SelectSite ident -> pure (update screen {screenSelected = Just ident, screenStockPage = 0, screenTab = ColonyTab})
  ClearSelection -> pure (update screen {screenSelected = Nothing})
  SelectTab tab -> pure (update screen {screenTab = tab, screenBuild = if tab == BuildingTab then screenBuild screen else Nothing})
  SelectBuild name -> do
    let cost = if name == "road" then M.singleton Stone 2000 else maybe M.empty buildingCost (M.lookup name (contentBuildings (worldContent (gameWorld game))))
        costText = intercalate " / " [resourceName resource ++ " " ++ resourceAmount resource amount | (resource, amount) <- M.toAscList cost]
    pure (update screen {screenBuild = Just name, screenNotice = siteName name ++ "を配置：" ++ costText ++ " / Esc で解除"})
  ChangeSpeed speed -> pure (update screen {screenSpeed = speed})
  PalettePage page -> pure (update screen {screenPalettePage = max 0 page})
  SupplyPage page -> pure (update screen {screenSupplyPage = max 0 page})
  StockPage page -> pure (update screen {screenStockPage = max 0 page})
  RotateBuilding -> pure (update screen {screenBuildRotation = toEnum ((fromEnum (screenBuildRotation screen) + 1) `mod` 4)})
  ToggleAlerts -> pure (update screen {screenAutoPause = not (screenAutoPause screen)})
  SaveNow -> do
    _ <- Store.saveGame store game
    pure app {appScreen = screen {screenNotice = "開拓を保存しました。", screenSaved = True}, appSavedRevision = gameRevision game, appSaveTime = 0}
  ShowLibrary -> do
    paused <- pauseGame game
    entries <- Store.checkpointPage store 0
    pure (update screen {screenGame = paused, screenDialog = SaveLibrary entries 0, screenBuild = Nothing})
  LibraryPage page -> case screenDialog screen of
    SaveLibrary _ _ -> do
      entries <- Store.checkpointPage store page
      pure (update screen {screenDialog = SaveLibrary entries page})
    _ -> pure app
  ReadSave name -> do
    preview <- Store.previewCheckpoint store name
    pure (update screen {screenDialog = LoadPreview preview})
  ConfirmLoad -> case screenDialog screen of
    LoadPreview preview -> do
      when (appStarted app) (Store.saveGame store game >> pure ())
      candidate <- Store.confirmCheckpoint store preview
      pure app {appScreen = screen {screenGame = candidate, screenSelected = Nothing, screenBuild = Nothing, screenTab = ColonyTab, screenDialog = NoDialog, screenNotice = "新しい履歴で再開しました。時間は一時停止です。", screenSaved = True}, appDebt = 0, appSavedRevision = gameRevision candidate, appSaveTime = 0, appStarted = True}
    _ -> pure app
  CloseDialog ->
    if appStarted app
      then pure (update screen {screenDialog = NoDialog, screenBuild = Nothing, screenNotice = ""})
      else do
        catalog <- Store.latestCheckpointCatalog store
        pure (update screen {screenDialog = Welcome catalog, screenBuild = Nothing, screenNotice = ""})
  ShowNewCampaign -> do
    paused <- pauseGame game
    pure (update screen {screenGame = paused, screenDialog = NewCampaign, screenBuild = Nothing})
  StartScenario scenario -> do
    when (appStarted app) (Store.saveGame store game >> pure ())
    original <- either (ioError . userError) pure (startGame scenario (appNewPack app))
    candidate <- Store.activateGame store original
    pure app {appScreen = screen {screenGame = candidate, screenTab = ColonyTab, screenSelected = Nothing, screenBuild = Nothing, screenCamera = homeCamera, screenSpeed = 1, screenDialog = Introduction scenario, screenNotice = "", screenSaved = True}, appDebt = 0, appSavedRevision = gameRevision candidate, appSaveTime = 0, appStarted = True}
  QuitGame -> pure app {appQuit = True}
  where
    screen = appScreen app
    game = screenGame screen
    update next = app {appScreen = next}

pauseGame :: GameState -> IO GameState
pauseGame game = if worldMode (gameWorld game) == Active then either (ioError . userError) pure (act [("op", "pause")] game) else pure game

advanceFrame :: Double -> App -> IO App
advanceFrame dt app
  | not (isNoDialog (screenDialog screen)) || worldMode world /= Active = pure app {appDebt = 0, appSaveTime = appSaveTime app + dt}
  | otherwise = do
      let total = min 16 (appDebt app + dt * 20 * fromIntegral (screenSpeed screen)); count = min 8 (floor total)
      case advanceGame count game of
        Left failure -> do
          paused <- pauseGame game
          pure app {appScreen = screen {screenGame = paused, screenNotice = "進行を停止しました：" ++ take 100 failure}, appDebt = 0}
        Right candidate -> do
          forced <- evaluate (force candidate)
          let before = gameCampaign game
              after = gameCampaign forced
              newlyBroken = not (campaignDisrupted before) && campaignDisrupted after
              alarm = screenAutoPause screen && newlyBroken
              ending = campaignEnding before /= campaignEnding after
          stopped <- if alarm || ending then pauseGame forced else pure forced
          pure
            app
              { appScreen =
                  screen
                    { screenGame = stopped,
                      screenSaved = gameRevision stopped == appSavedRevision app,
                      screenDialog = if ending then Conclusion stopped else screenDialog screen,
                      screenNotice = if newlyBroken then "厨房が故障しました。配給の備蓄と保守班を確認してください。" else if ending then fst (advice stopped) else screenNotice screen
                    },
                appDebt = if alarm then 0 else total - fromIntegral count,
                appSaveTime = appSaveTime app + dt
              }
  where
    screen = appScreen app; game = screenGame screen; world = gameWorld game

autoSave :: Store.Store -> App -> IO App
autoSave store app
  | appSaveTime app < 30 || gameRevision game == appSavedRevision app = pure app
  | otherwise = do
      result <- ioResult (Store.saveGame store game)
      pure
        ( case result of
            Left failure -> app {appSaveTime = 0, appScreen = screen {screenNotice = "自動保存できませんでした：" ++ take 80 failure}}
            Right _ -> app {appSaveTime = 0, appSavedRevision = gameRevision game, appScreen = screen {screenSaved = True}}
        )
  where
    screen = appScreen app; game = screenGame screen

decisionMessage :: Decision -> String
decisionMessage decision = case decision of
  Commission WaterWorks -> "井戸・配給所・運搬班を配置しました。時間を進めて、配送を見守りましょう。"
  Commission FoodWorks -> "農場と厨房の班を配置しました。作物が育ち、食事になり、運ばれていきます。"
  Commission ServiceWorks -> "建設と保守の予備班を準備しました。修復を優先して作業します。"
  ReserveWarehouse -> "予備倉庫と道路を計画しました。物資と班がそろうと工事が進みます。"
  Plan _ -> "建設計画を置きました。完成には材料・配送・建設班が必要です。"
  CancelPlan _ -> "計画を取り消しました。返却可能な物資は通常の経路で戻ります。"
  ToggleDelivery _ -> "配送方針を変更しました。運搬中の荷はそのまま進みます。"
  ChangeBuffer _ _ -> "配送先の目標備蓄を変更しました。次の配送から反映されます。"
  StaffFacility _ -> "三交代の班を配置しました。"
  ReleaseFacility _ -> "施設の班を解放しました。"
  ConnectFacility _ -> "材料と出荷の配送計画をつなぎました。道路と運搬班がそろうと、物資が動きます。"
  _ -> "方針を変更しました。"

friendlyFailure :: String -> String
friendlyFailure failure
  | "Workforce" `contains` failure || "workers" `contains` failure || "people" `contains` failure = "班を配置できません。ほかの施設の割り当てと、作業中の人員を確認してください。"
  | "Conflict" `contains` failure || "Outside" `contains` failure || "Placement" `contains` failure = "ここには配置できません。建物・道路・地形と重ならない場所を選んでください。"
  | "already queued" `contains` failure = "予備倉庫の建設をすでに計画しています。現在の工事を確認してください。"
  | otherwise = "操作を受け付けられませんでした：" ++ take 80 failure
  where
    contains needle haystack = any (needle `prefix`) (tails haystack); prefix a b = take (length a) b == a; tails [] = [[]]; tails value@(_ : rest) = value : tails rest

-- Opt-in QA supplies raw pointer/key events to the ordinary hit-test path.
-- It cannot edit state or advance the clock; it also captures actual GPU frames.
readQa :: Options -> Int -> IO (Int, String)
readQa options consumed = case optionQa options of
  Nothing -> pure (consumed, "")
  Just folder ->
    ( do
        let path = folder </> "input.txt"
        exists <- doesFileExist path
        if not exists
          then pure (consumed, "")
          else do
            content <- readFile path
            _ <- evaluate (length content)
            let complete = if null content || last content == '\n' then lines content else init (lines content)
                pending = drop consumed complete
            case pending of { value : _ -> pure (consumed + 1, value); _ -> pure (consumed, "") }
    )
      `catch` (\(_ :: IOException) -> pure (consumed, ""))
