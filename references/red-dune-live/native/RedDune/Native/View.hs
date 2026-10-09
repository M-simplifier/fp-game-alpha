{-# LANGUAGE PatternSynonyms #-}

module RedDune.Native.View where

import Colony.Construction qualified as C
import Colony.Content
import Colony.M1State
import Colony.Maintenance
import Colony.Needs hiding (fraction)
import Colony.S01Fixture
import Colony.Space qualified as S
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Monad (foldM, forM, forM_, void, when)
import Data.List (find, foldl', isInfixOf, sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as Set
import Data.Word (Word64)
import Raylib.Core
import Raylib.Core.Shapes
import Raylib.Types (Color (..), Rectangle (..), Vector2, pattern Vector2)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.Native.Font (NativeFont, drawNativeText, measureNativeText)
import RedDune.Native.Help qualified as Help
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.Policies qualified as P
import Text.Printf (printf)

data Tab = ColonyTab | SupplyTab | BuildingTab | PeopleTab | PlacesTab | DiningTab deriving (Eq, Show, Read, Enum, Bounded)

data Camera = Camera {cameraX :: !Float, cameraY :: !Float, cameraScale :: !Float, cameraRotation :: !Int} deriving (Eq, Show)

homeCamera :: Camera
homeCamera = Camera 83 48 14 0

openingCamera :: GameState -> Camera
openingCamera game = case worldM1 (gameWorld game) >>= M.lookup pantry . S.spatialPlacements . m1Space of
  Just placement -> case S.placementShape placement of
    S.BuildingShape _ (S.Tile x y) _ -> Camera (fromInteger x) (fromInteger y) 24 0
    _ -> homeCamera
  _ -> homeCamera
  where
    Owner _ pantry = s01Pantry (gameDescriptor game)

overviewCamera :: GameState -> Camera
overviewCamera game = case points of
  [] -> homeCamera
  _ ->
    let xs = map fst points; ys = map snd points
     in Camera ((minimum xs + maximum xs) / 2) ((minimum ys + maximum ys) / 2) (min 22 (1000 / max 1 (maximum xs - minimum xs + maximum ys - minimum ys))) 0
  where
    points = [(fromInteger x, fromInteger y) | state <- maybe [] (: []) (worldM1 (gameWorld game)), placement <- M.elems (S.spatialPlacements (m1Space state)), S.BuildingShape _ (S.Tile x y) _ <- [S.placementShape placement]]

data Dialog = NoDialog | Introduction String | Welcome Store.Catalog | SaveLibrary Store.Catalog Int | LoadPreview Store.Preview | NewCampaign | Conclusion GameState | DiningPreview S.Tile S.Rotation Int (M.Map Resource Integer)

data Screen = Screen
  { screenGame :: !GameState,
    screenTab :: !Tab,
    screenSelected :: !(Maybe EntityId),
    screenCamera :: !Camera,
    screenBuild :: !(Maybe String),
    screenSpeed :: !Int,
    screenDialog :: !Dialog,
    screenNotice :: !String,
    screenNoticeAge :: !Double,
    screenSaved :: !Bool,
    screenAutoPause :: !Bool,
    screenPalettePage :: !Int,
    screenSupplyPage :: !Int,
    screenStockPage :: !Int,
    screenBuildRotation :: !S.Rotation,
    screenRoadStart :: !(Maybe S.Tile),
    screenCues :: ![WorldCue],
    screenHelpUi :: !Help.HelpUi
  }

data UiCommand
  = Choose Decision
  | BeginWork EntityId
  | PlaceDining S.Tile S.Rotation
  | ConfirmDining S.Tile S.Rotation
  | FocusDining S.Tile
  | HomeView
  | SelectSite EntityId
  | ClearSelection
  | SelectTab Tab
  | SelectBuild String
  | FocusSource EntityId
  | ChangeSpeed Int
  | SaveNow
  | ShowLibrary
  | ReadSave String
  | ConfirmLoad
  | CloseDialog
  | StartScenario String
  | ShowNewCampaign
  | LibraryPage Int
  | ToggleAlerts
  | QuitGame
  | PalettePage Int
  | SupplyPage Int
  | StockPage Int
  | RotateBuilding
  | HelpCommand Help.HelpAction
  deriving (Eq, Show)

newScreen :: GameState -> Dialog -> Screen
newScreen game dialog =
  Screen
    { screenGame = game,
      screenTab = ColonyTab,
      screenSelected = Nothing,
      screenCamera = openingCamera game,
      screenBuild = Nothing,
      screenSpeed = 4,
      screenDialog = dialog,
      screenNotice = "",
      screenNoticeAge = 0,
      screenSaved = False,
      screenAutoPause = True,
      screenPalettePage = 0,
      screenSupplyPage = 0,
      screenStockPage = 0,
      screenBuildRotation = S.R0,
      screenRoadStart = Nothing,
      screenCues = [],
      screenHelpUi = Help.newHelpUi Help.defaultPreferences
    }

data WorldCue = WorldCue {cueX :: !Float, cueY :: !Float, cueLabel :: !String, cueLife :: !Float, cueColor :: !Color}

data WorldLabel = WorldLabel
  { worldLabelPriority :: !Int,
    worldLabelBounds :: !Rectangle,
    drawWorldLabel :: IO ()
  }

fadeCues :: Double -> [WorldCue] -> [WorldCue]
fadeCues dt = filter ((> 0) . cueLife) . map (\cue -> cue {cueLife = cueLife cue - realToFrac dt})

worldFeedback :: GameState -> GameState -> [WorldCue]
worldFeedback before after =
  take 8 $
    [ WorldCue (fromInteger x + 1.5) (fromInteger y + 1.5) (resourceName resource ++ " +" ++ resourceAmount resource increase) 2.8 (resourceColor resource)
    | state <- maybe [] (: []) (worldM1 newWorld),
      placement <- M.elems (S.spatialPlacements (m1Space state)),
      S.BuildingShape _ (S.Tile x y) _ <- [S.placementShape placement],
      S.placementStage placement == S.Built,
      resource <- [Water, Crops, Ration],
      let stock world = sum [P.physical world owner resource | owner@(Owner _ ident) <- M.keys (invStorage (worldInventory world)), ident == S.placementId placement],
      let increase = stock newWorld - stock oldWorld,
      increase >= 500
    ]
      ++ [ WorldCue (fromInteger x + 1.5) (fromInteger y + 1.5) "ここで、ひとくち" 3.4 mint
         | status <- diningStatuses after,
           S.Tile x y <- [diningTile status],
           any (\(person, meal) -> maybe True ((/= mealOwner meal) . mealOwner) (M.lookup person (needsLastMeals (worldNeeds oldWorld)))) (diningMeals status),
           not (null (diningMeals status))
         ]
  where
    oldWorld = gameWorld before; newWorld = gameWorld after

data Button = Button {buttonRect :: !Rectangle, buttonLabel :: !String, buttonCommand :: !UiCommand, buttonActive :: !Bool}

ink, muted, paper, panel, copper, mint, water, warning, line :: Color
ink = Color 39 47 48 255
muted = Color 98 94 84 255
paper = Color 251 246 231 255
panel = Color 255 251 239 250
copper = Color 155 64 42 255
mint = Color 45 116 87 255
water = Color 43 117 154 255
warning = Color 194 91 45 255
line = Color 209 182 154 255

txt :: NativeFont -> String -> Float -> Float -> Float -> Color -> IO ()
txt font label x y size color = drawNativeText font label (Vector2 x y) (size * 1.45) 0.6 color

measureLabel :: NativeFont -> String -> Float -> IO Vector2
measureLabel font label size = measureNativeText font label (size * 1.45) 0.6

card :: Float -> Float -> Float -> Float -> Color -> IO ()
card x y width height color = drawRectangleRounded (Rectangle x y width height) 0.08 5 color

inside :: Vector2 -> Rectangle -> Bool
inside (Vector2 x y) (Rectangle u v width height) = x >= u && y >= v && x < u + width && y < v + height

worldViewport :: Int -> Int -> Screen -> Rectangle
worldViewport width height screen =
  Rectangle 0 100 (fromIntegral (if screenTab screen == ColonyTab && screenSelected screen == Nothing then width else width - 406)) (fromIntegral (height - 214))

worldPointerVisible :: Int -> Int -> Screen -> Vector2 -> Bool
worldPointerVisible width height screen mouse =
  inside mouse (worldViewport width height screen)
    && not (Help.activeHint (screenHelpUi screen) /= Nothing && inside mouse hintRectangle)

type PreviewKey = (Word64, String, S.Tile, S.Rotation, Maybe S.Tile)

previewKeyAt :: Int -> Int -> Vector2 -> Screen -> Maybe PreviewKey
previewKeyAt width height mouse screen = do
  name <- screenBuild screen
  if worldPointerVisible width height screen mouse
    then Just (gameRevision (screenGame screen), name, unproject width height (screenCamera screen) mouse, screenBuildRotation screen, screenRoadStart screen)
    else Nothing

previewFailureAt :: GameState -> PreviewKey -> Maybe String
previewFailureAt game (_, name, tile, rotation, roadStart)
  | name == "dining" = either Just (const Nothing) (planDining tile rotation game)
  | name == "detail-erase" && M.notMember tile (gamePlaces game) = Just "No detail at tile"
  | otherwise = either Just (const Nothing) (decide candidate game)
  where
    detail = lookup name [("detail-square", PlaceSquare), ("detail-bench", PlaceBench), ("detail-garden", PlaceGarden), ("detail-lantern", PlaceLantern)]
    candidate = case roadStart of
      Just from | name == "road" -> RoadPath from tile
      _ | name == "road" -> RoadPath tile tile
      _ | name == "detail-erase" -> RemoveDetail tile
      _ | Just kind <- detail -> PlaceDetail kind tile rotation
      _ -> Plan (S.BuildingShape name tile rotation)

sourcesFor :: GameState -> String -> [S.SourceRegion]
sourcesFor game prototype = case worldM1 world of
  Nothing -> []
  Just state ->
    [ source
    | source <- M.elems (S.spatialSources (m1Space state)),
      Set.member (S.sourceRegionKind source, S.sourceRegionResource source) (S.sourceRequirements (worldContent world) prototype)
    ]
  where
    world = gameWorld game

sourceRemaining :: World -> S.SourceRegion -> Integer
sourceRemaining world source = maybe 0 (qtyValue . depositQty) (M.lookup (S.sourceRegionId source) (invDeposits (worldInventory world)))

sourceColor :: Resource -> Color
sourceColor resource = case resource of
  Water -> Color 68 132 139 108
  Brine -> Color 52 112 144 108
  Ore -> Color 119 91 113 135
  Stone -> Color 116 110 103 145
  Sand -> Color 203 155 84 145
  _ -> Color 145 116 94 110

placementExplanation :: String -> String -> Maybe String
placementExplanation prototype failure
  | take 7 prototype == "detail-" && ("overlaps" `isInfixOf` failure || "transport road" `isInfixOf` failure) = Just "建物や道路に重なります。空いた場所を選んでください。"
  | prototype == "detail-erase" && failure == "No detail at tile" = Just "ここに片付ける飾りはありません。"
  | prototype == "dining" && "construction queue" `isInfixOf` failure = Just "今の工事が終わってから、食事の場を計画できます。"
  | prototype == "dining" && "already has a dining place" `isInfixOf` failure = Just "食事の場はすでにあります。"
  | "NoCompatibleSource" `isInfixOf` failure = Just (if prototype == "mine" then "鉱石の区画に、建物の辺を重ねず接してください。" else if prototype == "quarry" then "石材か砂の区画に、建物の辺を重ねず接してください。" else "必要な資源の区画に、建物の辺を重ねず接してください。")
  | prototype == "road" && "SourceConflict" `isInfixOf` failure = Just "資源の区画には道路を通せません。区画の外を通るように終点を選び直してください。"
  | prototype == "road" && any (`isInfixOf` failure) ["FootprintConflict", "RoadConflict", "PortConflict"] = Just "道が施設や入口と重なります。通れる場所へ終点を選び直してください。"
  | "SourceConflict" `isInfixOf` failure = Just "資源の区画に建物・道路・入口を重ねられません。Rで入口の向きも確認してください。"
  | "FootprintConflict" `isInfixOf` failure || "RoadConflict" `isInfixOf` failure || "PortConflict" `isInfixOf` failure = Just "建物・道路・入口と重なっています。空いた場所へ動かすかRで向きを変えてください。"
  | "SourceDepleted" `isInfixOf` failure = Just "この区画の資源は枯渇しています。別の区画を探してください。"
  | otherwise = Nothing

button :: Float -> Float -> Float -> String -> UiCommand -> Bool -> Button
button x y width label command active = Button (Rectangle x y width 44) label command active

drawButton :: NativeFont -> Vector2 -> Button -> IO ()
drawButton font mouse b = do
  let Rectangle x y width height = buttonRect b
      hovered = inside mouse (buttonRect b)
      color = if buttonActive b then copper else if hovered then Color 237 217 190 255 else Color 243 230 210 255
  card x y width height color
  Vector2 labelWidth _ <- measureLabel font (buttonLabel b) 22
  txt font (buttonLabel b) (if width < 100 then x + (width - labelWidth) / 2 else x + 12) (y + (height - 24) / 2 - 3) 22 (if buttonActive b then paper else ink)

project :: Int -> Int -> Camera -> Float -> Float -> Vector2
project width height camera x y =
  let dx = x - cameraX camera
      dy = y - cameraY camera
      (u, v) = case cameraRotation camera `mod` 4 of 0 -> (dx, dy); 1 -> (-dy, dx); 2 -> (-dx, -dy); _ -> (dy, -dx)
      scale = cameraScale camera
   in Vector2 (fromIntegral width / 2 + (u - v) * scale) (fromIntegral height / 2 - 35 + (u + v) * scale * 0.47)

unproject :: Int -> Int -> Camera -> Vector2 -> S.Tile
unproject width height camera (Vector2 sx sy) =
  let u = (sx - fromIntegral width / 2) / cameraScale camera
      v = (sy - fromIntegral height / 2 + 35) / (cameraScale camera * 0.47)
      dx = (u + v) / 2
      dy = (v - u) / 2
      (x, y) = case cameraRotation camera `mod` 4 of 0 -> (dx, dy); 1 -> (dy, -dx); 2 -> (-dx, -dy); _ -> (-dy, dx)
   in S.Tile (floor (x + cameraX camera)) (floor (y + cameraY camera))

quad :: Vector2 -> Vector2 -> Vector2 -> Vector2 -> Color -> IO ()
quad a b c d color = do
  -- raylib triangles are counterclockwise in screen coordinates.
  drawTriangle a d c color
  drawTriangle a c b color

raise :: Float -> Vector2 -> Vector2
raise amount (Vector2 x y) = Vector2 x (y - amount)

tileQuad :: Int -> Int -> Camera -> Float -> Float -> Float -> Float -> Float -> Color -> IO ()
tileQuad width height camera x y w h elevation color =
  let p u v = raise elevation (project width height camera u v)
   in quad (p x y) (p (x + w) y) (p (x + w) (y + h)) (p x (y + h)) color

buildingBox :: Int -> Int -> Camera -> Float -> Float -> Float -> Float -> Float -> Color -> IO ()
buildingBox width height camera x y w h elevation color@(Color r g b a) = do
  let p = project width height camera
      high = raise elevation
      a0 = p x y
      b0 = p (x + w) y
      c0 = p (x + w) (y + h)
      d0 = p x (y + h)
      shade value factor = fromIntegral (toInteger value * factor `div` 10)
      dark = Color (shade r 7) (shade g 7) (shade b 7) a
      side = Color (shade r 8) (shade g 8) (shade b 8) a
  tileQuad width height camera (x + 0.8) (y + 0.8) w h 0 (Color 90 57 47 65)
  quad b0 c0 (high c0) (high b0) dark
  quad c0 d0 (high d0) (high c0) side
  quad (high a0) (high b0) (high c0) (high d0) color

placementAt :: GameState -> S.Tile -> Maybe EntityId
placementAt game tile = do
  state <- worldM1 (gameWorld game)
  let candidates =
        [ S.placementId placement
        | placement <- M.elems (S.spatialPlacements (m1Space state)),
          Right (tiles, _) <- [S.placementGeometry (worldContent (gameWorld game)) placement],
          Set.member tile tiles
        ]
  case candidates of { ident : _ -> Just ident; _ -> Nothing }

drawColony :: NativeFont -> Int -> Int -> Double -> Vector2 -> Screen -> Maybe String -> IO [Button]
drawColony font width height time mouse screen failure = do
  let camera = screenCamera screen
      game = screenGame screen
      world = gameWorld game
      p = project width height camera
      scale = cameraScale camera
      SimTick tick = simTick world
      clock = if worldMode world == Active && Help.helpTopic (screenHelpUi screen) == Nothing then realToFrac time else fromIntegral tick / 20
      night = max 0 (min 1 ((cos (fromIntegral (tick `mod` 28800) * pi / 14400) + 0.15) * 0.85)) :: Float
      buildSources = maybe [] (sourcesFor game) (screenBuild screen)
      placements = maybe [] (sortOn (depth camera) . M.elems . S.spatialPlacements . m1Space) (worldM1 world)
      diningPlans = M.keys (gameDiningPlaces game) ++ case screenDialog screen of DiningPreview tile _ _ _ -> [tile]; _ -> []
      hotspots = [Button (placementRect width height camera world placement) "" (SelectSite (S.placementId placement)) False | placement <- placements, case S.placementShape placement of S.BuildingShape {} -> True; _ -> False]
      visibleWorld = worldPointerVisible width height screen mouse
      hovered = if screenBuild screen == Nothing && visibleWorld then buttonCommand <$> find (inside mouse . buttonRect) (reverse hotspots) else Nothing
      Rectangle _ _ visibleWidth _ = worldViewport width height screen
      viewportWidth = round visibleWidth
  beginScissorMode 0 100 viewportWidth (height - 214)
  drawRectangleGradientV 0 100 viewportWidth (height - 214) (Color 210 158 122 255) (Color 230 191 148 255)
  -- Dune contours are scenery; crop, stock and activity below read real state.
  forM_ [0 .. 14 :: Int] $ \n -> do
    let y = 80 + fromIntegral n * 71
    drawLineBezier (Vector2 (-80) y) (Vector2 (fromIntegral width + 100) (y + 230)) 22 (Color 194 129 94 26)
    drawLineBezier (Vector2 (-80) (y + 21)) (Vector2 (fromIntegral width + 100) (y + 251)) 2 (Color 247 217 167 70)
  case worldM1 world of
    Nothing -> pure ()
    Just state -> do
      let space = m1Space state
      forM_ (M.toAscList (S.mapTerrain (S.spatialMap space))) $ \(S.Tile x y, terrain) -> do
        when (terrain `elem` [S.Rock, S.Cliff, S.Salt]) $
          tileQuad width height camera (fromInteger x) (fromInteger y) 1 1 0 (if terrain == S.Salt then Color 236 224 193 255 else Color 141 109 87 255)
      sourceLabels <- forM (M.elems (S.spatialSources space)) $ \source -> case S.sourceRegionBounds source of
        S.Rect (S.Tile x y) w h -> do
          let px = fromInteger x
              py = fromInteger y
              fw = fromInteger w
              fh = fromInteger h
              corners = [p px py, p (px + fw) py, p (px + fw) (py + fh), p px (py + fh)]
              remaining = sourceRemaining world source
              depleted = remaining <= 0
              label = resourceName (S.sourceRegionResource source) ++ if depleted then " 枯渇" else " " ++ resourceAmount (S.sourceRegionResource source) remaining
              Color red green blue _ = sourceColor (S.sourceRegionResource source)
          tileQuad width height camera px py fw fh 0 (if depleted then Color 119 108 100 85 else sourceColor (S.sourceRegionResource source))
          forM_ (zip corners (tail corners ++ take 1 corners)) $ \(a, b) -> drawLineEx a b 2 (if depleted then Color 129 102 91 190 else Color red green blue 230)
          let Vector2 sx sy = p (px + fw / 2) (py + if S.sourceRegionKind source == "aquifer" then 0.5 else fh / 2)
          Vector2 labelWidth _ <- measureLabel font label 18
          let centeredX = max (labelWidth / 2 + 15) (min (visibleWidth - labelWidth / 2 - 15) sx)
              priority = if any ((== S.sourceRegionId source) . S.sourceRegionId) buildSources then -1 else 3
              bounds = Rectangle (centeredX - labelWidth / 2 - 9) (sy - 15) (labelWidth + 18) 31
              drawLabel = do
                card (centeredX - labelWidth / 2 - 9) (sy - 15) (labelWidth + 18) 31 panel
                txt font label (centeredX - labelWidth / 2) (sy - 12) 18 (if depleted then copper else ink)
          pure $
            if sx >= 0 && sx <= visibleWidth && sy >= 115 && sy <= fromIntegral height - 145
              then Just (WorldLabel priority bounds drawLabel)
              else Nothing
      forM_ (Set.toAscList (S.spatialRoads space)) $ \(S.Tile x y) -> do
        tileQuad width height camera (fromInteger x - 0.08) (fromInteger y - 0.08) 1.16 1.16 0 (Color 126 99 76 255)
        tileQuad width height camera (fromInteger x + 0.07) (fromInteger y + 0.07) 0.86 0.86 1 (Color 216 189 145 255)
      forM_ (M.toAscList (gamePlaces game)) $ \(tile, (kind, rotation)) -> drawPlace width height camera night tile kind rotation
      forM_ diningPlans $ \tile@(S.Tile x y) ->
        when (not (any (\placement -> case S.placementShape placement of S.BuildingShape "pantry" origin _ -> origin == tile; _ -> False) placements)) $ do
          tileQuad width height camera (fromInteger x) (fromInteger y) 3 3 0 (Color 251 219 124 135)
          drawWorksite width height camera (fromInteger x) (fromInteger y) 3 3 0
          let Vector2 sx sy = p (fromInteger x + 1.5) (fromInteger y + 1.5)
          txt font "食事の場（予定）" (sx - 90) (sy - 74) 23 ink
      let buildingLabel placement = case S.placementShape placement of
            S.BuildingShape name (S.Tile x y) rotation -> do
              let ident = S.placementId placement
                  selected = screenSelected screen == Just ident
                  pointed = hovered == Just (SelectSite ident)
              if not (selected || pointed || name `elem` ["hand_pump", "farm", "kitchen", "pantry"])
                then pure Nothing
                else do
                  let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
                      (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fromInteger fh, fromInteger fw) else (fromInteger fw, fromInteger fh)
                      px = fromInteger x
                      py = fromInteger y
                      Vector2 centerX centerY = p (px + bw / 2) (py + bh / 2)
                      cx = centerX + (if name == "farm" then -42 else if name == "kitchen" then 38 else 0)
                      cy = centerY + (if name == "farm" then -22 else if name == "kitchen" then 8 else 0)
                      title = if M.member (S.Tile x y) (gameDiningPlaces game) then "食事の場" else siteName name
                      elevation = if name `elem` ["farm", "solar"] then 9 else scale * 2.2
                      status = siteStatus game ident
                      showStatus = selected || pointed || name == "hand_pump"
                      caption = statusTitle status
                  Vector2 titleWidth _ <- measureLabel font title 23
                  Vector2 captionWidth _ <- measureLabel font caption 20
                  let labelWidth = max titleWidth (if showStatus then captionWidth else 0) + 28
                      lx = max 8 (min (visibleWidth - labelWidth - 8) (cx - labelWidth / 2))
                      ly = cy - elevation - if showStatus then 78 else 42
                      bounds = Rectangle lx ly labelWidth (if showStatus then 65 else 37)
                      priority = if selected then 0 else if pointed then 1 else 2
                      drawLabel = do
                        card lx ly labelWidth (if showStatus then 65 else 37) (Color 255 249 233 244)
                        txt font title (lx + (labelWidth - titleWidth) / 2) (ly + 5) 23 ink
                        when showStatus $ do
                          drawCircleV (Vector2 (lx + 12) (ly + 47)) 4 (moodColor (statusMood status))
                          txt font caption (lx + 23) (ly + 36) 20 (moodColor (statusMood status))
                  pure $
                    if cx >= 0 && cx <= visibleWidth && cy >= 100 && cy <= fromIntegral height - 114
                      then Just (WorldLabel priority bounds drawLabel)
                      else Nothing
            _ -> pure Nothing
      candidates <- mapM buildingLabel placements
      let overlaps (Rectangle ax ay aw ah) (Rectangle bx by bw bh) = ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah
          keep labels label
            | any (overlaps (worldLabelBounds label) . worldLabelBounds) labels = labels
            | otherwise = label : labels
          -- Sources needed by the active build choice take priority, including after FocusSource.
          -- Otherwise resources yield to selected, hovered and ambient facility labels.
          visibleLabels = reverse (foldl' keep [] (sortOn worldLabelPriority [label | Just label <- candidates ++ sourceLabels]))
      let drawBuilding placement = case S.placementShape placement of
            S.RoadShape (S.Tile x y) -> when (S.placementStage placement /= S.Built) $ tileQuad width height camera (fromInteger x) (fromInteger y) 1 1 0 (Color 246 193 81 180)
            S.BuildingShape name (S.Tile x y) rotation -> do
              let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
                  (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fromInteger fh, fromInteger fw) else (fromInteger fw, fromInteger fh)
                  px = fromInteger x
                  py = fromInteger y
                  ident = S.placementId placement
                  selected = screenSelected screen == Just ident
                  pointed = hovered == Just (SelectSite ident)
                  status = siteStatus game ident
                  running = statusMood status == MoodBusy && worldMode world == Active
                  progress = maybe 0 id (statusProgress status)
                  stock resource = sum [P.physical world owner resource | owner@(Owner _ target) <- M.keys (invStorage (worldInventory world)), target == ident]
                  plate = if selected then Color 255 231 156 230 else Color 252 222 170 105
              when (selected || pointed) $ do
                tileQuad width height camera (px - 0.35) (py - 0.35) (bw + 0.7) (bh + 0.7) 0 plate
                let Vector2 cx cy = p (px + bw / 2) (py + bh / 2)
                drawEllipseLines (round cx) (round cy) (scale * (bw + bh) / 2) (scale * (bw + bh) / 4) copper
              if S.placementStage placement /= S.Built
                then drawWorksite width height camera px py bw bh progress
                else drawFacility width height camera clock night (if M.member (S.Tile x y) (gameDiningPlaces game) then "dining" else name) px py bw bh running progress stock
              when selected $ case worksiteRoadConnector game ident of
                Just connector@(S.Tile cx cy) -> do
                  let Vector2 ex ey = p (fromInteger cx + 0.5) (fromInteger cy + 0.5)
                      connected = Set.member connector (S.spatialRoads space)
                      caption = if connected then "道路につながる" else "ここへ道路"
                  tileQuad width height camera (fromInteger cx) (fromInteger cy) 1 1 0 (Color 85 174 118 145)
                  card (ex + 10) (ey - 19) 128 34 panel
                  txt font caption (ex + 19) (ey - 15) 18 ink
                Nothing -> pure ()
      let drawResident (n, person, resident, (px, py, working, eating)) = do
            let bob = if working || eating && worldMode world == Active then 0.8 * sin (clock * 5 + fromIntegral n) else 0
                Vector2 u v = p px py
                EntityId number = person
            drawPerson (p px py) (max 0.85 (scale / 17)) (fromInteger (residentShift resident)) bob
            when eating $ do
              drawEllipse (round (u + scale * 0.28)) (round (v - scale * 0.35)) (scale * 0.16) (scale * 0.07) paper
              drawCircleV (Vector2 (u + scale * 0.28) (v - scale * 0.37)) (scale * 0.045) mint
            when (inside mouse (Rectangle (u - 12) (v - 34) 24 38)) $ do
              let label = "住民 " ++ show number ++ (if eating then " · ここで食事" else if working then " · 作業中" else " · 休息中")
              Vector2 tw _ <- measureLabel font label 22
              card (u - tw / 2 - 10) (v - 67) (tw + 20) 36 panel
              txt font label (u - tw / 2) (v - 64) 22 ink
      let drawVehicle vehicle = do
            let (x, y) = vehicleXY (transportTopology (worldTransport world)) (vehiclePosition vehicle)
                Vector2 vx vy = p x y
                s = max 0.85 (scale / 17)
                resource = find (\r -> P.physical world (Owner Vehicle (vehicleId vehicle)) r > 0) allResources
                cargoColor = maybe (Color 184 151 112 255) resourceColor resource
            drawEllipse (round (vx + 3)) (round (vy + 5)) (14 * s) (6 * s) (Color 64 53 42 55)
            card (vx - 13 * s) (vy - 12 * s) (26 * s) (16 * s) (Color 104 77 60 255)
            card (vx - 10 * s) (vy - 15 * s) (20 * s) (14 * s) cargoColor
            drawCircleV (Vector2 (vx - 9 * s) (vy + 1 * s)) (3 * s) ink
            drawCircleV (Vector2 (vx + 9 * s) (vy + 1 * s)) (3 * s) ink
            drawPerson (Vector2 (vx + 16 * s) (vy + 4 * s)) (0.85 * s) 2 0
            when (inside mouse (Rectangle (vx - 26) (vy - 35) 65 60)) $ do
              let label = maybe "空の荷車" (\r -> resourceName r ++ " " ++ resourceAmount r (P.physical world (Owner Vehicle (vehicleId vehicle)) r)) resource
              Vector2 tw _ <- measureLabel font label 22
              card (vx - tw / 2 - 10) (vy - 57) (tw + 20) 34 panel
              txt font label (vx - tw / 2) (vy - 53) 22 ink
      let residents = [(n, person, resident, spot) | (n, (person, resident)) <- zip [0 :: Int ..] (M.toAscList (needsResidents (worldNeeds world))), Just spot <- [residentSpot game state n person resident]]
          buildingZ placement = case S.placementShape placement of
            S.BuildingShape name (S.Tile x y) rotation ->
              let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
                  (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fh, fw) else (fw, fh)
               in sceneDepth camera (fromInteger x + fromInteger bw / 2) (fromInteger y + fromInteger bh)
            S.RoadShape (S.Tile x y) -> sceneDepth camera (fromInteger x) (fromInteger y)
          scene =
            [(buildingZ placement, drawBuilding placement) | placement <- placements]
              ++ [(sceneDepth camera px py, drawResident person) | (person@(_, _, _, (px, py, _, _))) <- residents]
              ++ [(sceneDepth camera x y, drawVehicle vehicle) | vehicle <- M.elems (transportVehicles (worldTransport world)), let (x, y) = vehicleXY (transportTopology (worldTransport world)) (vehiclePosition vehicle)]
      mapM_ snd (sortOn fst scene)
      mapM_ drawWorldLabel visibleLabels
      case screenBuild screen of
        Nothing -> pure ()
        Just name | visibleWorld -> do
          let S.Tile tx ty = unproject width height camera mouse
              footprint = if name == "road" then (1, 1) else maybe (3, 3) buildingFootprint (M.lookup (if name == "dining" then "pantry" else name) (contentBuildings (worldContent world)))
              (bw, bh) = if screenBuildRotation screen `elem` [S.R90, S.R270] then (snd footprint, fst footprint) else footprint
              tile = S.Tile tx ty
              detail = lookup name [("detail-square", PlaceSquare), ("detail-bench", PlaceBench), ("detail-garden", PlaceGarden), ("detail-lantern", PlaceLantern)]
              color = maybe (Color 85 174 118 135) (const (Color 211 91 69 155)) failure
          if name == "dining"
            then do
              tileQuad width height camera (fromInteger tx) (fromInteger ty) (fromInteger bw) (fromInteger bh) 0 color
              drawFacility width height camera clock night "dining" (fromInteger tx) (fromInteger ty) (fromInteger bw) (fromInteger bh) False 0 (const 0)
            else
              if take 7 name == "detail-"
                then do
                  tileQuad width height camera (fromInteger tx) (fromInteger ty) 1 1 0 color
                  case detail of
                    Just kind -> drawPlace width height camera night tile kind (screenBuildRotation screen)
                    Nothing -> pure ()
                else tileQuad width height camera (fromInteger tx) (fromInteger ty) (fromInteger bw) (fromInteger bh) 0 color
          case screenRoadStart screen of
            Just (S.Tile x y) -> do
              let range a b = if a <= b then [a .. b] else reverse [b .. a]
              forM_ ([S.Tile u y | u <- range x tx] ++ [S.Tile tx v | v <- range y ty]) $ \(S.Tile u v) -> tileQuad width height camera (fromInteger u) (fromInteger v) 1 1 0 color
            Nothing -> pure ()
          when (name /= "road" && name /= "dining" && take 7 name /= "detail-") $ case M.lookup name (contentBuildings (worldContent world)) of
            Nothing -> pure ()
            Just building -> case S.footprintGeometry (buildingFootprint building) (S.Tile tx ty) (screenBuildRotation screen) of
              Left _ -> pure ()
              Right (_, portGeometry) -> do
                let S.Tile cx cy = S.roadConnector portGeometry
                    Vector2 ex ey = p (fromInteger cx + 0.5) (fromInteger cy + 0.5)
                drawCircleV (Vector2 ex ey) 7 (maybe mint (const warning) failure)
                when (failure == Nothing) (txt font "入口" (ex + 10) (ey - 25) 18 ink)
          let label = case failure of
                Just reason -> maybe "ここには置けません" id (placementExplanation name reason)
                Nothing -> if name == "road" then (if screenRoadStart screen == Nothing then "道の始点を選ぶ" else "ここまで道をつなぐ") else if take 7 name == "detail-" then "ここに置く" else "ここに建てる"
              maxWidth = fromIntegral viewportWidth - 56
              labelColor = maybe ink (const copper) failure
              background = maybe (Color 255 250 238 245) (const (Color 255 242 223 248)) failure
          Vector2 labelWidth _ <- measureLabel font label 19
          if labelWidth + 24 <= maxWidth
            then do
              let top = fromIntegral height - 172
              card 28 top (labelWidth + 24) 46 background
              txt font label 40 (top + 8) 19 labelColor
            else do
              let top = fromIntegral height - 190
              card 28 top maxWidth 68 background
              _ <- wrapMeasured font label 40 (top + 8) (maxWidth - 24) 18 labelColor
              pure ()
        Just _ -> pure ()
      drawRectangle 0 100 width (height - 214) (Color 40 52 73 (round (night * 57)))
      forM_ (screenCues screen) $ \cue -> do
        let Vector2 cx cy = p (cueX cue) (cueY cue)
            lift = 70 + (2.8 - cueLife cue) * 12
        Vector2 tw _ <- measureLabel font (cueLabel cue) 22
        card (cx - tw / 2 - 12) (cy - lift) (tw + 24) 36 panel
        txt font (cueLabel cue) (cx - tw / 2) (cy - lift + 3) 22 (cueColor cue)
  endScissorMode
  pure (if screenBuild screen == Nothing && visibleWorld then hotspots else [])
  where
    depth camera placement = case S.placementShape placement of
      S.BuildingShape _ (S.Tile x y) _ -> depthXY camera x y
      S.RoadShape (S.Tile x y) -> depthXY camera x y
    depthXY camera x y = case cameraRotation camera `mod` 4 of 0 -> x + y; 1 -> x - y; 2 -> -x - y; _ -> y - x

sceneDepth :: Camera -> Float -> Float -> Float
sceneDepth camera x y = case cameraRotation camera `mod` 4 of 0 -> x + y; 1 -> x - y; 2 -> -x - y; _ -> y - x

residentSpot :: GameState -> M1State -> Int -> EntityId -> Resident -> Maybe (Float, Float, Bool, Bool)
residentSpot game state n person resident = do
  let world = gameWorld game
      space = m1Space state
      claim = M.lookup person (W.workforceClaims (m1Workforce state))
      home = bedBuilding <$> M.lookup person (m1Beds state)
      SimTick tick = simTick world
      meal = M.lookup person (needsLastMeals (worldNeeds world))
      dining = case (claim, meal) of
        (Nothing, Just serving) ->
          let SimTick ate = mealTick serving; Owner _ ident = mealOwner serving
           in if tick - ate <= 200 && any ((== Just (mealOwner serving)) . diningOwner) (diningStatuses game) then Just ident else Nothing
        _ -> Nothing
      target = case claim of
        Just (W.OperateFacility ident) -> Just ident
        Just (W.ConstructSite ident) -> Just ident
        Just (W.MaintainJob ident) -> maintenanceTarget <$> M.lookup ident (maintenanceJobs (worldMaintenance world))
        Just (W.DriveVehicle _) -> Nothing
        _ -> case dining of Just ident -> Just ident; Nothing -> home
  if residentStatus resident /= Living
    then Nothing
    else do
      ident <- target
      placement <- M.lookup ident (S.spatialPlacements space)
      case S.placementShape placement of
        S.BuildingShape name (S.Tile x y) rotation ->
          let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
              (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fh, fw) else (fw, fh)
              px = fromInteger x + 0.3 + fromIntegral (n `mod` 5) * fromInteger bw / 5
              py = fromInteger y + fromInteger bh + 0.16 + fromIntegral (n `div` 5 `mod` 2) * 0.32
           in Just (px, py, claim /= Nothing && worldMode world == Active, dining /= Nothing)
        _ -> Nothing

placementRect :: Int -> Int -> Camera -> World -> S.Placement -> Rectangle
placementRect width height camera world placement = case S.placementShape placement of
  S.BuildingShape name (S.Tile x y) rotation ->
    let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
        (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fh, fw) else (fw, fh)
        corners = [project width height camera (fromInteger u) (fromInteger v) | (u, v) <- [(x, y), (x + bw, y), (x + bw, y + bh), (x, y + bh)]]
        xs = [u | Vector2 u _ <- corners]
        ys = [v | Vector2 _ v <- corners]
        left = minimum xs - 7
        top = minimum ys - cameraScale camera * 2.7 - 25
     in Rectangle left top (maximum xs - left + 7) (maximum ys - top + 10)
  _ -> Rectangle (-100) (-100) 0 0

moodColor :: SiteMood -> Color
moodColor mood = case mood of MoodQuiet -> muted; MoodWaiting -> Color 143 93 31 255; MoodBusy -> water; MoodReady -> mint; MoodTrouble -> copper

resourceColor :: Resource -> Color
resourceColor resource = case resource of Water -> Color 75 161 178 255; Ration -> Color 242 184 76 255; Crops -> Color 109 153 79 255; Fuel -> Color 125 87 70 255; Parts -> Color 106 128 143 255; _ -> Color 177 137 96 255

drawPlace :: Int -> Int -> Camera -> Float -> S.Tile -> PlaceKind -> S.Rotation -> IO ()
drawPlace width height camera night (S.Tile tx ty) kind rotation = do
  let x = fromInteger tx
      y = fromInteger ty
      s = cameraScale camera
      p = project width height camera
      Vector2 cx cy = p (x + 0.5) (y + 0.5)
      horizontal = rotation `elem` [S.R0, S.R180]
      wood = Color 157 104 58 255
  case kind of
    PlaceSquare -> do
      tileQuad width height camera x y 1 1 0 (Color 197 165 126 255)
      tileQuad width height camera (x + 0.05) (y + 0.05) 0.41 0.9 0 (Color 237 216 175 255)
      tileQuad width height camera (x + 0.54) (y + 0.05) 0.41 0.9 0 (Color 229 203 158 255)
    PlaceBench -> do
      buildingBox width height camera (x + 0.1) (y + 0.2) (if horizontal then 0.8 else 0.35) (if horizontal then 0.35 else 0.8) (s * 0.34) wood
      drawLineEx (Vector2 (cx - s * 0.55) (cy + s * 0.1)) (Vector2 (cx - s * 0.55) (cy - s * 1.2)) 2 wood
      drawLineEx (Vector2 (cx + s * 0.55) (cy + s * 0.1)) (Vector2 (cx + s * 0.55) (cy - s * 1.2)) 2 wood
      quad (Vector2 (cx - s * 0.85) (cy - s * 1.2)) (Vector2 cx (cy - s * 1.6)) (Vector2 (cx + s * 0.85) (cy - s * 1.2)) (Vector2 cx (cy - s * 0.8)) (Color 243 224 173 255)
    PlaceGarden -> do
      buildingBox width height camera (x + 0.15) (y + 0.15) 0.7 0.7 (s * 0.28) (Color 169 94 63 255)
      tileQuad width height camera (x + 0.22) (y + 0.22) 0.56 0.56 (s * 0.28 + 1) (Color 108 81 50 255)
      forM_ [-0.22, 0.22] $ \u -> do
        drawLineEx (Vector2 (cx + u * s) cy) (Vector2 (cx + u * s) (cy - s * 0.9)) (s * 0.17) mint
        drawLineEx (Vector2 (cx + u * s) (cy - s * 0.5)) (Vector2 (cx + (u + 0.17) * s) (cy - s * 0.72)) (s * 0.12) mint
        drawCircleV (Vector2 (cx + u * s) (cy - s * 0.95)) (s * 0.1) (Color 237 186 113 255)
    PlaceLantern -> do
      drawLineEx (Vector2 cx cy) (Vector2 cx (cy - s * 1.5)) 3 wood
      card (cx - s * 0.2) (cy - s * 1.6) (s * 0.4) (s * 0.5) (Color 247 206 114 255)
      when (night > 0.2) $ drawCircleV (Vector2 cx (cy - s * 1.25)) (s * 1.1) (Color 251 211 126 (round (night * 65)))

drawPerson :: Vector2 -> Float -> Int -> Float -> IO ()
drawPerson (Vector2 x y) size group bob = do
  let coat = [Color 59 121 125 255, Color 190 96 57 255, Color 100 124 76 255] !! (group `mod` 3)
      at u v = Vector2 (x + u * size) (y + (v + bob) * size)
  drawEllipse (round x) (round (y + 2)) (4.5 * size) (2 * size) (Color 59 51 40 65)
  drawLineEx (at (-1.5) (-4)) (at (-2) 0) (2 * size) ink
  drawLineEx (at 1.5 (-4)) (at 2 0) (2 * size) ink
  drawLineEx (at 0 (-11)) (at 0 (-4)) (6 * size) coat
  drawCircleV (at 0 (-15)) (3 * size) (Color 240 198 145 255)
  drawLineEx (at (-4) (-17)) (at 4 (-17)) (2 * size) (Color 239 222 177 255)

drawWorksite :: Int -> Int -> Camera -> Float -> Float -> Float -> Float -> Float -> IO ()
drawWorksite width height camera x y bw bh progress = do
  tileQuad width height camera x y bw bh 0 (Color 248 204 104 100)
  let p = project width height camera
      h = cameraScale camera * (0.8 + progress * 1.2)
  forM_ [(x, y), (x + bw, y), (x + bw, y + bh), (x, y + bh)] $ \(u, v) -> drawLineEx (p u v) (raise h (p u v)) 4 (Color 140 90 55 255)
  quad (raise h (p x y)) (raise h (p (x + bw) y)) (raise h (p (x + bw) (y + bh))) (raise h (p x (y + bh))) (Color 243 203 111 65)

drawFacility :: Int -> Int -> Camera -> Float -> Float -> String -> Float -> Float -> Float -> Float -> Bool -> Float -> (Resource -> Integer) -> IO ()
drawFacility width height camera clock night name x y bw bh running progress stock = do
  let s = cameraScale camera
      p = project width height camera
      center = p (x + bw / 2) (y + bh / 2)
      Vector2 cx cy = center
      cream = Color 237 213 170 255
      roof = Color 174 83 53 255
      lift h u v = raise h (p u v)
      pitched wall top = do
        buildingBox width height camera x y bw bh (s * 1.4) wall
        let ridgeA = lift (s * 2.2) x (y + bh / 2); ridgeB = lift (s * 2.2) (x + bw) (y + bh / 2)
        quad (lift (s * 1.4) x y) (lift (s * 1.4) (x + bw) y) ridgeB ridgeA top
        quad ridgeA ridgeB (lift (s * 1.4) (x + bw) (y + bh)) (lift (s * 1.4) x (y + bh)) (Color 192 99 62 255)
      window u v lit =
        quad (lift (s * 0.35) u v) (lift (s * 0.35) (u + 0.55) v) (lift (s * 0.95) (u + 0.55) v) (lift (s * 0.95) u v) (if lit then Color 255 208 102 255 else Color 66 87 82 255)
  tileQuad width height camera (x - 0.3) (y - 0.3) (bw + 0.6) (bh + 0.6) 0 (Color 123 84 59 34)
  case name of
    "farm" -> do
      tileQuad width height camera x y bw bh 0 (Color 178 125 84 255)
      let growing = progress
      forM_ [0 .. 4 :: Int] $ \row -> do
        let v = y + 0.25 + fromIntegral row * (bh - 0.5) / 5
        tileQuad width height camera (x + 0.25) v (bw - 0.5) 0.33 3 (Color 113 76 52 255)
        when (growing > 0) $ forM_ [0 .. 6 :: Int] $ \col -> do
          let Vector2 u w = p (x + 0.45 + fromIntegral col * (bw - 0.9) / 7) (v + 0.17)
              leaf = s * (0.10 + 0.21 * growing)
          drawLineEx (Vector2 u (w - 2)) (Vector2 u (w - 2 - s * 0.6 * growing)) 2 mint
          drawEllipse (round (u - leaf * 0.5)) (round (w - 3 - s * 0.4 * growing)) leaf (leaf * 0.45) (Color 83 128 66 255)
          drawEllipse (round (u + leaf * 0.5)) (round (w - 4 - s * 0.55 * growing)) leaf (leaf * 0.45) (Color 130 165 73 255)
    "hand_pump" -> do
      drawEllipse (round (cx + 3)) (round (cy + 5)) (s * 1.5) (s * 0.7) (Color 97 83 58 75)
      drawEllipse (round cx) (round (cy - s * 0.28)) (s * 1.12) (s * 0.58) (Color 197 178 132 255)
      drawEllipse (round cx) (round (cy - s * 0.45)) (s * 0.78) (s * 0.39) (Color 55 102 120 255)
      drawEllipse (round cx) (round (cy - s * 0.45)) (s * 0.47) (s * 0.21) (Color 94 163 177 255)
      forM_ [-0.9, 0.9] $ \u -> drawLineEx (Vector2 (cx + u * s) cy) (Vector2 (cx + u * s) (cy - s * 2.4)) (s * 0.2) (Color 107 77 58 255)
      drawLineEx (Vector2 (cx - s * 1.15) (cy - s * 2.4)) (Vector2 (cx + s * 1.15) (cy - s * 2.4)) (s * 0.25) roof
      drawLineEx (Vector2 cx (cy - s * 2.3)) (Vector2 cx (cy - s * 0.5)) 2 cream
      let crank = if running then sin (clock * 5) * s * 0.25 else 0
      drawLineEx (Vector2 (cx + s * 0.95) (cy - s * 1.5)) (Vector2 (cx + s * 1.65) (cy - s * 1.3 + crank)) 4 water
      when (stock Water > 0) $ do
        drawEllipse (round (cx + s * 1.5)) (round (cy + s * 0.3)) (s * 0.4) (s * 0.21) (Color 98 154 162 255)
        drawEllipse (round (cx + s * 1.5)) (round (cy + s * 0.03)) (s * 0.4) (s * 0.2) (Color 121 192 194 255)
    _ | name `elem` ["pantry", "dining"] -> do
      buildingBox width height camera x y bw bh (s * 0.7) cream
      forM_ [(x, y), (x + bw, y), (x, y + bh), (x + bw, y + bh)] $ \(u, v) -> drawLineEx (p u v) (lift (s * 2) u v) 3 (Color 120 84 57 255)
      forM_ [0 .. 4 :: Int] $ \stripe -> tileQuad width height camera (x + fromIntegral stripe * bw / 5) y (bw / 5) bh (s * 2) (if name == "dining" then if even stripe then Color 74 133 128 255 else Color 184 214 185 255 else if even stripe then Color 238 188 90 255 else Color 254 233 173 255)
      forM_ [0 .. 2 :: Int] $ \n -> do
        let u = x + 0.45 + fromIntegral n * (bw - 0.9) / 3
        tileQuad width height camera u (y + bh + 0.3) 0.7 0.45 (s * 0.35) (Color 154 108 65 255)
        when (stock Ration > 0) $ drawEllipse (round (let Vector2 a _ = p (u + 0.3) (y + bh + 0.5) in a)) (round (let Vector2 _ b = p (u + 0.3) (y + bh + 0.5) in b - s * 0.35)) (s * 0.18) (s * 0.09) (Color 249 235 190 255)
    "kitchen" -> do
      pitched cream roof
      let Vector2 ox oy = p (x + bw * 0.6) (y + bh)
      drawCircleV (Vector2 ox (oy - s * 0.47)) (s * 0.58) (Color 139 88 59 255)
      drawCircleV (Vector2 ox (oy - s * 0.43)) (s * 0.4) (Color 62 52 45 255)
      when running $ drawCircleV (Vector2 ox (oy - s * 0.43)) (s * (0.23 + 0.04 * sin (clock * 9))) (Color 245 173 64 255)
      buildingBox width height camera (x + bw - 0.7) (y + 0.4) 0.45 0.45 (s * 3) (Color 157 102 70 255)
      when running $ forM_ [0 .. 3 :: Int] $ \n -> do
        let age = (clock * 0.45 + fromIntegral n / 4) - fromIntegral (floor (clock * 0.45 + fromIntegral n / 4) :: Int)
            chimney = p (x + bw - 0.5) (y + 0.6)
        drawCircleV (raise (s * (3 + age * 2)) chimney) (s * (0.22 + age * 0.25)) (Color 253 235 202 (round ((1 - age) * 140)))
    "housing" -> do
      pitched (Color 237 215 181 255) roof
      window (x + 0.45) (y + bh) (night > 0.25)
      window (x + bw - 1.05) (y + bh) (night > 0.25)
      when (night > 0.25) $ drawCircleV (p (x + bw / 2) (y + bh + 0.4)) (s * 0.8) (Color 252 194 103 (round (night * 48)))
    "solar" -> do
      forM_ [0 .. 2 :: Int] $ \row -> do
        let u = x + 0.2 + fromIntegral row * (bw - 0.4) / 3
        buildingBox width height camera u (y + 0.2) ((bw - 0.65) / 3) (bh - 0.4) (s * 0.35) (Color 43 88 107 255)
        forM_ [1 .. 3 :: Int] $ \n -> tileQuad width height camera u (y + 0.2 + fromIntegral n * (bh - 0.4) / 4) ((bw - 0.65) / 3) 0.05 (s * 0.35 + 1) (Color 118 162 177 255)
    "battery" -> do
      buildingBox width height camera x y bw bh (s * 1.1) (Color 95 124 122 255)
      forM_ [0 .. 2 :: Int] $ \n -> tileQuad width height camera (x + 0.3 + fromIntegral n * (bw - 0.6) / 3) (y + 0.3) 0.2 (bh - 0.6) (s * 1.1 + 1) (Color 202 216 177 255)
    "tank" -> do
      drawEllipse (round cx) (round cy) (s * bw / 2) (s * bh / 4) (Color 85 140 150 255)
      drawRectangle (round (cx - s * bw / 2)) (round (cy - s * 1.3)) (round (s * bw)) (round (s * 1.3)) (Color 94 153 162 255)
      drawEllipse (round cx) (round (cy - s * 1.3)) (s * bw / 2) (s * bh / 4) (Color 175 210 201 255)
    _ -> do
      pitched (if name `elem` ["warehouse", "depot"] then Color 183 145 106 255 else cream) (Color 130 98 73 255)
      let quantity = sum [stock r | r <- allResources]
      forM_ [0 .. min 4 ((quantity + 199999) `div` 200000) - 1] $ \n -> buildingBox width height camera (x + 0.2 + fromInteger (n `mod` 3) * 0.6) (y + bh + 0.15 + fromInteger (n `div` 3) * 0.55) 0.45 0.45 (s * 0.45) (Color 195 153 91 255)

vehicleXY :: RoadTopology -> VehiclePosition -> (Float, Float)
vehicleXY _ (AtRoadNode node) = let (x, y) = nodeXY node in (fromInteger x + 0.5, fromInteger y + 0.5)
vehicleXY topology (Traversing from to remaining _) =
  let (x, y) = nodeXY from
      (u, v) = nodeXY to
      cost = maybe 1 roadCost (M.lookup (edgeKey from to) (roadEdges topology))
      fraction = max 0 (min 1 (1 - fromInteger remaining / fromInteger (max 1 cost)))
   in (fromInteger x + 0.5 + fromInteger (u - x) * fraction, fromInteger y + 0.5 + fromInteger (v - y) * fraction)

buildingColor :: String -> Color
buildingColor name
  | name `elem` ["hand_pump", "pump", "tank", "brine_pump"] = Color 124 173 174 255
  | name `elem` ["farm", "greenhouse"] = Color 160 160 103 255
  | name `elem` ["kitchen", "pantry"] = Color 229 188 121 255
  | name `elem` ["solar", "battery"] = Color 102 119 121 255
  | name == "housing" = Color 236 205 162 255
  | otherwise = Color 189 135 101 255

drawView :: NativeFont -> Int -> Int -> Double -> Vector2 -> Screen -> Maybe String -> IO [Button]
drawView font width height time mouse screen previewFailure = do
  clearBackground paper
  sites <- drawColony font width height time mouse screen previewFailure
  let game = screenGame screen
      world = gameWorld game
      d = gameDescriptor game
      campaign = gameCampaign game
      paused = worldMode world /= Active || Help.helpTopic (screenHelpUi screen) /= Nothing
      right = fromIntegral width - 386
      bottom = fromIntegral height - 114
      hour = elapsedTicks world campaign `div` 1200
      minute = elapsedTicks world campaign `mod` 1200 `div` 20
      SimTick absoluteTick = simTick world
      clockHour = (absoluteTick `div` 1200) `mod` 24
      people = M.elems (needsResidents (worldNeeds world))
      served = all (\person -> residentHourWaterDue person == residentHourWaterServed person && residentHourFoodDue person == residentHourFoodServed person) people
      top =
        [button 239 18 132 (if paused then "▶ 進める" else "Ⅱ 停止") (Choose ToggleTime) paused]
          ++ [button (383 + fromIntegral n * 48) 18 44 (show speed ++ "×") (ChangeSpeed speed) (screenSpeed screen == speed) | (n, speed) <- zip [0 :: Int ..] [1, 2, 4, 8]]
          ++ [button (fromIntegral width - 220) 18 88 "保存" SaveNow False, button (fromIntegral width - 122) 18 96 "保存一覧" ShowLibrary False]
      dock = [button 28 (bottom + 60) 130 "建てる" (SelectTab BuildingTab) (screenTab screen == BuildingTab), button 169 (bottom + 60) 176 "食事の場" (SelectTab DiningTab) (screenTab screen == DiningTab), button 356 (bottom + 60) 114 "飾る" (SelectTab PlacesTab) (screenTab screen == PlacesTab), button 481 (bottom + 60) 114 "配送" (SelectTab SupplyTab) (screenTab screen == SupplyTab), button 606 (bottom + 60) 130 "班を見る" (SelectTab PeopleTab) (screenTab screen == PeopleTab), button 747 (bottom + 60) 130 "全体へ" HomeView False]
      helpButton = button (fromIntegral width - 250) (bottom + 60) 120 "遊び方" (HelpCommand (Help.OpenHelp (contextTopic screen))) False
      overview = screenTab screen == ColonyTab && screenSelected screen == Nothing
      panelOpen = not overview
  drawRectangle 0 0 width 100 paper
  drawLine 0 99 width 99 line
  txt font "RED DUNE" 28 14 26 copper
  txt font "赤い土地に、暮らしをつくる" 29 60 20 muted
  txt font (printf "%02d:%02d" clockHour minute) 599 15 29 ink
  txt font ("開拓 " ++ show (hour `div` 24 + 1) ++ "日目") 600 59 20 muted
  stockBadge font 728 17 "水" (P.physical world (s01Pantry d) Water) 10000 water
  stockBadge font 884 17 "食事" (P.physical world (s01Pantry d) Ration) 5000 mint
  txt font (show (length (filter ((== Living) . residentStatus) people)) ++ "人 " ++ if served && hour > 0 then "配給が届いています" else if not served then "配給が足りません" else "備蓄から、暮らしへ") 730 71 20 (if served then mint else copper)
  hintButtons <- if isPlainScreen screen then drawHint font screen else pure []
  content <-
    if panelOpen
      then do
        card (right - 20) 121 378 (fromIntegral height - 251) panel
        controls <- drawPanel font right 147 height screen
        pure (button (right + 290) 132 44 "×" ClearSelection False : controls)
      else pure []
  drawRectangle 0 (height - 114) width 114 paper
  drawLine 0 (height - 114) width (height - 114) line
  let notice = if null (screenNotice screen) then if paused then "時間は停止中。施設を選んで作業を始められます。" else "建物を選ぶ / ホイールで拡大 / WASDで移動" else screenNotice screen
  txt font notice 28 (bottom + 16) 22 ink
  txt font (if screenSaved screen then "保存済み" else "自動保存待ち") (fromIntegral width - 126) (bottom + 73) 18 muted
  when (campaignFreshPantry campaign && overview) $ do
    card 30 (bottom - 68) 520 46 (Color 244 246 215 243)
    txt font (if campaignFreshConsumed campaign > 0 then "新しい食事を食べた  " ++ resourceAmount Ration (campaignFreshConsumed campaign) else "つくった食事が、暮らしに届いた") 46 (bottom - 59) 24 mint
  let panelHelp = [button (right + 205) 132 78 "見方" (HelpCommand (Help.OpenHelp (contextTopic screen))) False | panelOpen]
      normal = (if panelOpen then filter (\b -> let Rectangle x _ _ _ = buttonRect b in x < right - 25) sites else sites) ++ top ++ dock ++ content ++ panelHelp ++ [button 28 342 226 "向きを変える ↻" RotateBuilding False | canRotateBuild screen] ++ hintButtons ++ [helpButton]
      visible = filter (not . null . buttonLabel) normal
  underlying <- case screenDialog screen of
    NoDialog -> mapM_ (drawButton font mouse) visible >> pure normal
    dialog -> do
      mapM_ (drawButton font (Vector2 (-1) (-1))) visible
      drawRectangle 0 0 width height (Color 29 28 25 165)
      case dialog of
        DiningPreview (S.Tile tx ty) _ _ _ -> do
          let px = fromInteger tx
              py = fromInteger ty
              corners = [project width height (screenCamera screen) x y | (x, y) <- [(px, py), (px + 3, py), (px + 3, py + 3), (px, py + 3)]]
              Vector2 cx cy = project width height (screenCamera screen) (px + 1.5) (py + 1.5)
          forM_ (zip corners (drop 1 corners ++ take 1 corners)) $ \(a, b) -> drawLineEx a b 4 (Color 255 229 142 255)
          card (cx - 94) (cy - 102) 188 40 paper
          txt font "選んだ場所" (cx - 80) (cy - 97) 23 copper
        _ -> pure ()
      dialogButtons <- drawDialog font width height dialog
      mapM_ (drawButton font mouse) dialogButtons
      drawButton font mouse helpButton
      pure (dialogButtons ++ [helpButton])
  case Help.helpTopic (screenHelpUi screen) of
    Nothing -> pure underlying
    Just topic -> do
      drawRectangle 0 0 width height (Color 29 28 25 165)
      controls <- drawHelp font width height screen topic
      mapM_ (drawButton font mouse) controls
      pure controls

isPlainScreen :: Screen -> Bool
isPlainScreen screen = Help.helpTopic (screenHelpUi screen) == Nothing && case screenDialog screen of NoDialog -> True; _ -> False

canRotateBuild :: Screen -> Bool
canRotateBuild screen = case screenBuild screen of Just name -> name `notElem` ["road", "detail-erase"]; Nothing -> False

contextTopic :: Screen -> Help.TopicId
contextTopic screen = case screenDialog screen of
  Welcome {} -> Help.SavingAndResume
  SaveLibrary {} -> Help.SavingAndResume
  LoadPreview {} -> Help.SavingAndResume
  NewCampaign -> Help.TimeAndControls
  Conclusion {} -> Help.TimeAndControls
  DiningPreview {} -> Help.DiningAndPlaces
  _ -> case screenBuild screen of
    Just name | take 7 name == "detail-" -> Help.DiningAndPlaces
    Just "dining" -> Help.DiningAndPlaces
    Just _ -> Help.RoadsAndBuilding
    _ -> case screenTab screen of
      SupplyTab -> Help.DeliveryAndStock
      BuildingTab -> Help.RoadsAndBuilding
      PeopleTab -> Help.ShiftCrews
      PlacesTab -> Help.DiningAndPlaces
      DiningTab -> Help.DiningAndPlaces
      ColonyTab -> case screenSelected screen of
        Just ident | isDiningSite game ident -> Help.DiningAndPlaces
        Just ident | ident `elem` [s01Pump d, s01Farm d, s01Kitchen d] -> Help.WaterAndFood
        Just _ -> Help.RoadsAndBuilding
        Nothing -> Help.TimeAndControls
  where
    game = screenGame screen; d = gameDescriptor game

contextDescription :: Screen -> String
contextDescription screen = case screenDialog screen of
  LoadPreview {} -> "保存の確認中です。閉じると、この確認画面に戻ります。"
  SaveLibrary {} -> "保存一覧を開いています。閉じると、同じ一覧に戻ります。"
  Welcome {} -> "前回の開拓を選べます。保存を確認してから再開します。"
  DiningPreview {} -> "食事の場を建てる前の確認です。場所と費用を確かめられます。"
  _ -> case screenBuild screen of
    Just "road" -> "道路を配置中です。閉じると、選んだ始点の続きに戻ります。"
    Just name | take 7 name == "detail-" -> "飾りを配置中です。閉じると、選んだ飾りと向きの続きに戻ります。"
    Just _ -> "建設場所を選んでいます。閉じると、同じ計画の続きに戻ります。"
    _ -> case screenTab screen of
      ColonyTab | Just ident <- screenSelected screen -> siteName (sitePrototype (screenGame screen) ident) ++ "：" ++ statusTitle (siteStatus (screenGame screen) ident)
      ColonyTab -> "全体の地図を見ています。建物を選ぶと、作業や在庫を確認できます。"
      _ -> "元の画面：" ++ Help.topicTitle (contextTopic screen) ++ "。読む間は時間が進みません。"

sitePrototype :: GameState -> EntityId -> String
sitePrototype game ident = case worldM1 (gameWorld game) >>= M.lookup ident . S.spatialPlacements . m1Space of
  Just placement -> case S.placementShape placement of S.BuildingShape name _ _ -> name; _ -> "road"
  Nothing -> "施設"

hintForScreen :: Screen -> Maybe Help.HintId
hintForScreen screen
  | not (isPlainScreen screen) = Nothing
  | screenBuild screen == Just "road" = Just Help.RoadHint
  | screenTab screen == PlacesTab = Just Help.PlacesHint
  | screenTab screen == SupplyTab = Just Help.DeliveryHint
  | screenTab screen == PeopleTab = Just Help.CrewsHint
  | screenTab screen == DiningTab = diningHint
  | screenTab screen /= ColonyTab = Nothing
  | Just ident <- screenSelected screen =
      if ident == s01Pump d && inactive ident
        then Just Help.WellHint
        else
          if ident == s01Farm d && inactive ident
            then Just Help.FarmHint
            else
              if ident == s01Kitchen d && inactive ident
                then Just Help.KitchenHint
                else
                  if ident == s01Kitchen d && not fresh
                    then Just Help.FirstFoodHint
                    else
                      if isDiningSite game ident
                        then diningHint
                        else Nothing
  | inactive (s01Pump d) = Just Help.WellHint
  | inactive (s01Farm d) = Just Help.FarmHint
  | inactive (s01Kitchen d) = Just Help.KitchenHint
  | not fresh = Just Help.FirstFoodHint
  | otherwise = diningHint
  where
    game = screenGame screen
    d = gameDescriptor game
    inactive ident = ident `notElem` P.productionSites (gamePolicies game)
    fresh = campaignFreshPantry (gameCampaign game)
    diningHint = case diningStatuses game of
      [] -> if fresh then Just Help.DiningPlanHint else Nothing
      status : _ -> if null (diningMeals status) then Nothing else Just Help.DiningUseHint

hintRectangle :: Rectangle
hintRectangle = Rectangle 28 124 592 196

drawHint :: NativeFont -> Screen -> IO [Button]
drawHint font screen = case Help.activeHint (screenHelpUi screen) of
  Nothing -> pure []
  Just hint -> do
    let (title, detail) = Help.hintCopy hint
        d = gameDescriptor (screenGame screen)
        action = case hint of
          Help.WellHint -> ("井戸を見る", SelectSite (s01Pump d))
          Help.FarmHint -> ("農場を見る", SelectSite (s01Farm d))
          Help.KitchenHint -> ("厨房を見る", SelectSite (s01Kitchen d))
          Help.FirstFoodHint -> ("厨房を見る", SelectSite (s01Kitchen d))
          Help.DiningPlanHint -> ("場所を選ぶ", SelectTab DiningTab)
          Help.DiningUseHint -> ("周りを飾る", SelectTab PlacesTab)
          _ -> ("詳しく", HelpCommand (Help.OpenHelp (Help.hintTopic hint)))
        secondary = if fst action == "詳しく" then [] else [button 219 268 98 "詳しく" (HelpCommand (Help.OpenHelp (Help.hintTopic hint))) False]
    card 28 124 592 196 (Color 255 249 234 243)
    txt font title 46 136 26 ink
    wrap font detail 46 180 548 21 muted
    pure ([button 46 268 164 (fst action) (snd action) False, button 325 268 98 "閉じる" (HelpCommand Help.DismissHint) False, button 431 268 164 "案内OFF" (HelpCommand (Help.SetGuides False)) False] ++ secondary)

drawHelp :: NativeFont -> Int -> Int -> Screen -> Help.TopicId -> IO [Button]
drawHelp font width height screen topic = do
  let x = 60
      y = 100
      w = fromIntegral width - 120
      h = fromIntegral height - 180
      cx = x + 250
      textWidth = min 760 (w - 282)
      footer = y + h - 72
      enabled = Help.guidesEnabled (Help.helpPreferences (screenHelpUi screen))
      topics = [button (x + 26) (y + 116 + fromIntegral n * 60) 194 (Help.topicTitle chapter) (HelpCommand (Help.OpenHelp chapter)) (chapter == topic) | (n, chapter) <- zip [0 :: Int ..] Help.allTopics]
  card x y w h paper
  txt font "遊び方" (x + 26) (y + 20) 30 copper
  txt font "どの章からでも読めます" (x + 26) (y + 77) 18 muted
  txt font (Help.topicTitle topic) cx (y + 25) 30 copper
  wrap font (contextDescription screen) cx (y + 79) textWidth 21 muted
  contentEnd <-
    foldM
      ( \sectionY (heading, body) -> do
          txt font heading cx sectionY 23 ink
          bodyEnd <- wrapMeasured font body cx (sectionY + 38) textWidth 20 ink
          pure (bodyEnd + 12)
      )
      (y + 165)
      (Help.topicSections topic)
  when (contentEnd < footer - 42) (txt font "読んでいる間は時間が止まります。Escで元の画面に戻ります。" (x + 26) (footer - 36) 20 muted)
  pure (topics ++ [button (x + 26) footer 194 (if enabled then "短い案内：ON" else "短い案内：OFF") (HelpCommand (Help.SetGuides (not enabled))) enabled, button (x + 234) footer 222 "案内をもう一度" (HelpCommand Help.RepeatHints) False, button (x + w - 232) footer 206 "元の画面へ" (HelpCommand Help.CloseHelp) True])

stockBadge :: NativeFont -> Float -> Float -> String -> Integer -> Integer -> Color -> IO ()
stockBadge font x y label amount hourly color = do
  let hours = fromInteger amount / fromInteger hourly :: Double
  card x y 140 49 (Color 240 231 207 255)
  txt font (label ++ " " ++ printf "%.1f" hours) (x + 8) (y + 1) 23 (if hours < 2 then copper else color)
  txt font "時間分の備蓄" (x + 8) (y + 29) 19 muted

meter :: NativeFont -> Float -> Float -> String -> String -> Float -> Color -> IO ()
meter font x y label value fraction color = do
  txt font label x y 15 muted
  txt font value (x + 212) y 17 (if fraction < 0.15 then copper else ink)
  card x (y + 25) 322 8 (Color 226 208 184 255)
  card x (y + 25) (max 0 (min 322 (322 * fraction))) 8 color

wrap :: NativeFont -> String -> Float -> Float -> Float -> Float -> Color -> IO ()
wrap font content x y width size color = void (wrapMeasured font content x y width size color)

-- Return the first free vertical position so callers can place controls after the text.
-- Measuring with the drawing font keeps Japanese lines inside the panel's width.
wrapMeasured :: NativeFont -> String -> Float -> Float -> Float -> Float -> Color -> IO Float
wrapMeasured font content x top width size color = do
  linesToDraw <- wrappedLines font content width size
  forM_ (zip [0 :: Int ..] linesToDraw) $ \(row, lineText) -> txt font lineText x (top + fromIntegral row * (size * 1.45 + 4)) size color
  pure (top + fromIntegral (length linesToDraw) * (size * 1.45 + 4))

wrappedLines :: NativeFont -> String -> Float -> Float -> IO [String]
wrappedLines font content width size = go content
  where
    go [] = pure []
    go remaining = do
      fitting <- longestFitting remaining 1 (length remaining)
      let count = safeBreak remaining fitting
      let lineText = take count remaining
      (lineText :) <$> go (drop count remaining)
    safeBreak remaining count
      | count > 1,
        count < length remaining,
        remaining !! count `elem` "、。，．！？・）】』」ぁぃぅぇぉっゃゅょー" || remaining !! (count - 1) `elem` "（【『「" =
          safeBreak remaining (count - 1)
      | otherwise = count
    longestFitting remaining low high
      | low >= high = pure low
      | otherwise = do
          let middle = (low + high + 1) `div` 2
          Vector2 measured _ <- measureLabel font (take middle remaining) size
          if measured <= width
            then longestFitting remaining middle high
            else longestFitting remaining low (middle - 1)

drawPanel :: NativeFont -> Float -> Float -> Int -> Screen -> IO [Button]
drawPanel font x y height screen = do
  let game = screenGame screen; world = gameWorld game; d = gameDescriptor game; policy = gamePolicies game
  case screenTab screen of
    DiningTab -> drawDiningPanel font x y game
    PlacesTab -> do
      txt font "街を飾る" x (y + 7) 28 copper
      wrap font "飾りを選び、地面をクリック。Rで回転できます。" x (y + 65) 320 21 muted
      let choices = [("石畳", "detail-square"), ("日陰の席", "detail-bench"), ("植栽鉢", "detail-garden"), ("灯り", "detail-lantern")]
      forM_ (zip [0 :: Int ..] [PlaceSquare, PlaceBench, PlaceGarden, PlaceLantern]) $ \(n, kind) -> do
        let sx = x + fromIntegral (n `mod` 2) * 172 + 52; sy = y + 160 + fromIntegral (n `div` 2) * 154
        card (sx - 50) (sy - 23) 134 64 (Color 229 212 177 70)
        drawPlace (round (sx * 2)) (round ((sy + 35) * 2)) (Camera 0.5 0.5 27 0) 0 (S.Tile 0 0) kind S.R0
      txt font "置き直す時は、先に片づけます。" x (y + 461) 21 ink
      pure ([button (x + fromIntegral (n `mod` 2) * 172) (y + 197 + fromIntegral (n `div` 2) * 154) 160 label (SelectBuild key) (screenBuild screen == Just key) | (n, (label, key)) <- zip [0 :: Int ..] choices] ++ [button x (y + 516) 332 "置いたものを片付ける" (SelectBuild "detail-erase") False])
    ColonyTab | Just ident <- screenSelected screen -> drawInspector font x y height screen ident
    ColonyTab -> do
      txt font "開拓の手順" x y 21 copper
      let commissions =
            [ button x (y + 39) 322 "1  水と運搬の班を配置" (Choose (Commission WaterWorks)) (s01Pump d `elem` P.productionSites policy),
              button x (y + 84) 322 "2  農場と厨房の班を配置" (Choose (Commission FoodWorks)) (s01Farm d `elem` P.productionSites policy),
              button x (y + 129) 322 "3  建設と保守を準備" (Choose (Commission ServiceWorks)) (P.assistMaintenance policy)
            ]
      forM_ (zip [0 :: Int ..] (objectives game)) $ \(n, (complete, label, progress)) -> do
        let py = y + 190 + fromIntegral n * 52
        txt font (if complete then "●" else "○") x py 19 (if complete then mint else muted)
        txt font label (x + 28) py 17 ink
        txt font progress (x + 28) (py + 24) 13 muted
      pure commissions
    SupplyTab -> do
      txt font "配送" x y 30 copper
      txt font "届け先の備蓄を調整" x (y + 57) 22 muted
      let order route = (P.policyPriority route, maybe 9 id (lookup (P.policyId route) (zip ["pantry-water", "pantry-food", "farm-water", "kitchen-crops", "kitchen-water", "kitchen-fuel"] [0 :: Int ..])), P.policyId route)
          routes = sortOn order (P.deliveryPolicies policy)
          page = max 0 (min ((max 1 (length routes) - 1) `div` 4) (screenSupplyPage screen))
          shown = take 4 (drop (page * 4) routes)
      controls <-
        fmap concat $
          mapM
            ( \(n, route) -> do
                let py = y + 94 + fromIntegral n * 116
                    (status, _) = P.policyStatus world route
                    label = case status of "disabled" -> "停止中"; "deliveryInFlight" -> "荷車で運搬中"; "bufferSatisfied" -> "補充はまだ不要です"; "sourceEmpty" -> "送り元の在庫待ち"; "destinationFull" -> "届け先が満杯"; _ -> "出荷を待っています"
                    amount = P.physical world (P.policyDestination route) (P.policyResource route)
                card x py 332 108 (Color 241 233 211 255)
                txt font (deliveryName world route) (x + 10) (py + 4) 22 ink
                txt font label (x + 10) (py + 35) 20 muted
                txt font ("現在 " ++ resourceAmount (P.policyResource route) amount) (x + 10) (py + 59) 19 (resourceColor (P.policyResource route))
                txt font ("目標 " ++ resourceAmount (P.policyResource route) (P.policyTarget route)) (x + 10) (py + 83) 19 muted
                pure [button (x + 174) (py + 60) 44 "－" (Choose (ChangeBuffer (P.policyId route) (-P.policyBatch route))) False, button (x + 224) (py + 60) 44 "＋" (Choose (ChangeBuffer (P.policyId route) (P.policyBatch route))) False, button (x + 282) (py + 60) 44 (if P.policyEnabled route then "Ⅱ" else "▶") (Choose (ToggleDelivery (P.policyId route))) False]
            )
            (zip [0 :: Int ..] shown)
      when (null routes) (wrap font "井戸や厨房を動かすと、ここに配送が現れます。" x (y + 110) 332 24 ink)
      txt font (show (page + 1) ++ "/" ++ show (max 1 ((length routes + 3) `div` 4))) (x + 145) (y + 574) 22 muted
      pure (controls ++ [button x (y + 568) 134 "前の経路" (SupplyPage (max 0 (page - 1))) False, button (x + 198) (y + 568) 134 "次の経路" (SupplyPage (min ((max 1 (length routes) - 1) `div` 4) (page + 1))) False])
    BuildingTab -> do
      txt font "建てる" x y 30 copper
      wrap font "種類を選び、地面をクリック。道路は両端を選びます。" x (y + 59) 332 22 muted
      let preferred = ["road", "warehouse", "tank", "farm", "kitchen", "housing", "solar", "pump"]
          canUseSource name = Set.null (S.sourceRequirements (worldContent world) name) || not (null (sourcesFor game name))
          prototypes = filter canUseSource (preferred ++ filter (`notElem` preferred) C.liveBuildablePrototypes)
          page = max 0 (min ((length prototypes - 1) `div` 8) (screenPalettePage screen))
          shown = take 8 (drop (page * 8) prototypes)
          selectedSources = maybe [] (sourcesFor game) (screenBuild screen)
          controls = [button (x + fromIntegral (n `mod` 2) * 172) (y + 169 + fromIntegral (n `div` 2) * 83) 160 (siteName name) (SelectBuild name) (screenBuild screen == Just name) | (n, name) <- zip [0 :: Int ..] shown]
          sourceControls = [button (x + fromIntegral n * 172) (y + 521) 160 (resourceName (S.sourceRegionResource source) ++ if sourceRemaining world source <= 0 then " 枯渇" else "を見る") (FocusSource (S.sourceRegionId source)) False | (n, source) <- zip [0 :: Int ..] (take 2 selectedSources)]
      forM_ (zip [0 :: Int ..] shown) $ \(n, name) -> do
        let sx = x + fromIntegral (n `mod` 2) * 172
            sy = y + 138 + fromIntegral (n `div` 2) * 83
            cost = if name == "road" then M.singleton Stone 2000 else maybe M.empty buildingCost (M.lookup name (contentBuildings (worldContent world)))
            label = case M.toAscList cost of (resource, amount) : _ -> resourceName resource ++ " " ++ resourceAmount resource amount; _ -> ""
        txt font label (sx + 8) sy 19 muted
      txt font (if null selectedSources then "材料と班が現場を進めます。" else if all ((<= 0) . sourceRemaining world) selectedSources then "資源区画は枯渇しています。" else "資源に辺で接し、入口は区画の外へ。") x (y + 495) (if null selectedSources then 22 else 18) ink
      txt font (show (page + 1) ++ "/" ++ show ((length prototypes + 7) `div` 8)) (x + 145) (y + 574) 22 muted
      pure (controls ++ sourceControls ++ [button x (y + 568) 134 "前の施設" (PalettePage (max 0 (page - 1))) False, button (x + 198) (y + 568) 134 "次の施設" (PalettePage (min ((length prototypes - 1) `div` 8) (page + 1))) False])
    PeopleTab -> do
      txt font "三交代の班" x y 28 copper
      case worldM1 world of
        Nothing -> pure []
        Just state -> do
          let workforce = m1Workforce state; residents = M.elems (needsResidents (worldNeeds world))
          forM_ [0 .. 2 :: Integer] $ \shift -> do
            let py = y + 49 + fromInteger shift * 76
                assigned = concat [names | ((_, s), names) <- M.toList (W.workforceRosters workforce), s == shift]
                group = filter ((== shift) . residentShift) residents
            txt font (show (shift + 1) ++ "班  " ++ show (length assigned) ++ " / " ++ show (length group) ++ "人を配置") x py 18 ink
            txt font ("最大疲労 " ++ show (maximum (0 : map residentFatigue group) `div` 10) ++ "% / 休息は交代時に") x (py + 28) 14 muted
          txt font "予備の人員" x (y + 301) 18 copper
          textEnd <- wrapMeasured font "保守と建設は同じ予備班を使います。保守を先に行い、終わると建設に戻ります。施設を選ぶと担当を配置・解除できます。" x (y + 337) 320 19 muted
          let actionY = max (y + 427) (textEnd + 6)
          pure
            [ button x actionY 322 (if P.assistMaintenance policy then "保守班：有効" else "保守班：停止") (Choose ToggleRepairs) (P.assistMaintenance policy),
              button x (actionY + 54) 322 (if P.assistConstruction policy then "建設班：有効" else "建設班：停止") (Choose ToggleBuildingCrews) (P.assistConstruction policy)
            ]

drawDiningPanel :: NativeFont -> Float -> Float -> GameState -> IO [Button]
drawDiningPanel font x y game = do
  txt font "食事の場" x (y + 7) 30 copper
  case diningStatuses game of
    [] -> do
      wrap font "日陰の食卓を、好きな場所へ。厨房で作った料理を運び、住民がここで食べます。" x (y + 74) 332 24 ink
      let sx = x + 158; sy = y + 252
      drawFacility (round (sx * 2)) (round ((sy + 35) * 2)) (Camera 1.5 1.5 24 0) 0 0 "pantry" 0 0 3 3 False 0 (const 0)
      wrap font "道と建物を一緒に計画します。建材と予備班が工事を進めます。" x (y + 323) 332 22 muted
      txt font "席や灯りで周りを飾れます。" x (y + 463) 21 ink
      pure [button x (y + 408) 332 "場所を選ぶ" (SelectBuild "dining") True, button x (y + 508) 332 "周りを飾る" (SelectTab PlacesTab) False]
    status : _ -> do
      let built = diningBuilt status
          meals = diningMeals status
          served = length meals
          title = if not built then "完成を待っています" else if served > 0 then "前回の食事をここでとった人" else if diningStock status > 0 then "料理が届きました" else if diningIncoming status > 0 then "料理を運んでいます" else "厨房の料理を待っています"
          color = if served > 0 then mint else if built then water else copper
          S.Tile tx ty = diningTile status
      txt font ("選んだ場所  " ++ show tx ++ ", " ++ show ty) x (y + 62) 22 muted
      card x (y + 108) 332 148 (Color 240 234 212 255)
      txt font title (x + 12) (y + 120) (if served > 0 then 20 else 24) color
      if served > 0
        then do
          txt font (show served ++ "人") (x + 12) (y + 151) 36 color
          txt font ("料理 " ++ resourceAmount Ration (diningStock status)) (x + 12) (y + 209) 22 mint
        else do
          txt font "ここにある料理" (x + 12) (y + 163) 22 muted
          txt font (resourceAmount Ration (diningStock status)) (x + 12) (y + 198) 23 mint
      txt font ("運搬中 " ++ resourceAmount Ration (diningIncoming status)) x (y + 280) 22 water
      txt font ("使う予定の住民 " ++ show (length (diningResidents status)) ++ "人") x (y + 330) 24 ink
      txt font "各班2人に、利用を割り当てます" x (y + 369) 20 muted
      wrap font (if not built then "建設が終わるまでは、いつもの配給所で食事をします。" else "勤務していない住民が、現地の料理を食べます。空の時は通常の配給を使います。") x (y + 408) 332 21 muted
      pure (if served > 0 then [button x (y + 500) 332 "周りを飾る" (SelectTab PlacesTab) True, button x (y + 552) 332 "この場所を見にいく" (FocusDining (diningTile status)) False] else [button x (y + 500) 332 "この場所を見にいく" (FocusDining (diningTile status)) True, button x (y + 552) 332 "周りを飾る" (SelectTab PlacesTab) False])

objectives :: GameState -> [(Bool, String, String)]
objectives game =
  let c = gameCampaign game; s = campaignScenario c
   in [ (campaignProduced c > 0, "新しい食料を作る", printf "生産 %.1f kg" (fromInteger (campaignProduced c) / 1000 :: Double)),
        (campaignFreshConsumed c >= scenarioFreshFood s, "運び、食べる", printf "%.1f / %.1f kg" (fromInteger (campaignFreshConsumed c) / 1000 :: Double) (fromInteger (scenarioFreshFood s) / 1000 :: Double)),
        (campaignExpanded c, "予備の施設を建て、使う", "道路 → 建設 → 実際に備蓄"),
        (campaignRecovered c, "厨房の故障を乗り越える", if campaignDisrupted c then "部品と保守班で修復" else "開拓24時間後に故障"),
        (campaignStableTicks c >= scenarioStableHours s * 1200, "交代を越えて配給を保つ", show (campaignStableTicks c `div` 1200) ++ " / " ++ show (scenarioStableHours s) ++ "時間の安定"),
        (campaignEnding c == SettlementSecured, "この土地に根づく", show (elapsedTicks (gameWorld game) c `div` 1200) ++ " / " ++ show (scenarioHours s) ++ "時間")
      ]

drawDialog :: NativeFont -> Int -> Int -> Dialog -> IO [Button]
drawDialog font width height dialog = do
  let x = case dialog of DiningPreview {} -> fromIntegral width - 626; _ -> fromIntegral width / 2 - 300
      y = fromIntegral height / 2 - 280
  card x y 600 550 paper
  case dialog of
    DiningPreview (S.Tile tx ty) rotation roads cost -> do
      txt font "ここに、食事の場をつくる" (x + 40) (y + 35) 28 copper
      txt font ("選んだ場所 " ++ show tx ++ ", " ++ show ty) (x + 40) (y + 93) 24 ink
      txt font ("つなぐ道路 " ++ show roads ++ "本") (x + 40) (y + 142) 24 ink
      txt font "合計費用" (x + 40) (y + 190) 22 ink
      forM_ (zip [0 :: Int ..] [(resource, amount) | (resource, amount) <- M.toAscList cost, amount > 0]) $ \(row, (resource, amount)) ->
        txt font (resourceName resource ++ " " ++ resourceAmount resource amount) (x + 40) (y + 228 + fromIntegral row * 34) 22 ink
      wrap font "食事の場は1か所。確定後の移設・取消はできません。席や灯りはいつでも並べ替えられます。" (x + 40) (y + 294) 520 22 muted
      pure [button (x + 40) (y + 415) 520 "ここに建てる" (ConfirmDining (S.Tile tx ty) rotation) True, button (x + 40) (y + 466) 520 "場所を選び直す" (SelectBuild "dining") False]
    Introduction scenario -> do
      txt font "RED DUNE" (x + 40) (y + 32) 36 copper
      txt font "40人が、この赤い土地で暮らし始める。" (x + 40) (y + 93) 24 ink
      wrap font (if scenario == "recovery" then "厨房は壊れ、配給所の食料は12時間分。修復を急ぎ、生産と運搬を立て直してください。" else "手元の備蓄は数日分。水をくみ、作物を育て、食事を作り、40人に届ける暮らしを築いてください。") (x + 40) (y + 145) 520 20 muted
      wrap font "班を三交代で配置し、道路を通して運びます。建設も修復も、人と物資がそろって初めて進みます。時間はいつでも止められます。" (x + 40) (y + 242) 520 19 ink
      txt font "最初は一時停止。準備してから時間を進めましょう。" (x + 40) (y + 360) 18 copper
      pure [button (x + 40) (y + 416) 520 "開拓を始める" CloseDialog True, button (x + 40) (y + 466) 520 "別のシナリオを選ぶ" ShowNewCampaign False]
    NewCampaign -> do
      txt font "新しい開拓" (x + 40) (y + 35) 30 copper
      wrap font "現在の進行を保存してから、新しい分岐を始めます。過去の保存は残ります。" (x + 40) (y + 96) 520 18 ink
      txt font "定住 ―― 備蓄から暮らしへ" (x + 40) (y + 180) 22 ink
      wrap font "水と食料の生産を築き、予備の倉庫を使い、厨房の故障を越えて66時間の開拓を続ける。" (x + 40) (y + 220) 510 17 muted
      txt font "回復 ―― 壊れた供給線" (x + 40) (y + 334) 22 ink
      wrap font "厨房は停止。食料は12時間分。限られた備蓄から立て直し、42時間の安定を取り戻す。" (x + 40) (y + 374) 510 17 muted
      pure [button (x + 40) (y + 278) 520 "定住を始める" (StartScenario "settlement") True, button (x + 40) (y + 434) 520 "回復を始める" (StartScenario "recovery") False, button (x + 40) (y + 484) 520 "戻る" CloseDialog False]
    Welcome catalog -> do
      txt font "おかえりなさい" (x + 40) (y + 35) 32 copper
      txt font "赤い土地の暮らしを、続けよう。" (x + 40) (y + 96) 23 ink
      wrap font "前回の開拓は、一時停止で再開します。保存の内容を確認してから、時間を進められます。" (x + 40) (y + 150) 520 20 muted
      case Store.catalogEntries catalog of
        latest : _ -> do
          txt font ("前回：開拓 " ++ show (Store.checkpointHour latest) ++ "時間 / " ++ scenarioCaption (Store.checkpointScenario latest)) (x + 40) (y + 264) 20 ink
          pure
            [ button (x + 40) (y + 317) 520 "前回の開拓を確認" (ReadSave (Store.checkpointName latest)) True,
              button (x + 40) (y + 369) 520 "ほかの保存から選ぶ" ShowLibrary False,
              button (x + 40) (y + 421) 520 "新しい開拓を始める" ShowNewCampaign False,
              button (x + 420) (y + 477) 140 "終了" QuitGame False
            ]
        [] -> pure [button (x + 40) (y + 421) 520 "新しい開拓を始める" ShowNewCampaign True]
    SaveLibrary catalog page -> do
      let entries = Store.catalogEntries catalog
      txt font ("保存された開拓  " ++ show (page + 1) ++ "/" ++ show (max 1 ((Store.catalogTotal catalog + 6) `div` 7))) (x + 40) (y + 35) 30 copper
      txt font "選択 → 内容の確認 → 新しい分岐で再開" (x + 40) (y + 89) 17 muted
      when
        (Store.catalogUnreadable catalog > 0)
        (txt font ("このページで読めない保存 " ++ show (Store.catalogUnreadable catalog) ++ "件 / 正常な保存を選べます") (x + 40) (y + 114) 12 copper)
      let shown = take 7 entries
          choices = [button (x + 40) (y + 135 + fromIntegral n * 45) 520 ("履歴 " ++ show (Store.checkpointBranch e) ++ "・保存 " ++ show (Store.checkpointSequence e) ++ " / " ++ show (Store.checkpointHour e) ++ "時間 / " ++ if Store.checkpointScenario e == "recovery" then "回復" else "定住") (ReadSave (Store.checkpointName e)) False | (n, e) <- zip [0 :: Int ..] shown]
      when (null entries) (txt font "このページに読める保存はありません。" (x + 40) (y + 155) 20 muted)
      pure (choices ++ [button (x + 40) (y + 477) 120 "前へ" (LibraryPage (max 0 (page - 1))) False, button (x + 171) (y + 477) 120 "次へ" (LibraryPage (min (max 0 ((Store.catalogTotal catalog - 1) `div` 7)) (page + 1))) False, button (x + 420) (y + 477) 140 "戻る" CloseDialog False])
    LoadPreview preview -> do
      let game = Store.previewGame preview; c = gameCampaign game
      txt font "この開拓から、再開する" (x + 40) (y + 35) 28 copper
      txt font ("開拓 " ++ show (elapsedTicks (gameWorld game) c `div` 1200) ++ "時間 / " ++ show (M.size (needsResidents (worldNeeds (gameWorld game)))) ++ "人") (x + 40) (y + 104) 23 ink
      let (title, _) = advice game
      wrap font title (x + 40) (y + 160) 520 22 muted
      wrap font "現在の進行は保存して残します。選んだ保存も残したまま、新しい分岐として一時停止で再開します。" (x + 40) (y + 242) 520 20 ink
      txt font "読み込む前に、もう一度データを検証します。" (x + 40) (y + 363) 16 muted
      pure [button (x + 40) (y + 415) 520 "保存して、この開拓から再開" ConfirmLoad True, button (x + 40) (y + 466) 520 "キャンセル" CloseDialog False]
    Conclusion game -> do
      let campaign = gameCampaign game; secured = campaignEnding campaign == SettlementSecured
      txt font (if secured then "この土地に、暮らしが根づいた。" else "開拓を立て直そう。") (x + 35) (y + 37) 28 copper
      wrap font (if secured then "水が運ばれ、作物が食事になり、交代を越えて40人の暮らしが続きました。" else "供給が途絶えました。過去の保存から選択をやり直すことも、新しい開拓を始めることもできます。") (x + 40) (y + 104) 520 20 ink
      txt font ("開拓 " ++ show (elapsedTicks (gameWorld game) campaign `div` 1200) ++ "時間") (x + 40) (y + 223) 24 copper
      txt font ("作った食料  " ++ resourceAmount Ration (campaignProduced campaign)) (x + 40) (y + 270) 20 ink
      txt font ("届いて食べた新しい食料  " ++ resourceAmount Ration (campaignFreshConsumed campaign)) (x + 40) (y + 313) 20 ink
      txt font ("連続して守った安全な配給  " ++ show (campaignStableTicks campaign `div` 1200) ++ "時間") (x + 40) (y + 356) 20 ink
      pure
        [ button (x + 40) (y + 422) 520 "開拓の画面に戻る" CloseDialog True,
          button (x + 40) (y + 472) 520 "別の開拓を始める" ShowNewCampaign False
        ]
    NoDialog -> pure []

scenarioCaption :: String -> String
scenarioCaption scenario = if scenario == "recovery" then "回復" else "定住"

isDiningSite :: GameState -> EntityId -> Bool
isDiningSite game ident = case worldM1 (gameWorld game) >>= M.lookup ident . S.spatialPlacements . m1Space of
  Just placement -> case S.placementShape placement of S.BuildingShape "pantry" tile _ -> M.member tile (gameDiningPlaces game); _ -> False
  _ -> False

drawInspector :: NativeFont -> Float -> Float -> Int -> Screen -> EntityId -> IO [Button]
drawInspector font x y height screen ident
  | isDiningSite (screenGame screen) ident = drawDiningPanel font x y (screenGame screen)
  | otherwise = do
      let game = screenGame screen
          world = gameWorld game
          policy = gamePolicies game
          placement = worldM1 world >>= M.lookup ident . S.spatialPlacements . m1Space
          name = case S.placementShape <$> placement of Just (S.BuildingShape prototype _ _) -> prototype; Just (S.RoadShape _) -> "road"; _ -> "施設"
          status = siteStatus game ident
          stock resource = sum [P.physical world owner resource | owner@(Owner _ target) <- M.keys (invStorage (worldInventory world)), target == ident]
          stocks = [(resource, stock resource) | resource <- allResources, stock resource > 0]
          crew = rosterCount game ident
          worksite = worldM1 world >>= find (\job -> C.constructionSiteId job == ident && not (C.constructionTerminal job)) . M.elems . C.constructionJobs . m1Construction
          active = ident `elem` P.productionSites policy && maybe False siteEnabled (M.lookup ident (worldSites world))
          configured = crew > 0 && maybe False siteEnabled (M.lookup ident (worldSites world))
          starting = worksite == Nothing && not active && not configured && name `elem` ["hand_pump", "farm", "kitchen"]
          stoppedDescription = (if statusMood status == MoodBusy then "進行中の作業は続きます。" else "") ++ "次の生産は始めません。担当と配送は残ります。"
          startDescription = case name of
            "hand_pump" -> "井戸・配給所・荷車の担当を三交代に配置します。押すと時間が進みます。"
            "farm" -> "農場の担当と水の配送を準備します。押すと時間が進みます。"
            "kitchen" -> "厨房の担当と材料・料理の配送を準備します。押すと時間が進みます。"
            _ -> statusDetail status
      let detailText = if starting then startDescription else if configured && not active then stoppedDescription else statusDetail status
          detailSize = if starting || configured && not active || worksite /= Nothing then 20 else 22
      detailLines <- wrappedLines font detailText 303 detailSize
      let detailPitch = detailSize * 1.45 + 4
          detailBottom = y + 148 + fromIntegral (length detailLines) * detailPitch
          progressY = max (y + 235) (detailBottom + 5)
          cardBottom = max (y + 227) (case statusProgress status of Nothing -> detailBottom + 12; Just _ -> progressY + 48)
          actionY = max (y + 292) (cardBottom + 16)
          stockY = max (y + 470) (actionY + 178)
      txt font (siteName name) x (y + 7) 25 copper
      txt font (if crew > 0 then "各班 " ++ show crew ++ "人を配置" else if name == "housing" then "住人の寝床" else "この場所でできること") x (y + 57) 22 muted
      card x (y + 99) 334 (cardBottom - y - 99) (Color 240 233 215 255)
      drawCircleV (Vector2 (x + 16) (y + 122)) 6 (moodColor (statusMood status))
      txt font (statusTitle status) (x + 32) (y + 107) 24 (moodColor (statusMood status))
      forM_ (zip [0 :: Int ..] detailLines) $ \(row, lineText) -> txt font lineText (x + 14) (y + 148 + fromIntegral row * detailPitch) detailSize ink
      case statusProgress status of
        Nothing -> pure ()
        Just progress -> do
          card x progressY 334 10 (Color 224 211 184 255)
          card x progressY (max 0 (min 334 (progress * 334))) 10 (moodColor (statusMood status))
          txt font (show (round (progress * 100) :: Int) ++ "%") (x + 265) (progressY + 18) 23 ink
      controls <- case worksite of
        Just _ -> pure [button x actionY 334 (if P.assistConstruction policy then "建設班を休ませる" else "建設班を動かす") (Choose ToggleBuildingCrews) (P.assistConstruction policy), button x (actionY + 54) 334 "この計画を取り消す" (Choose (CancelPlan ident)) False]
        Nothing
          | M.member ident (worldSites world) || name == "pantry" -> do
              let beginLabel = case name of
                    "hand_pump" -> "水を汲み始める"
                    "farm" -> "作物を育て始める"
                    "kitchen" -> "料理を作り始める"
                    _ -> "班を配置して動かす"
                  begin = button x actionY 334 beginLabel (BeginWork ident) True
                  pause = button x actionY 334 "連続生産を止める" (Choose (ToggleProduction ident)) False
                  resume = button x actionY 334 "連続生産を再開" (Choose (ToggleProduction ident)) True
              pure ((if active then [pause] else if configured then [resume] else if name == "pantry" && crew > 0 then [] else [begin]) ++ [button x (actionY + 54) 334 "配送の様子を見る" (SelectTab SupplyTab) False] ++ [button x (actionY + 108) 334 "この施設の班を外す" (Choose (ReleaseFacility ident)) False | crew > 0])
          | otherwise -> pure []
      Vector2 _ amountHeight <- measureLabel font "99999.9 kg" 25
      let secondRowBottom = stockY + 40 + 66 + 25 + amountHeight
          pageSize = if secondRowBottom <= fromIntegral height - 130 then 4 else 2
          pages = max 1 ((length stocks + pageSize - 1) `div` pageSize)
          page = screenStockPage screen `mod` pages
      txt font "ここにある物資" x stockY 23 ink
      forM_ (zip [0 :: Int ..] (take pageSize (drop (page * pageSize) stocks))) $ \(n, (resource, amount)) -> do
        let sx = x + fromIntegral (n `mod` 2) * 169; sy = stockY + 40 + fromIntegral (n `div` 2) * 66
        txt font (resourceName resource) sx sy 20 muted
        txt font (resourceAmount resource amount) sx (sy + 25) 25 (resourceColor resource)
      when (null stocks) (txt font "まだ物資は届いていません" x (stockY + 43) 22 muted)
      pure (controls ++ [button (x + 169) (stockY - 4) 165 "次の物資" (StockPage ((page + 1) `mod` pages)) False | pages > 1])
