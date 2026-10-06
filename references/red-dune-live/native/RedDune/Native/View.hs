{-# LANGUAGE PatternSynonyms #-}

module RedDune.Native.View where

import Colony.Construction qualified as C
import Colony.Content
import Colony.Jobs
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
import Control.Monad (forM_, when)
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as Set
import Raylib.Core
import Raylib.Core.Shapes
import Raylib.Types (Color (..), Rectangle (..), Vector2, pattern Vector2)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.Native.Font (NativeFont, drawNativeText, measureNativeText)
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.Policies qualified as P
import Text.Printf (printf)

data Tab = ColonyTab | SupplyTab | BuildingTab | PeopleTab deriving (Eq, Show, Read, Enum, Bounded)

data Camera = Camera {cameraX :: !Float, cameraY :: !Float, cameraScale :: !Float, cameraRotation :: !Int} deriving (Eq, Show)

homeCamera :: Camera
homeCamera = Camera 82 49 10 0

data Dialog = NoDialog | Introduction String | Welcome Store.Catalog | SaveLibrary Store.Catalog Int | LoadPreview Store.Preview | NewCampaign | Conclusion GameState

data Screen = Screen
  { screenGame :: !GameState,
    screenTab :: !Tab,
    screenSelected :: !(Maybe EntityId),
    screenCamera :: !Camera,
    screenBuild :: !(Maybe String),
    screenSpeed :: !Int,
    screenDialog :: !Dialog,
    screenNotice :: !String,
    screenSaved :: !Bool,
    screenAutoPause :: !Bool,
    screenPalettePage :: !Int,
    screenSupplyPage :: !Int,
    screenBuildRotation :: !S.Rotation
  }

data UiCommand
  = Choose Decision
  | SelectSite EntityId
  | ClearSelection
  | SelectTab Tab
  | SelectBuild String
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
  | RotateBuilding
  deriving (Eq, Show)

newScreen :: GameState -> Dialog -> Screen
newScreen game dialog =
  Screen
    { screenGame = game,
      screenTab = ColonyTab,
      screenSelected = Nothing,
      screenCamera = homeCamera,
      screenBuild = Nothing,
      screenSpeed = 1,
      screenDialog = dialog,
      screenNotice = "",
      screenSaved = False,
      screenAutoPause = True,
      screenPalettePage = 0,
      screenSupplyPage = 0,
      screenBuildRotation = S.R0
    }

data Button = Button {buttonRect :: !Rectangle, buttonLabel :: !String, buttonCommand :: !UiCommand, buttonActive :: !Bool}

ink, muted, paper, panel, copper, mint, water, warning, line :: Color
ink = Color 40 30 31 255
muted = Color 111 87 76 255
paper = Color 249 238 218 255
panel = Color 255 248 233 248
copper = Color 150 57 36 255
mint = Color 51 112 99 255
water = Color 65 121 148 255
warning = Color 194 91 45 255
line = Color 209 182 154 255

txt :: NativeFont -> String -> Float -> Float -> Float -> Color -> IO ()
txt font label x y size color = drawNativeText font label (Vector2 x y) size 0.6 color

card :: Float -> Float -> Float -> Float -> Color -> IO ()
card x y width height color = drawRectangleRounded (Rectangle x y width height) 0.08 5 color

inside :: Vector2 -> Rectangle -> Bool
inside (Vector2 x y) (Rectangle u v width height) = x >= u && y >= v && x < u + width && y < v + height

button :: Float -> Float -> Float -> String -> UiCommand -> Bool -> Button
button x y width label command active = Button (Rectangle x y width 37) label command active

drawButton :: NativeFont -> Vector2 -> Button -> IO ()
drawButton font mouse b = do
  let Rectangle x y width height = buttonRect b
      hovered = inside mouse (buttonRect b)
      color = if buttonActive b then copper else if hovered then Color 237 217 190 255 else Color 243 230 210 255
  card x y width height color
  txt font (buttonLabel b) (x + 12) (y + 9) 17 (if buttonActive b then paper else ink)

project :: Int -> Int -> Camera -> Float -> Float -> Vector2
project width height camera x y =
  let dx = x - cameraX camera
      dy = y - cameraY camera
      (u, v) = case cameraRotation camera `mod` 4 of 0 -> (dx, dy); 1 -> (-dy, dx); 2 -> (-dx, -dy); _ -> (dy, -dx)
      scale = cameraScale camera
   in Vector2 (fromIntegral (width - 370) / 2 + (u - v) * scale) (100 + fromIntegral (height - 260) / 2 + (u + v) * scale * 0.47)

unproject :: Int -> Int -> Camera -> Vector2 -> S.Tile
unproject width height camera (Vector2 sx sy) =
  let u = (sx - fromIntegral (width - 370) / 2) / cameraScale camera
      v = (sy - 100 - fromIntegral (height - 260) / 2) / (cameraScale camera * 0.47)
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

drawColony :: NativeFont -> Int -> Int -> Double -> Vector2 -> Screen -> IO ()
drawColony font width height time mouse screen = do
  let camera = screenCamera screen
      game = screenGame screen
      world = gameWorld game
      p = project width height camera
      scale = cameraScale camera
  beginScissorMode 0 85 (width - 370) (height - 235)
  drawRectangleGradientV 0 85 (width - 370) (height - 235) (Color 206 148 107 255) (Color 231 181 130 255)
  -- Authored contour bands are cosmetic; authoritative terrain remains in Space.
  forM_ [0 .. 16 :: Int] $ \n -> do
    let y = 110 + n * 43; shift = 15 * sin (fromIntegral n * 1.4)
    drawLineEx (Vector2 (-80 + shift) (fromIntegral y)) (Vector2 (fromIntegral width) (fromIntegral (y + 180))) 3 (Color 188 124 89 30)
  forM_ [0 .. 24 :: Int] $ \n -> do
    let x = fromIntegral ((n * 43 + 17) `mod` 130)
        y = fromIntegral ((n * 29 + 23) `mod` 108)
        v = p x y
    drawPoly v (5 + n `mod` 3) (3 + scale * 0.17) (fromIntegral (n * 31)) (Color 143 87 69 90)
  case worldM1 world of
    Nothing -> pure ()
    Just state -> do
      let space = m1Space state
      forM_ (Set.toAscList (S.spatialRoads space)) $ \(S.Tile x y) -> tileQuad width height camera (fromInteger x) (fromInteger y) 1 1 0 (Color 151 105 78 255)
      forM_ (M.elems (S.spatialSources space)) $ \source -> case S.sourceRegionBounds source of
        S.Rect (S.Tile x y) w h -> do
          tileQuad width height camera (fromInteger x) (fromInteger y) (fromInteger w) (fromInteger h) 0 (Color 93 138 143 80)
          let Vector2 lx ly = p (fromInteger x) (fromInteger y)
          when (S.sourceRegionKind source == "aquifer") (txt font "地下水" lx (ly + 10) 14 water)
      forM_ (sortOn (depth camera) (M.elems (S.spatialPlacements space))) $ \placement -> case S.placementShape placement of
        S.RoadShape (S.Tile x y) -> when (S.placementStage placement /= S.Built) $ tileQuad width height camera (fromInteger x) (fromInteger y) 1 1 0 (Color 244 194 95 190)
        S.BuildingShape name (S.Tile x y) rotation -> do
          let (fw, fh) = maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
              (bw, bh) = if rotation `elem` [S.R90, S.R270] then (fromInteger fh, fromInteger fw) else (fromInteger fw, fromInteger fh)
              px = fromInteger x
              py = fromInteger y
              selected = screenSelected screen == Just (S.placementId placement)
              broken = maybe False ((== FacilityBroken) . maintenanceStatus) (M.lookup (S.placementId placement) (maintenanceFacilities (worldMaintenance world)))
              roof = if broken then Color 169 74 55 255 else buildingColor name
              elevation = if name `elem` ["farm", "solar"] then scale * 0.3 else scale * 1.45
          when selected $ tileQuad width height camera (px - 0.4) (py - 0.4) (bw + 0.8) (bh + 0.8) 0 (Color 254 224 137 255)
          if S.placementStage placement /= S.Built
            then do
              tileQuad width height camera px py bw bh 0 (Color 238 190 96 170)
              buildingBox width height camera px py 0.28 bh (scale * 1.8) (Color 125 76 52 255)
              buildingBox width height camera (px + bw - 0.28) py 0.28 bh (scale * 1.8) (Color 125 76 52 255)
            else do
              buildingBox width height camera px py bw bh elevation roof
              case name of
                "farm" -> forM_ [0 .. 4 :: Int] $ \r -> tileQuad width height camera (px + 0.4) (py + 0.35 + fromIntegral r * 0.65) (bw - 0.8) 0.32 (elevation + 1) (Color 93 134 79 255)
                "solar" -> forM_ [0 .. 2 :: Int] $ \r -> tileQuad width height camera (px + 0.25 + fromIntegral r * 0.95) (py + 0.3) 0.65 (bh - 0.6) (elevation + 2) (Color 45 74 83 255)
                "housing" -> do
                  tileQuad width height camera (px + 0.3) (py + 0.4) (bw - 0.6) 0.35 (elevation + 1) (Color 221 141 91 255)
                  tileQuad width height camera (px + 0.3) (py + bh - 0.75) (bw - 0.6) 0.35 (elevation + 1) (Color 221 141 91 255)
                "hand_pump" -> do
                  let Vector2 cx cy = p (px + bw / 2) (py + bh / 2)
                  drawEllipse (round cx) (round (cy - elevation)) (scale * 0.65) (scale * 0.32) (Color 229 217 173 255)
                  drawLineEx (Vector2 cx (cy - elevation)) (Vector2 cx (cy - elevation - scale * 1.4)) 3 water
                "kitchen" -> do
                  let chimney = p (px + bw - 0.8) (py + 0.6)
                  drawCircleV (raise (elevation + scale * 0.8) chimney) (scale * 0.28) (Color 103 69 58 255)
                  when (not broken && any (\job -> M.lookup (jobId job) (worldJobSites world) == Just (S.placementId placement) && jobPhase job == Running) (M.elems (worldJobs world))) $
                    forM_ [0 .. 2 :: Int] $
                      \n -> drawCircleV (raise (elevation + scale * (1.2 + fromIntegral n * 0.7) + realToFrac (sin time) * 2) chimney) (scale * 0.25) (Color 250 238 209 100)
                _ -> pure ()
          when (selected || name `elem` ["farm", "kitchen", "pantry", "hand_pump"]) $ do
            let Vector2 lx ly = p (px + bw / 2) (py + bh / 2)
                label = siteName name
                size = if selected then 17 else 14
            Vector2 labelWidth _ <- measureNativeText font label size 0.6
            card (lx - labelWidth / 2 - 8) (ly - elevation - 27) (labelWidth + 16) 24 (Color 250 240 220 230)
            txt font label (lx - labelWidth / 2) (ly - elevation - 24) size (if broken then copper else ink)
      -- Every dot represents one current named worker claim, grouped at work.
      forM_ (zip [0 :: Int ..] (M.toAscList (W.workforceClaims (m1Workforce state)))) $ \(n, (_, target)) -> do
        let ident = case target of W.OperateFacility i -> i; W.ConstructSite i -> i; W.MaintainJob i -> maybe i maintenanceTarget (M.lookup i (maintenanceJobs (worldMaintenance world))); W.DriveVehicle _ -> EntityId 0
        case M.lookup ident (S.spatialPlacements space) of
          Just placement -> case S.placementShape placement of
            S.BuildingShape _ (S.Tile x y) _ -> do
              let pos = p (fromInteger x + 0.5 + fromIntegral (n `mod` 4) * 0.4) (fromInteger y + 4.8)
              drawCircleV (raise 1 pos) (max 2 (scale * 0.18)) mint
            _ -> pure ()
          Nothing -> pure ()
      forM_ (M.elems (transportVehicles (worldTransport world))) $ \vehicle -> do
        let (x, y) = vehicleXY (transportTopology (worldTransport world)) (vehiclePosition vehicle)
            Vector2 vx vy = p x y
            color = if vehicleJob vehicle == Nothing then Color 94 71 61 255 else Color 242 220 156 255
        drawCircleV (Vector2 (vx + 2) (vy + 4)) (scale * 0.4) (Color 76 47 35 70)
        card (vx - scale * 0.5) (vy - scale * 0.5) scale (scale * 0.64) color
        drawCircleV (Vector2 (vx - scale * 0.3) vy) (scale * 0.15) ink
        drawCircleV (Vector2 (vx + scale * 0.3) vy) (scale * 0.15) ink
      case screenBuild screen of
        Nothing -> pure ()
        Just name -> do
          let S.Tile tx ty = unproject width height camera mouse
              footprint = if name == "road" then (1, 1) else maybe (3, 3) buildingFootprint (M.lookup name (contentBuildings (worldContent world)))
              (bw, bh) = if screenBuildRotation screen `elem` [S.R90, S.R270] then (snd footprint, fst footprint) else footprint
          tileQuad width height camera (fromInteger tx) (fromInteger ty) (fromInteger bw) (fromInteger bh) 0 (Color 252 232 140 170)
  endScissorMode
  where
    depth camera placement = case S.placementShape placement of
      S.BuildingShape _ (S.Tile x y) _ -> depthXY camera x y
      S.RoadShape (S.Tile x y) -> depthXY camera x y
    depthXY camera x y = case cameraRotation camera `mod` 4 of 0 -> x + y; 1 -> x - y; 2 -> -x - y; _ -> y - x

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

drawView :: NativeFont -> Int -> Int -> Double -> Vector2 -> Screen -> IO [Button]
drawView font width height time mouse screen = do
  clearBackground paper
  drawColony font width height time mouse screen
  let game = screenGame screen
      world = gameWorld game
      d = gameDescriptor game
      campaign = gameCampaign game
      right = fromIntegral width - 354
      lower = fromIntegral height - 142
      SimTick tick = simTick world
      hour = elapsedTicks world campaign `div` 1200
      minute = elapsedTicks world campaign `mod` 1200 `div` 20
      people = M.elems (needsResidents (worldNeeds world))
      food = P.physical world (s01Pantry d) Ration
      waterStock = P.physical world (s01Pantry d) Water
      healthy = length (filter ((== Living) . residentStatus) people)
      topButtons =
        [button 258 23 102 (if worldMode world == Active then "一時停止" else "再開") (Choose ToggleTime) (worldMode world /= Active)]
          ++ [button (372 + fromIntegral n * 50) 23 44 (show speed ++ "×") (ChangeSpeed speed) (screenSpeed screen == speed) | (n, speed) <- zip [0 :: Int ..] [1, 2, 4, 8]]
          ++ [button (fromIntegral width - 304) 23 83 "保存" SaveNow False, button (fromIntegral width - 212) 23 83 "読み込む" ShowLibrary False, button (fromIntegral width - 120) 23 96 "新しい開拓" ShowNewCampaign False]
      tabs = [button (right + fromIntegral n * 81) 105 76 label (SelectTab tab) (screenTab screen == tab) | (n, (label, tab)) <- zip [0 :: Int ..] [("暮らし", ColonyTab), ("供給", SupplyTab), ("建設", BuildingTab), ("住民", PeopleTab)]]
  drawRectangle 0 0 width 84 paper
  txt font "RED DUNE" 26 18 31 copper
  txt font "赤い土地に、暮らしをつくる" 28 53 13 muted
  txt font (printf "%02d:%02d" hour minute) 594 17 28 ink
  txt font ("開拓 " ++ show (hour `div` 24 + 1) ++ "日目 / " ++ show ((tick `div` 9600) `mod` 3 + 1) ++ "班") 594 52 13 muted
  drawRectangle (width - 370) 84 370 (height - 84) panel
  drawLine (width - 370) 84 (width - 370) height line
  txt font (show healthy ++ "人 / 健康 " ++ show (minimum (1000 : map residentHealth people) `div` 10) ++ "%") right 162 18 ink
  meter font right 196 "配給所の水" (printf "%.1f 時間" (fromInteger waterStock / 10000 :: Double)) (fromInteger waterStock / 120000) water
  meter font right 243 "配給所の食料" (printf "%.1f 時間" (fromInteger food / 5000 :: Double)) (fromInteger food / 60000) mint
  contentButtons <- drawPanel font right 302 height screen
  drawRectangle 0 (height - 150) (width - 370) 150 paper
  let (title, detail) = advice game
  txt font title 28 (lower + 3) 24 copper
  wrap font detail 28 (lower + 40) (fromIntegral (width - 426)) 17 muted
  txt font (if null (screenNotice screen) then "建物を選択 / WASD 移動 / ホイール 拡大 / Q・E 回転 / F 全体 / Space 一時停止" else screenNotice screen) 28 (fromIntegral height - 41) 15 ink
  txt font (if screenSaved screen then "保存済み" else "進行は自動保存されます") 28 (fromIntegral height - 20) 12 muted
  let bottomButtons = [button (right + 4) (fromIntegral height - 58) 318 (if screenAutoPause screen then "重要な警報で停止：有効" else "重要な警報で停止：無効") ToggleAlerts (screenAutoPause screen)]
      normal = topButtons ++ tabs ++ contentButtons ++ bottomButtons
  case screenDialog screen of
    NoDialog -> mapM_ (drawButton font mouse) normal >> pure normal
    dialog -> do
      mapM_ (drawButton font (Vector2 (-1) (-1))) normal
      drawRectangle 0 0 width height (Color 29 21 21 165)
      dialogButtons <- drawDialog font width height dialog
      mapM_ (drawButton font mouse) dialogButtons
      pure dialogButtons

meter :: NativeFont -> Float -> Float -> String -> String -> Float -> Color -> IO ()
meter font x y label value fraction color = do
  txt font label x y 15 muted
  txt font value (x + 212) y 17 (if fraction < 0.15 then copper else ink)
  card x (y + 25) 322 8 (Color 226 208 184 255)
  card x (y + 25) (max 0 (min 322 (322 * fraction))) 8 color

wrap :: NativeFont -> String -> Float -> Float -> Float -> Float -> Color -> IO ()
wrap font text x y width size color = forM_ (zip [0 :: Int ..] (chunks (max 1 (floor (width / size))) text)) $ \(n, label) -> txt font label x (y + fromIntegral n * (size + 7)) size color
  where
    chunks _ [] = []; chunks count rest = take count rest : chunks count (drop count rest)

drawPanel :: NativeFont -> Float -> Float -> Int -> Screen -> IO [Button]
drawPanel font x y _height screen = do
  let game = screenGame screen; world = gameWorld game; d = gameDescriptor game; policy = gamePolicies game
  case screenTab screen of
    ColonyTab | Just ident <- screenSelected screen -> drawInspector font x y game ident
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
      txt font "物資の通り道" x y 21 copper
      txt font "止まった経路を直し、余裕を調整" x (y + 30) 14 muted
      let order route = (P.policyPriority route, maybe 9 id (lookup (P.policyId route) (zip ["pantry-water", "pantry-food", "farm-water", "kitchen-crops", "kitchen-water", "kitchen-fuel"] [0 :: Int ..])), P.policyId route)
          routes = sortOn order (P.deliveryPolicies policy)
          page = max 0 (min ((max 1 (length routes) - 1) `div` 6) (screenSupplyPage screen))
          shown = take 6 (drop (page * 6) routes)
      buttons <-
        fmap concat $
          mapM
            ( \(n, route) -> do
                let py = y + 65 + fromIntegral n * 66
                    (status, _) = P.policyStatus world route
                    label = case status of "disabled" -> "停止"; "deliveryInFlight" -> "運搬中"; "bufferSatisfied" -> "備蓄十分"; "sourceEmpty" -> "供給元が空"; "destinationFull" -> "受取先が満杯"; _ -> "出荷待ち"
                    amount = P.physical world (P.policyDestination route) (P.policyResource route)
                txt font (deliveryName world route) x py 16 ink
                txt font label x (py + 27) 13 muted
                txt font (printf "%.0f/%.0f" (fromInteger amount / 1000 :: Double) (fromInteger (P.policyTarget route) / 1000 :: Double)) (x + 112) (py + 27) 13 muted
                pure
                  [ button (x + 208) (py + 20) 36 "－" (Choose (ChangeBuffer (P.policyId route) (-P.policyBatch route))) False,
                    button (x + 249) (py + 20) 36 "＋" (Choose (ChangeBuffer (P.policyId route) (P.policyBatch route))) False,
                    button (x + 290) (py + 20) 32 (if P.policyEnabled route then "✓" else "×") (Choose (ToggleDelivery (P.policyId route))) False
                  ]
            )
            (zip [0 :: Int ..] shown)
      when (null routes) (wrap font "暮らしタブで班を配置すると、配送計画がここに現れます。" x (y + 75) 314 18 muted)
      txt font (show (page + 1) ++ "/" ++ show (max 1 ((length routes + 5) `div` 6))) (x + 135) (y + 471) 16 muted
      pure
        ( buttons
            ++ [ button x (y + 463) 115 "前の経路" (SupplyPage (max 0 (page - 1))) False,
                 button (x + 203) (y + 463) 119 "次の経路" (SupplyPage (min ((max 1 (length routes) - 1) `div` 6) (page + 1))) False
               ]
        )
    BuildingTab -> do
      txt font "土地を育てる" x y 21 copper
      let upper = [button x (y + 40) 322 "予備倉庫と道路を計画" (Choose ReserveWarehouse) False]
          prototypes = "road" : C.liveBuildablePrototypes
          page = max 0 (min ((length prototypes - 1) `div` 12) (screenPalettePage screen))
          shown = take 12 (drop (page * 12) prototypes)
      txt font "選んで地図へ / R 回転 / Esc 解除" x (y + 91) 14 muted
      let choices = [button (x + fromIntegral (n `mod` 2) * 163) (y + 122 + fromIntegral (n `div` 2) * 43) 155 (siteName name) (SelectBuild name) (screenBuild screen == Just name) | (n, name) <- zip [0 :: Int ..] shown]
      txt font (show (page + 1) ++ "/" ++ show ((length prototypes + 11) `div` 12)) (x + 138) (y + 406) 16 muted
      pure
        ( upper
            ++ choices
            ++ [ button x (y + 397) 115 "前の施設" (PalettePage (max 0 (page - 1))) False,
                 button (x + 203) (y + 397) 119 "次の施設" (PalettePage (min ((length prototypes - 1) `div` 12) (page + 1))) False
               ]
        )
    PeopleTab -> do
      txt font "三つの班で、暮らしをつなぐ" x y 20 copper
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
          wrap font "保守と建設は同じ予備班を使います。保守を先に行い、終わると建設に戻ります。施設を選ぶと班を配置・解放できます。" x (y + 337) 320 17 muted
          pure
            [ button x (y + 427) 322 (if P.assistMaintenance policy then "保守班：有効" else "保守班：停止") (Choose ToggleRepairs) (P.assistMaintenance policy),
              button x (y + 473) 322 (if P.assistConstruction policy then "建設班：有効" else "建設班：停止") (Choose ToggleBuildingCrews) (P.assistConstruction policy)
            ]

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
  let x = fromIntegral width / 2 - 300; y = fromIntegral height / 2 - 280
  card x y 600 550 paper
  case dialog of
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
      txt font "保存された開拓" (x + 40) (y + 35) 30 copper
      txt font "選択 → 内容の確認 → 新しい分岐で再開" (x + 40) (y + 89) 17 muted
      when
        (Store.catalogUnreadable catalog > 0 || Store.catalogOlder catalog > 0)
        (txt font ("最新256件を表示 / 読めない保存 " ++ show (Store.catalogUnreadable catalog) ++ "件 / 以前 " ++ show (Store.catalogOlder catalog) ++ "件") (x + 40) (y + 114) 12 copper)
      let shown = take 7 (drop (page * 7) entries)
          choices = [button (x + 40) (y + 135 + fromIntegral n * 45) 520 ("履歴 " ++ show (Store.checkpointBranch e) ++ "・保存 " ++ show (Store.checkpointSequence e) ++ " / " ++ show (Store.checkpointHour e) ++ "時間 / " ++ if Store.checkpointScenario e == "recovery" then "回復" else "定住") (ReadSave (Store.checkpointName e)) False | (n, e) <- zip [0 :: Int ..] shown]
      when (null entries) (txt font "まだ保存がありません。" (x + 40) (y + 155) 20 muted)
      pure (choices ++ [button (x + 40) (y + 477) 120 "前へ" (LibraryPage (max 0 (page - 1))) False, button (x + 171) (y + 477) 120 "次へ" (LibraryPage (min (max 0 ((length entries - 1) `div` 7)) (page + 1))) False, button (x + 420) (y + 477) 140 "戻る" CloseDialog False])
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

drawInspector :: NativeFont -> Float -> Float -> GameState -> EntityId -> IO [Button]
drawInspector font x y game ident = do
  let world = gameWorld game
      policy = gamePolicies game
      placement = worldM1 world >>= M.lookup ident . S.spatialPlacements . m1Space
      name = case S.placementShape <$> placement of Just (S.BuildingShape prototype _ _) -> prototype; Just (S.RoadShape _) -> "road"; _ -> "施設"
      EntityId number = ident
      activeJobs = maybe [] (filter ((== ident) . C.constructionSiteId) . M.elems . C.constructionJobs . m1Construction) (worldM1 world)
      stock resource = sum [P.physical world owner resource | owner@(Owner _ ownerId) <- M.keys (invStorage (worldInventory world)), ownerId == ident]
  txt font (siteName name) x y 27 copper
  txt font ("施設 " ++ show number ++ " / " ++ case S.placementStage <$> placement of Just S.Built -> "完成"; _ -> "建設中") x (y + 39) 14 muted
  wrap font (siteReport game ident) x (y + 71) 319 16 ink
  txt font "施設にある物資" x (y + 135) 17 copper
  let stocks = [(resource, stock resource) | resource <- allResources, stock resource > 0]
  forM_ (zip [0 :: Int ..] (take 6 stocks)) $ \(n, (resource, amount)) -> do
    let cellX = x + fromIntegral (n `mod` 2) * 164; cellY = y + 163 + fromIntegral (n `div` 2) * 43
    txt font (resourceName resource) cellX cellY 14 muted
    txt font (resourceAmount resource amount) cellX (cellY + 18) 15 ink
  when (length stocks > 6) (txt font ("ほか " ++ show (length stocks - 6) ++ "種類") x (y + 277) 12 muted)
  case filter (not . C.constructionTerminal) activeJobs of
    job : _ -> do
      let progress = C.constructionProgress job; required = C.constructionRequired (C.constructionSnapshot job)
      meter font x (y + 308) "建設の進行" (show (progress * 100 `div` max 1 required) ++ "%") (fromInteger progress / fromInteger (max 1 required)) mint
      txt font (case C.constructionBlocked job of Nothing -> "物資と作業員を待っています"; Just problem -> take 30 (show problem)) x (y + 364) 14 muted
      pure [button x (y + 417) 322 "建設計画を取り消す" (Choose (CancelPlan ident)) False, button x (y + 466) 322 "開拓の手順に戻る" ClearSelection False]
    _ ->
      pure
        ( [button x (y + 467) 322 "開拓の手順に戻る" ClearSelection False]
            ++ if M.member ident (worldSites world)
              then
                [ button x (y + 295) 155 "三交代の班を配置" (Choose (StaffFacility ident)) False,
                  button (x + 164) (y + 295) 158 "班を解放" (Choose (ReleaseFacility ident)) False,
                  button x (y + 337) 322 (if ident `elem` P.productionSites policy then "連続生産：有効" else "連続生産：停止") (Choose (ToggleProduction ident)) (ident `elem` P.productionSites policy),
                  button x (y + 421) 322 "材料と出荷の配送をつなぐ" (Choose (ConnectFacility ident)) False,
                  button x (y + 379) 322 (if maybe False siteEnabled (M.lookup ident (worldSites world)) then "施設を停止する" else "施設を動かす") (Choose (SetFacility ident (not (maybe False siteEnabled (M.lookup ident (worldSites world)))))) False
                ]
              else []
        )
