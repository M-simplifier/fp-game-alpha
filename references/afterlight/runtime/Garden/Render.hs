{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}

module Garden.Render (renderScene, renderSceneWith, renderPhotoChrome, renderPhotoFrame, renderPhotoToast, renderInterface, renderMenu, renderSaveFeedback) where

import Control.Monad (forM_, when)
import Data.IORef (readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Garden.Mesh (palette)
import Garden.Photo
import Garden.Render.Chunk
import Garden.Render.HUD qualified as HUD
import Garden.Render.Radiance
import Garden.Render.Resources
import Garden.Render.Settings
import Garden.Types
import Garden.View
import Raylib.Core
import Raylib.Core.Models (drawCubeV, drawCubeWiresV)
import Raylib.Core.Shapes
import Raylib.Core.Text (drawText)
import Raylib.Types
import Raylib.Util (blendMode, mode2D)

cameraFor :: SceneView -> Camera3D
cameraFor view = Camera3D (toRay (sceneEye view)) (toRay (plus (sceneEye view) (sceneForward view))) (Vector3 0 1 0) 68 CameraPerspective

renderScene :: Resources -> SceneView -> Float -> IO ()
renderScene = renderSceneWith Nothing

renderSceneWith :: Maybe Photo -> Resources -> SceneView -> Float -> IO ()
renderSceneWith portrait resources view pulse = do
  width <- getScreenWidth
  height <- getScreenHeight
  settings <- readIORef (resourceQuality resources)
  let ws = resourceShader resources
      f = sceneForward view
      fov = maybe 68 photoFov portrait
      lens = tan (fov * pi / 360)
      (right, upCorrect) = photoBasis (maybe 0 photoRoll portrait) f
      camera = Camera3D (toRay (sceneEye view)) (toRay (plus (sceneEye view) f)) (toRay upCorrect) fov CameraPerspective
      grading = case portrait of
        Nothing -> Vector3 0 0 1
        Just p -> Vector3 (photoExposure p) (fromIntegral (fromEnum (photoGrade p))) (if photoBloom p then 1 else 0)
      chosen = settings {bloom = bloom settings && maybe True photoBloom portrait}
      visible = visibleChunk (sceneEye view) f right upCorrect lens (fromIntegral sceneWidth / fromIntegral sceneHeight)
      (sceneWidth, sceneHeight) = sceneSize (renderPlan (width, height) chosen)
  lamps <- readIORef (resourceLights resources)
  let points = take 8 (sortOn (distance (sceneEye view)) lamps)
  uniform resources ws "lightCount" (ShaderUniformInt (length points))
  when (not (null points)) $
    setShaderValueV ws "lightPositions" (ShaderUniformVec3V (map toRay points)) (resourceWindow resources)
  (_, chunks) <- readIORef (resourceChunks resources)
  let opaque isShadow accepts = do
        forM_ (M.toList chunks) $ \(key, models) ->
          when (accepts key) $
            forM_ models (\m -> drawPrepared m (V3 0 0 0) 0 1 white)
        forM_ (resourceRelic resources) (\m -> drawRelic m (sceneTime view))
        drawKin isShadow resources view
        drawEnemies isShadow resources view
      shadow camera' = opaque True (shadowVisible chunkRadius camera' . toRay . chunkCenter)
      scene = do
        opaque False visible
        drawAtmosphere view
        drawBursts view
        case sceneTarget view of
          TerrainTarget c _ (Ore g) _ -> drawCubeWiresV (toRay (center c)) (Vector3 1.014 1.014 1.014) (toColor (palette (Ore g)) 0.82)
          TerrainTarget c _ _ _ -> drawCubeWiresV (toRay (center c)) (Vector3 1.012 1.012 1.012) (Color 232 224 167 150)
          _ -> pure ()
  renderRadiance
    (resourceRadiance resources)
    chosen
    ws
    camera
    (sceneTime view)
    (sceneVeil view)
    grading
    (if maybe True photoVignette portrait then 0.10 else 0)
    shadow
    scene
  when (pulse > 0.04) $ drawRectangleGradientV 0 0 width height (Color 113 233 192 (round (pulse * 13))) (Color 243 223 148 0)
  forM_ [b | b <- sceneBursts view, burstCue b == Return] $ \b -> do
    let age = sceneTime view - fromIntegral (unTick (burstBorn b)) / 60
        opacity = max 0 (1 - age / 1.3)
    when (opacity > 0) $ drawRectangle 0 0 width height (Color 248 246 224 (round (255 * opacity * opacity)))
  forM_ [b | b <- sceneBursts view, burstCue b == Wound] $ \b -> do
    let age = sceneTime view - fromIntegral (unTick (burstBorn b)) / 60
        opacity = max 0 (1 - age / 0.42)
    when (opacity > 0) $
      drawRectangleGradientV
        0
        0
        width
        height
        (Color 190 34 65 (round (opacity * 110)))
        (Color 190 34 65 0)

