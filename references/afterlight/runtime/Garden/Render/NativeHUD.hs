module Garden.Render.NativeHUD
  ( withNativeHUD, recordHUD, drawLoading
  ) where

import Control.Monad (void, when)
import qualified Data.ByteString as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified GameIO.Graphics as GPU
import GameIO.Platform (Window, windowFramebufferSize)
import qualified GameIO.Text as Font
import qualified GameIO.Text.Atlas as Atlas
import GameIO.Text.Render
import Garden.Photo (photoBasis)
import qualified Garden.Render.HUD as HUD
import Garden.Render.Settings (qualityName)
import Garden.Types
import Garden.View (SceneView(..), uiCorpus)

withNativeHUD :: GPU.Renderer -> (AtlasTexture -> IO a) -> IO a
withNativeHUD renderer use = do
  characters <- readFile "assets/fonts/glyphs.txt"
  bytes <- BS.readFile "assets/fonts/NotoSansCJKjp-Regular.otf"
  font <- checked (Font.decodeFontFace 0 bytes)
  size <- maybe (fail "Invalid HUD font size") pure (Font.pixelSize 32)
  let corpus = [' ' .. '~'] <> "·°–↑↓" <> filter (>= ' ') (characters <> uiCorpus <> concatMap qualityName [minBound .. maxBound])
  atlas <- checked (Atlas.buildAtlas 1024 font size corpus)
  withAtlasTexture renderer atlas use

recordHUD :: (Int, Int) -> AtlasTexture -> Maybe SceneView -> (HUD.Painter -> HUD.Painter -> IO ()) -> IO [GPU.OverlayBatch]
recordHUD dimensions@(_, height) font scene paint = do
  output <- newIORef []
  let emit batch = modifyIORef' output (batch :)
      zoom = max 0.85 (fromIntegral height / 900)
  paint (painter emit dimensions 1 font scene) (painter emit dimensions zoom font scene)
  reverse <$> readIORef output

drawLoading :: Window -> GPU.Renderer -> AtlasTexture -> Maybe (Int, Int) -> IO ()
drawLoading window renderer font progress = do
  extent@(width, height) <- windowFramebufferSize window
  when (width > 0 && height > 0) $ do
    batches <- recordHUD extent font Nothing $ \_ painter' -> do
      HUD.textAt painter' "NOEMA / GARDEN OF AFTERLIGHT" 55 60 28 (HUD.Color 232 230 204 255)
      HUD.textAt painter' "Growing the voxel garden..." 57 113 20 (HUD.Color 171 210 192 255)
      case progress of
        Nothing -> pure ()
        Just (done, total) -> do
          HUD.drawRectangle painter' 57 153 300 3 (HUD.Color 37 67 66 255)
          HUD.drawRectangle painter' 57 153 (300 * done `div` max 1 total) 3 (HUD.Color 171 210 192 255)
    void (GPU.renderFrame renderer (GPU.Frame (GPU.Color 0.055 0.141 0.169 1) [] batches))

painter :: (GPU.OverlayBatch -> IO ()) -> (Int, Int) -> Float -> AtlasTexture -> Maybe SceneView -> HUD.Painter
painter emit (width, height) zoom font scene = HUD.Painter
  { HUD.viewport = (round (fromIntegral width / zoom), round (fromIntegral height / zoom))
  , HUD.drawRectangle = \x y w h color -> rectangle x y w h color color
  , HUD.drawRectangleGradientV = rectangle
  , HUD.drawLine = \x y x' y' color ->
      rectangle (min x x') (min y y') (abs (x' - x) + 1) (abs (y' - y) + 1) color color
  , HUD.textAt = text
  , HUD.drawText = \label x y size color -> text label (fromIntegral x) (fromIntegral y) (fromIntegral size) color
  , HUD.textWidth = \label size -> do
      let scale' = textScale size
      run <- checked (Atlas.atlasLine atlas (1 / scale') label)
      pure (realToFrac (Font.runAdvance run * scale'))
  , HUD.projectPoint = pure . project
  }
  where
    atlas = textureAtlas font
    (ascent, descent, _) = Atlas.atlasLineMetrics atlas
    textScale :: Float -> Double
    textScale size = realToFrac size / (ascent - descent)
    text :: String -> Float -> Float -> Float -> HUD.Color -> IO ()
    text label x y size color = do
      let scale' = textScale size
          magnify value = realToFrac (value * zoom)
      (_, batch) <- checked $ atlasTextBatch font (magnify x) (magnify y + ascent * scale' * realToFrac zoom)
        (scale' * realToFrac zoom) (1 / scale') (toColor color) label
      emit batch
    rectangle x y w h top bottom = when (w > 0 && h > 0) $ do
      let vertex a b color = GPU.Vertex (fromIntegral a * zoom) (fromIntegral b * zoom) 0 0 0 (toColor color)
          tl = vertex x y top
          tr = vertex (x + w) y top
          br = vertex (x + w) (y + h) bottom
          bl = vertex x (y + h) bottom
      emit (GPU.OverlayBatch Nothing [tl, tr, br, tl, br, bl])
    project point = case scene of
      Nothing -> (0, 0)
      Just view ->
        let forward' = unit (sceneForward view)
            (right, up) = photoBasis 0 forward'
            delta = minus point (sceneEye view)
            depth = dot delta forward'
            halfHeight = fromIntegral height / 2
            perspective = halfHeight / (tan (34 * pi / 180) * depth)
        in if depth <= 0 then (0, 0)
           else ((fromIntegral width / 2 + dot delta right * perspective) / zoom,
                 (halfHeight - dot delta up * perspective) / zoom)

toColor :: HUD.Color -> GPU.Color
toColor (HUD.Color r g b a) = GPU.Color (channel r) (channel g) (channel b) (channel a)
  where channel value = fromIntegral value / 255

checked :: Show e => Either e a -> IO a
checked = either (ioError . userError . show) pure
