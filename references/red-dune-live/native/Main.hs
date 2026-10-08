{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Colony.Content
import Colony.M1State (m1Space)
import Colony.Presentation (encodeJSON)
import Colony.Space qualified as Space
import Colony.Transport (ShipmentStatus (ShipmentDelivered), shipmentStatus, transportShipments)
import Colony.Units (Resource (Stone))
import Colony.World
import Control.DeepSeq (force)
import Control.Exception (IOException, bracket, catch, evaluate)
import Control.Monad (forM_, when)
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.List (find, intercalate, isPrefixOf, nub)
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
import RedDune.Native.Help qualified as Help
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.Native.View
import RedDune.Policies (assistConstruction, policiesEnabled)
import System.Directory
import System.Environment
import System.Exit (exitFailure)
import System.FilePath
import Text.Read (readMaybe)

data Options = Options {optionStore :: !FilePath, optionQa :: !(Maybe FilePath), optionFrames :: !(Maybe Int), optionPack :: !(Maybe FilePath), optionNew :: !(Maybe String), optionHidden :: !Bool}

data App = App {appScreen :: !Screen, appDebt :: !Double, appSavedRevision :: !Word64, appSaveTime :: !Double, appQaRead :: !Int, appFrames :: !Int, appQuit :: !Bool, appStarted :: !Bool, appNewPack :: !ContentPack, appQaMilestones :: !(M.Map String Double)}

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
      (preferences, preferenceNotice) <- Store.loadPreferences store
      initial <- either (ioError . userError) pure (startVillageGame scenario pack)
      game <- Store.prepareGame store initial
      let started = optionNew options /= Nothing || null (Store.catalogEntries catalog)
      when started (Store.saveGame store game >> pure ())
      let screen = (newScreen game (if started then NoDialog else Welcome catalog)) {screenSaved = started, screenHelpUi = Help.newHelpUi preferences, screenNotice = maybe "" id preferenceNotice}
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
          loop root options store font (App screen 0 (gameRevision game) 0 0 0 False started pack M.empty)
    `catch` ( \(errorValue :: IOException) -> do
                temp <- getTemporaryDirectory
                writeFile (temp </> "red-dune-startup-error.txt") (show errorValue)
                arguments <- getArgs
                when ("--hidden" `notElem` arguments) $
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
  let oldScreen = appScreen previous
      guidedScreen = if appStarted previous && isPlainScreen oldScreen then oldScreen {screenHelpUi = Help.refreshHint (hintForScreen oldScreen) (screenHelpUi oldScreen)} else oldScreen
      guided = previous {appScreen = guidedScreen}
  buttons <- drawing (drawView font width height time usedMouse guidedScreen)
  let click = nativeClick || qaClick /= Nothing
      command = if click then buttonCommand <$> find (inside usedMouse . buttonRect) (reverse buttons) else Nothing
  keyCommand <- keyboard guidedScreen
  let rawQaKey = case words qaLine of
        ["key", "space"] -> Just (Choose ToggleTime)
        ["key", "save"] -> Just SaveNow
        ["key", "escape"] -> Just CloseDialog
        ["key", "quit"] -> Just QuitGame
        ["key", "help"] -> Just (toggleHelp guidedScreen)
        _ -> Nothing
      qaKey = if isPlainScreen guidedScreen || maybe False (\key -> overlayCommand key || key == SaveNow && isNoDialog (screenDialog guidedScreen)) rawQaKey then rawQaKey else Nothing
      requested = firstJust [command, keyCommand, qaKey]
      stamped = guided {appQaRead = qaCount, appFrames = appFrames previous + 1}
  operated <- maybe (pure stamped) (perform store stamped) requested
  case (optionQa options, requested) of
    (Just folder, Just action) | isHelpEvent guidedScreen action -> do
      createDirectoryIfMissing True folder
      appendFile (folder </> "help-events.txt") (show action ++ " worldUnchanged=" ++ show (screenGame guidedScreen == screenGame (appScreen operated)) ++ "\n")
    _ -> pure ()
  let helpFrameHeld = Help.helpHoldsClock (screenHelpUi guidedScreen) (screenHelpUi (appScreen operated))
  cameraScreen0 <- if helpFrameHeld then pure (appScreen operated) else cameraInput (max 0 (min 0.1 dt)) (appScreen operated)
  let noticeAge = screenNoticeAge cameraScreen0 + dt
      persistent = any (`isPrefixOf` screenNotice cameraScreen0) ["操作を完了", "保存できない", "自動保存でき", "進行を停止", "厨房が故障"]
      cameraScreen = cameraScreen0 {screenCues = fadeCues dt (screenCues cameraScreen0), screenNoticeAge = noticeAge, screenNotice = if noticeAge > 8 && not persistent then "" else screenNotice cameraScreen0}
  selected <-
    if not helpFrameHeld && click && command == Nothing && isPlainScreen cameraScreen && usedMouseInMap width height cameraScreen usedMouse
      then case screenBuild cameraScreen of
        Just prototype -> do
          let tile = unproject width height (screenCamera cameraScreen) usedMouse
              shape = if prototype == "road" then Space.RoadShape tile else Space.BuildingShape prototype tile (screenBuildRotation cameraScreen)
              detail = lookup prototype [("detail-square", PlaceSquare), ("detail-bench", PlaceBench), ("detail-garden", PlaceGarden), ("detail-lantern", PlaceLantern)]
              commandForPlace = if prototype == "dining" then PlaceDining tile (screenBuildRotation cameraScreen) else if prototype == "detail-erase" then Choose (RemoveDetail tile) else maybe (Choose (Plan shape)) (\kind -> Choose (PlaceDetail kind tile (screenBuildRotation cameraScreen))) detail
          if prototype == "road"
            then case screenRoadStart cameraScreen of
              Nothing -> pure operated {appScreen = cameraScreen {screenRoadStart = Just tile, screenNotice = "道路の終点を選んでください。Escで取り消せます。"}}
              Just from -> perform store operated {appScreen = cameraScreen {screenRoadStart = Nothing}} (Choose (RoadPath from tile))
            else perform store operated {appScreen = cameraScreen} commandForPlace
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
  advanced <- if Help.helpHoldsClock (screenHelpUi guidedScreen) (screenHelpUi (appScreen attended)) then pure attended {appDebt = 0, appSaveTime = appSaveTime attended + dt} else advanceFrame (max 0 (min 0.1 dt)) attended
  preferred <- persistPreferences store (screenHelpUi oldScreen) advanced
  checkpointed <- autoSave store preferred
  saved <- recordMilestones options time checkpointed
  case (optionQa options, words qaLine) of
    (Just folder, ["capture", name]) | takeFileName name == name && takeExtension name == ".png" -> do
      createDirectoryIfMissing True folder
      _ <- drawing (drawView font width height time usedMouse (appScreen saved))
      captureFrame (folder </> name)
      writeFile (folder </> replaceExtension name "json") (encodeJSON (observeGame (screenGame (appScreen saved))))
      writeFile (folder </> replaceExtension name "dining.txt") (show (diningStatuses (screenGame (appScreen saved))))
      writeFile (folder </> replaceExtension name "places.txt") (show (gamePlaces (screenGame (appScreen saved))))
      writeFile (folder </> replaceExtension name "ui.txt") (uiSnapshot (appScreen saved))
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
recordMilestones :: Options -> Double -> App -> IO App
recordMilestones options time app = case optionQa options of
  Nothing -> pure app
  Just folder -> do
    let screen = appScreen app
        game = screenGame screen
        world = gameWorld game
        conditions = [("first-site-response", screenSelected screen /= Nothing), ("first-real-delivery", any ((== ShipmentDelivered) . shipmentStatus) (M.elems (transportShipments (worldTransport world)))), ("first-cooked-food-arrived", campaignFreshPantry (gameCampaign game)), ("dining-planned", not (M.null (gameDiningPlaces game))), ("dining-actual-use", any (not . null . diningMeals) (diningStatuses game))]
        fresh = [label | (label, ready) <- conditions, ready, M.notMember label (appQaMilestones app)]
    when (not (null fresh)) $ do
      createDirectoryIfMissing True folder
      forM_ fresh $ \label -> appendFile (folder </> "milestones.txt") (label ++ " windowSeconds=" ++ show time ++ " simTick=" ++ show (simTick world) ++ " speed=" ++ show (screenSpeed screen) ++ "\n")
    pure app {appQaMilestones = foldr (\label -> M.insert label time) (appQaMilestones app) fresh}

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

usedMouseInMap :: Int -> Int -> Screen -> Vector2 -> Bool
usedMouseInMap width height screen mouse@(Vector2 x y) = x >= 0 && x < fromIntegral width && y >= 100 && y < fromIntegral (height - 114) && (screenTab screen == ColonyTab && screenSelected screen == Nothing || x < fromIntegral (width - 406)) && not (Help.activeHint (screenHelpUi screen) /= Nothing && inside mouse hintRectangle)

toggleHelp :: Screen -> UiCommand
toggleHelp screen = HelpCommand (if Help.helpTopic (screenHelpUi screen) == Nothing then Help.OpenHelp (contextTopic screen) else Help.CloseHelp)

overlayCommand :: UiCommand -> Bool
overlayCommand command = case command of HelpCommand {} -> True; CloseDialog -> True; QuitGame -> True; _ -> False

isHelpEvent :: Screen -> UiCommand -> Bool
isHelpEvent screen command = case command of HelpCommand {} -> True; CloseDialog -> Help.helpTopic (screenHelpUi screen) /= Nothing; _ -> False

uiSnapshot :: Screen -> String
uiSnapshot screen = unlines ["tab=" ++ show (screenTab screen), "selected=" ++ show (screenSelected screen), "camera=" ++ show (screenCamera screen), "build=" ++ show (screenBuild screen), "rotation=" ++ show (screenBuildRotation screen), "roadStart=" ++ show (screenRoadStart screen), "speed=" ++ show (screenSpeed screen), "dialog=" ++ dialogName (screenDialog screen), "help=" ++ show (screenHelpUi screen)]
  where
    dialogName dialog = case dialog of NoDialog -> "none"; Welcome {} -> "welcome"; SaveLibrary _ page -> "library:" ++ show page; LoadPreview preview -> "preview:" ++ Store.previewName preview; DiningPreview tile rotation roads _ -> "dining:" ++ show (tile, rotation, roads); NewCampaign -> "new"; Introduction scenario -> "intro:" ++ scenario; Conclusion {} -> "conclusion"

persistPreferences :: Store.Store -> Help.HelpUi -> App -> IO App
persistPreferences store before app
  | Help.helpPreferences before == preferences = pure app
  | otherwise = do
      result <- ioResult (Store.savePreferences store preferences)
      pure $ case result of
        Right () -> app
        Left _ -> app {appScreen = (appScreen app) {screenNotice = "案内の設定を保存できませんでした。今回はこのまま使えます。", screenNoticeAge = 0}}
  where
    preferences = Help.helpPreferences (screenHelpUi (appScreen app))

keyboard :: Screen -> IO (Maybe UiCommand)
keyboard screen = do
  space <- isKeyPressed KeySpace
  save <- isKeyPressed KeyF5
  load <- isKeyPressed KeyF9
  escape <- isKeyPressed KeyEscape
  help <- isKeyPressed KeyF1
  rotate <- isKeyPressed KeyR
  speeds <- mapM isKeyPressed [KeyOne, KeyTwo, KeyThree, KeyFour]
  pure (if escape then Just CloseDialog else if help then Just (toggleHelp screen) else if save && isNoDialog (screenDialog screen) then Just SaveNow else if not (isPlainScreen screen) then Nothing else if space then Just (Choose ToggleTime) else if load then Just ShowLibrary else if rotate && canRotateBuild screen then Just RotateBuilding else ChangeSpeed . snd <$> find fst (zip speeds [1, 2, 4, 8]))

cameraInput :: Double -> Screen -> IO Screen
cameraInput dt screen
  | not (isPlainScreen screen) = pure screen
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
              then overviewCamera (screenGame screen)
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
  let handled = either (\_ -> app {appScreen = (appScreen app) {screenNotice = operationFailure command}}) id result
  pure handled {appScreen = (appScreen handled) {screenNoticeAge = 0}}

ioResult :: IO a -> IO (Either String a)
ioResult work = (Right <$> work) `catch` (\(errorValue :: IOException) -> pure (Left (show errorValue)))

operationFailure :: UiCommand -> String
operationFailure command = case command of
  SaveNow -> "保存できませんでした。保存先を確認し、F5でもう一度保存できます。"
  ReadSave {} -> "保存を読み込めませんでした。保存一覧で別の保存を選ぶか、もう一度確認してください。"
  ConfirmLoad -> "保存から再開できませんでした。保存一覧から選び直して、内容を確認してください。"
  ShowLibrary -> "保存一覧を開けませんでした。保存先を確認して、もう一度開けます。"
  _ -> "操作を完了できませんでした。画面を閉じて、選び直してからもう一度試せます。"

performUnchecked :: Store.Store -> App -> UiCommand -> IO App
performUnchecked store app command = case command of
  HelpCommand action -> pure ((update screen {screenHelpUi = Help.updateHelp action (screenHelpUi screen)}) {appDebt = 0})
  FocusDining (Space.Tile x y) -> pure (update screen {screenCamera = Camera (fromInteger x + 7.5) (fromInteger y - 4.5) 26 0, screenTab = DiningTab, screenSelected = Nothing, screenBuild = Nothing})
  PlaceDining tile rotation -> case planDining tile rotation game of
    Left failure -> pure (update screen {screenNotice = friendlyFailure failure})
    Right candidate -> do
      paused <- pauseGame game
      let roads = length [() | Space.RoadShape _ <- gameBuildQueue candidate] - length [() | Space.RoadShape _ <- gameBuildQueue game]
          cost = M.unionWith (+) (M.singleton Stone (2000 * fromIntegral roads)) (maybe M.empty buildingCost (M.lookup "pantry" (contentBuildings (worldContent (gameWorld game)))))
          Space.Tile x y = tile
      pure (update screen {screenGame = paused, screenCamera = Camera (fromInteger x + 7.5) (fromInteger y - 4.5) 26 0, screenBuild = Nothing, screenDialog = DiningPreview tile rotation roads cost, screenNotice = ""})
  ConfirmDining tile rotation -> case planDining tile rotation game of
    Left failure -> pure (update screen {screenDialog = NoDialog, screenNotice = friendlyFailure failure})
    Right candidate -> do
      resumed <- if worldMode (gameWorld candidate) == Paused then either (ioError . userError) pure (act [("op", "resume")] candidate) else pure candidate
      forced <- evaluate (force resumed)
      pure (update screen {screenGame = forced, screenBuild = Nothing, screenTab = DiningTab, screenDialog = NoDialog, screenNotice = "食事の場を計画しました。道路と建設が進み、厨房から料理を運びます。", screenSaved = False})
  BeginWork ident -> case decide (StartSite ident) game >>= (\candidate -> if worldMode (gameWorld candidate) == Paused then act [("op", "resume")] candidate else Right candidate) of
    Left failure -> pure (update screen {screenNotice = friendlyFailure failure})
    Right candidate -> do
      forced <- evaluate (force candidate)
      pure (update screen {screenGame = forced, screenNotice = "班を配置しました。作業と配送が進みます。", screenSaved = False})
  HomeView -> pure (update screen {screenCamera = overviewCamera game, screenSelected = Nothing, screenTab = ColonyTab, screenBuild = Nothing, screenRoadStart = Nothing})
  Choose decision -> case decide decision game of
    Left failure -> pure (update screen {screenNotice = decisionFailure game decision failure})
    Right candidate -> do
      let builds = case decision of Plan _ -> True; RoadPath _ _ -> True; _ -> False
          queued = if builds then candidate {gamePolicies = (gamePolicies candidate) {policiesEnabled = True, assistConstruction = True}} else candidate
      resumed <- if builds && worldMode (gameWorld queued) == Paused then either (ioError . userError) pure (act [("op", "resume")] queued) else pure queued
      forced <- evaluate (force resumed)
      pure (update screen {screenGame = forced, screenNotice = decisionMessage decision, screenSaved = gameRevision forced == appSavedRevision app, screenBuild = case decision of Plan (Space.BuildingShape {}) -> Nothing; _ -> screenBuild screen})
  SelectSite ident -> do
    let placement = worldM1 (gameWorld game) >>= M.lookup ident . Space.spatialPlacements . m1Space
        camera = case placement of
          Just target -> case Space.placementShape target of
            Space.BuildingShape name (Space.Tile x y) _ ->
              let (bw, bh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent (gameWorld game))))
               in homeCamera {cameraX = fromInteger x + fromInteger bw / 2 + 6, cameraY = fromInteger y + fromInteger bh / 2 - 6, cameraScale = 22}
            _ -> screenCamera screen
          _ -> screenCamera screen
    pure (update screen {screenSelected = Just ident, screenStockPage = 0, screenTab = ColonyTab, screenCamera = camera})
  ClearSelection -> pure (update screen {screenSelected = Nothing, screenTab = ColonyTab, screenBuild = Nothing, screenRoadStart = Nothing})
  SelectTab tab -> pure (update screen {screenTab = tab, screenBuild = if tab `elem` [BuildingTab, PlacesTab] then screenBuild screen else Nothing, screenRoadStart = Nothing})
  SelectBuild name -> do
    let cost = if name == "road" then M.singleton Stone 2000 else maybe M.empty buildingCost (M.lookup name (contentBuildings (worldContent (gameWorld game))))
        costText = intercalate " / " [resourceName resource ++ " " ++ resourceAmount resource amount | (resource, amount) <- M.toAscList cost]
    pure (update screen {screenBuild = Just name, screenDialog = NoDialog, screenRoadStart = Nothing, screenNotice = if take 7 name == "detail-" then "好きな場所へ置く / Rで向き / Escで戻る" else if name == "road" then "道路の始点、終点を順に選ぶ / Escで戻る" else if name == "dining" then "好きな場所を選ぶ / 向きを変える / 費用を確認して確定" else siteName name ++ "を配置：" ++ costText ++ " / Esc で解除"})
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
      pure app {appScreen = screen {screenGame = candidate, screenSelected = Nothing, screenBuild = Nothing, screenCamera = openingCamera candidate, screenTab = ColonyTab, screenDialog = NoDialog, screenHelpUi = Help.resumedHelpUi (Help.helpPreferences (screenHelpUi screen)), screenNotice = "元の保存を残し、新しい履歴で再開しました。時間は一時停止です。", screenSaved = True}, appDebt = 0, appSavedRevision = gameRevision candidate, appSaveTime = 0, appStarted = True}
    _ -> pure app
  CloseDialog ->
    if Help.helpTopic (screenHelpUi screen) /= Nothing
      then pure ((update screen {screenHelpUi = Help.updateHelp Help.CloseHelp (screenHelpUi screen)}) {appDebt = 0})
      else
        if appStarted app
          then pure (update screen {screenDialog = NoDialog, screenBuild = Nothing, screenRoadStart = Nothing, screenSelected = Nothing, screenTab = ColonyTab, screenNotice = ""})
          else do
            catalog <- Store.latestCheckpointCatalog store
            pure (update screen {screenDialog = Welcome catalog, screenBuild = Nothing, screenNotice = ""})
  ShowNewCampaign -> do
    paused <- pauseGame game
    pure (update screen {screenGame = paused, screenDialog = NewCampaign, screenBuild = Nothing})
  StartScenario scenario -> do
    when (appStarted app) (Store.saveGame store game >> pure ())
    original <- either (ioError . userError) pure (startVillageGame scenario (appNewPack app))
    candidate <- Store.activateGame store original
    pure app {appScreen = screen {screenGame = candidate, screenTab = ColonyTab, screenSelected = Nothing, screenBuild = Nothing, screenCamera = openingCamera candidate, screenSpeed = 4, screenDialog = NoDialog, screenNotice = "", screenSaved = True}, appDebt = 0, appSavedRevision = gameRevision candidate, appSaveTime = 0, appStarted = True, appQaMilestones = M.empty}
  QuitGame -> pure app {appQuit = True}
  where
    screen = appScreen app
    game = screenGame screen
    update next = app {appScreen = next}