drawKin :: Bool -> Resources -> SceneView -> IO ()
drawKin isShadow resources view = forM_ (sceneKin view) $ \(KinView pos gem bond safe) -> do
  let t = sceneTime view
      float = 0.12 * sin (t * 1.15 + fromIntegral (fromEnum gem))
      toward = minus (sceneEye view) pos
      V3 dx _ dz = toward
      yaw = atan2 (-dx) (-dz) * 180 / pi
  forM_ (M.findWithDefault [] gem (resourceKin resources)) $ \m -> drawPrepared m (plus pos (V3 0 (0.14 + float) 0)) yaw 0.13 white
  when (not isShadow) $ blendMode BlendAdditive $ forM_ [0 .. 11 :: Int] $ \i -> do
    let a = fromIntegral i * pi / 6 + t * 0.32
        radius = if safe then 1.4 else 0.85
        p = plus pos (V3 (cos a * radius) (1.4 + float + sin (a * 2) * 0.16) (sin a * radius))
        s = if bond > 0 then 0.065 else 0.035
    drawCubeV (toRay p) (Vector3 s s s) (toColor (palette (Ore gem)) (if safe then 0.8 else 0.45))

drawEnemies :: Bool -> Resources -> SceneView -> IO ()
drawEnemies isShadow resources view = forM_ (sceneEnemies view) $ \(EnemyView pos _ windup kind) -> do
  let V3 dx _ dz = minus (sceneEye view) pos
      yaw = atan2 (-dx) (-dz) * 180 / pi
      shake = if windup > 0 then sin (sceneTime view * 40) * 0.08 else 0
  forM_ (M.findWithDefault [] kind (resourceEnemy resources)) $ \m -> drawPrepared m (plus pos (V3 shake 0 0)) yaw 0.14 white
  when (not isShadow && windup > 0) $ blendMode BlendAdditive $ forM_ [0 .. 23 :: Int] $ \i -> do
    let a = fromIntegral i * pi / 12
        radius = case kind of Wanderer -> 2.9; Custodian -> 3.9; Skitter -> 2.4; SkyMoth -> 3.1
        alpha = 0.4 + 0.3 * sin (sceneTime view * 24)
    drawCubeV (toRay (plus pos (V3 (cos a * radius) 0.1 (sin a * radius)))) (Vector3 0.22 0.045 0.22) (Color 255 71 86 (round (alpha * 255)))

drawAtmosphere :: SceneView -> IO ()
drawAtmosphere view = blendMode BlendAdditive $ do
  -- A field of slowly rising pollen ties near space to the massive architecture.
  forM_ [0 .. 145 :: Int] $ \i -> do
    let t = sceneTime view
        fi = fromIntegral i
        x = fromIntegral ((i * 71) `mod` 103) - 51 + sin (t * 0.18 + fi) * 0.7
        z = fromIntegral ((i * 43) `mod` 122) - 40 + cos (t * 0.12 + fi) * 0.6
        y = 3 + fromIntegral (i `mod` 15) * 0.85 + sin (t * 0.25 + fi) * 0.6
        s = 0.025 + fromIntegral (i `mod` 3) * 0.019
        alpha = round (35 + 80 * (0.5 + 0.5 * sin (t + fi)))
    when (distance (sceneEye view) (V3 x y z) < 65) $
      drawCubeV (Vector3 x y z) (Vector3 s (s * 1.4) s) (Color 173 241 212 alpha)
  -- The return beacon is assembled from discrete, ascending gold fragments.
  forM_ [0 .. 54 :: Int] $ \i -> do
    let fi = fromIntegral i
        t = sceneTime view
        a = fi * 2.399 + t * 0.06
        y = 48 + fi * 0.45 + sin (t * 0.2 + fi) * 0.2
        r = 1.8 + fi * 0.04
    drawCubeV (Vector3 (cos a * r) y (54 + sin a * r)) (Vector3 0.12 0.46 0.12) (Color 255 219 141 (if sceneFlight view then 225 else 80))

drawBursts :: SceneView -> IO ()
drawBursts view = forM_ (sceneBursts view) $ \burst -> do
  let age = sceneTime view - fromIntegral (unTick (burstBorn burst)) / 60
      hue = case burstCue burst of Wound -> Color 255 83 103 210; Jewel -> Color 119 251 209 240; _ -> Color 255 223 147 230
  when (age >= 0 && age < 1.15) $ forM_ [0 .. 16 :: Int] $ \i -> do
    let fi = fromIntegral i
        a = fi * 2.399
        p = plus (burstOrigin burst) (V3 (cos a * age * 2.4) (age * (1.0 + fromIntegral (i `mod` 4)) - 2.4 * age * age) (sin a * age * 2.4))
        size = max 0.01 (0.12 * (1 - age / 1.15))
    drawCubeV (toRay p) (Vector3 size size size) hue

renderInterface :: Resources -> SceneView -> Bool -> Float -> IO ()
renderInterface resources view debug fps = withUIScale $ \width height zoom -> do
  settings <- readIORef (resourceQuality resources)
  let label = qualityPrefix <> qualityName (renderQuality settings)
  HUD.renderInterface (rayPainter resources (width, height) zoom (Just view)) label view debug fps

renderMenu :: Resources -> Maybe Bool -> Bool -> IO ()
renderMenu resources saved invertY = withUIScale $ \width height zoom ->
  HUD.renderMenu (rayPainter resources (width, height) zoom Nothing) resumeLabel saved invertY

qualityPrefix, resumeLabel :: String
#if defined(wasm32_HOST_ARCH)
qualityPrefix = ""
resumeLabel = "クリック  旅を続ける"
#else
qualityPrefix = "F4  "
resumeLabel = "ESC  旅を続ける"
#endif

renderSaveFeedback :: Resources -> Maybe Bool -> IO ()
renderSaveFeedback resources status = withUIScale $ \width height zoom ->
  HUD.renderSaveFeedback (rayPainter resources (width, height) zoom Nothing) status

renderPhotoFrame :: Photo -> IO ()
renderPhotoFrame photo = do
  width <- getScreenWidth
  height <- getScreenHeight
  HUD.renderPhotoFrame (rayShapePainter (width, height)) photo

renderPhotoChrome :: Resources -> Photo -> Maybe String -> IO ()
renderPhotoChrome resources photo message = withUIScale $ \width height zoom ->
  HUD.renderPhotoChrome (rayPainter resources (width, height) zoom Nothing) photo message

renderPhotoToast :: Resources -> String -> IO ()
renderPhotoToast resources line = withUIScale $ \width height zoom ->
  HUD.renderPhotoToast (rayPainter resources (width, height) zoom Nothing) line

rayPainter :: Resources -> (Int, Int) -> Float -> Maybe SceneView -> HUD.Painter
rayPainter resources extent zoom view =
  (rayShapePainter extent)
    { HUD.textAt = \label x y size tint -> textAt resources label x y size (rayColor tint)
    , HUD.textWidth = textWidth resources
    , HUD.projectPoint = \point -> case view of
        Nothing -> pure (0, 0)
        Just scene -> do
          Vector2 x y <- getWorldToScreen (toRay point) (cameraFor scene)
          pure (x / zoom, y / zoom)
    }

rayShapePainter :: (Int, Int) -> HUD.Painter
rayShapePainter extent = HUD.Painter
  { HUD.viewport = extent
  , HUD.drawRectangle = \x y width height tint -> drawRectangle x y width height (rayColor tint)
  , HUD.drawRectangleGradientV = \x y width height top bottom -> drawRectangleGradientV x y width height (rayColor top) (rayColor bottom)
  , HUD.drawLine = \x y x' y' tint -> drawLine x y x' y' (rayColor tint)
  , HUD.textAt = \_ _ _ _ _ -> pure ()
  , HUD.drawText = \label x y size tint -> drawText label x y size (rayColor tint)
  , HUD.textWidth = \_ _ -> pure 0
  , HUD.projectPoint = \_ -> pure (0, 0)
  }

rayColor :: HUD.Color -> Color
rayColor (HUD.Color r g b a) = Color (fromIntegral r) (fromIntegral g) (fromIntegral b) (fromIntegral a)

withUIScale :: (Int -> Int -> Float -> IO ()) -> IO ()
withUIScale action = do
  width <- getScreenWidth
  height <- getScreenHeight
  let zoom = max 0.85 (fromIntegral height / 900)
  mode2D
    (Camera2D (Vector2 0 0) (Vector2 0 0) 0 zoom)
    (action (round (fromIntegral width / zoom)) (round (fromIntegral height / zoom)) zoom)

white :: Color
white = Color 255 255 255 255