pauseGame :: GameState -> IO GameState
pauseGame game = if worldMode (gameWorld game) == Active then either (ioError . userError) pure (act [("op", "pause")] game) else pure game

advanceFrame :: Double -> App -> IO App
advanceFrame dt app
  | not (isPlainScreen screen) || worldMode world /= Active = pure app {appDebt = 0, appSaveTime = appSaveTime app + dt}
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
              firstDining = not (any (not . null . diningMeals) (diningStatuses game)) && any (not . null . diningMeals) (diningStatuses forced)
              firstDelivery = not (campaignFreshPantry before) && campaignFreshPantry after
          stopped <- if alarm || ending then pauseGame forced else pure forced
          pure
            app
              { appScreen =
                  screen
                    { screenGame = stopped,
                      screenCues = take 8 (worldFeedback game stopped ++ screenCues screen),
                      screenSaved = gameRevision stopped == appSavedRevision app,
                      screenDialog = if ending then Conclusion stopped else screenDialog screen,
                      screenNoticeAge = if firstDining || firstDelivery || newlyBroken then 0 else screenNoticeAge screen,
                      screenNotice = if newlyBroken then "厨房が故障しました。配給の備蓄と保守班を確認してください。" else if ending then fst (advice stopped) else if firstDining then "住民が、ここで料理を食べました。周りを飾ってみよう。" else if firstDelivery then "厨房の料理が届きました。食事の場をつくれます。" else screenNotice screen
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
  PlaceDetail _ _ _ -> "この場所に置きました。並べ方や向きは自由に変えられます。"
  RemoveDetail _ -> "この場所を片付けました。"
  RoadPath _ _ -> "道路の計画を受け付けました。建材と班が現場を進めます。"
  StartSite _ -> "班と配送を準備しました。作業と運搬を見守りましょう。"
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

decisionFailure :: GameState -> Decision -> String -> String
decisionFailure game decision failure = case decision of
  RoadPath _ _
    | failure == "Road plan must be at most 64 tiles and wait for the current queue" ->
        if null (gameBuildQueue game) then "道路は1回に64マスまで計画できます。もっと近い終点を選んでください。" else friendlyFailure "Wait for the current construction queue"
  _ -> friendlyFailure failure

friendlyFailure :: String -> String
friendlyFailure failure
  | Just explanation <- lookup failure ordinaryFailures = explanation
  | "Workforce" `contains` failure || "workers" `contains` failure || "people" `contains` failure = "班を配置できません。ほかの施設の割り当てと、作業中の人員を確認してください。"
  | "Conflict" `contains` failure || "Outside" `contains` failure || "Placement" `contains` failure = "ここには配置できません。建物・道路・地形と重ならない場所を選んでください。"
  | "already queued" `contains` failure = "予備倉庫の建設をすでに計画しています。現在の工事を確認してください。"
  | otherwise = "操作を受け付けられませんでした：" ++ take 80 failure
  where
    ordinaryFailures =
      [ ("Wait for the current construction queue", "先に計画した道路・施設の着工待ちです。着工が進んでから、もう一度場所を選べます。"),
        ("Expansion is already queued", "先に計画した道路・施設の着工待ちです。着工が進んでから、もう一度計画できます。"),
        ("This colony already has a dining place", "食事の場はすでに計画されています。「食事の場」から場所を確認できます。"),
        ("Dining footprint overlaps placed scenery", "飾りと重なっています。先に片づけるか、別の場所を選んでください。"),
        ("Place overlaps a building or planned road", "建物や計画中の道路と重なっています。空いた地面を選んでください。"),
        ("Place overlaps a queued building or road", "計画中の建物や道路と重なっています。空いた地面を選んでください。"),
        ("Keep the transport road clear", "荷車が通る道路には置けません。道の横を選んでください。"),
        ("Keep placed furniture out of the road", "道路に飾りが重なっています。飾りを片づけるか、別の終点を選んでください。"),
        ("No road route reaches this dining place", "ここへつながる道路を計画できません。厨房の道路に近い、空いた場所を選んでください。"),
        ("Dining connector cannot reach the kitchen road", "厨房の道路へつなげられません。空いた地面が続く場所を選んでください。"),
        ("Dining road must fit the 64-stage construction queue", "厨房から遠すぎます。1回に道路と施設を合わせて64マスまで計画できます。もっと近い場所を選んでください。"),
        ("Dining transport workers are unavailable", "食事の場へ運ぶ人を配置できません。ほかの施設の班を確認し、担当を外してから試してください。"),
        ("Supply route has not been commissioned", "この配送はまだ準備されていません。送り元の施設を選んで、班と配送を準備してください。"),
        ("Campaign ended; restart or restore to play", "この開拓は区切りを迎えました。保存一覧から以前の続きに戻るか、新しい開拓を選べます。"),
        ("Cannot configure staffing while workers belong to other targets; release their assignments first", "ほかの施設に担当がいます。その施設の班を外してから、配置し直してください。")
      ]
    contains needle haystack = any (needle `prefix`) (tails haystack)
    prefix a b = take (length a) b == a
    tails [] = [[]]; tails value@(_ : rest) = value : tails rest

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
