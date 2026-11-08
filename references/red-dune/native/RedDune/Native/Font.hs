module RedDune.Native.Font
  ( NativeFont,
    loadNativeFont,
    unloadNativeFont,
    drawNativeText,
    measureNativeText,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import GameIO.Graphics qualified as GPU
import GameIO.Text
import GameIO.Text.Atlas
import GameIO.Text.Render
import RedDune.Native.Canvas

data NativeFont = NativeFont !AtlasTexture !(Set.Set Char)

loadNativeFont :: GPU.Renderer -> BS.ByteString -> String -> IO NativeFont
loadNativeFont renderer bytes glyphs = do
  font <- result (decodeFontFace 0 bytes)
  size <- maybe (fail "invalid Red Dune font size") pure (pixelSize 48)
  let characters = Set.insert '?' (Set.fromList glyphs)
  atlas <- result (buildAtlas 1536 font size (Set.toList characters))
  texture <- createAtlasTexture renderer atlas
  pure (NativeFont texture characters)

unloadNativeFont :: GPU.Renderer -> NativeFont -> IO ()
unloadNativeFont renderer (NativeFont texture _) = destroyAtlasTexture renderer texture

drawNativeText :: NativeFont -> String -> Vector2 -> Float -> Float -> Color -> Drawing ()
drawNativeText font@(NativeFont texture _) label (Vector2 x y) size spacing color = do
  let (ascender, scale, tracking, caption) = style font label size spacing
      baseline = realToFrac y + ascender * scale
  (_, batch) <- liftIO (result (atlasTextBatch texture (realToFrac x) baseline scale tracking (renderColor color) caption))
  submitOverlay batch

measureNativeText :: NativeFont -> String -> Float -> Float -> Drawing Vector2
measureNativeText font@(NativeFont texture _) label size spacing = do
  let (_, scale, tracking, caption) = style font label size spacing
  run <- liftIO (result (atlasLine (textureAtlas texture) tracking caption))
  pure (Vector2 (realToFrac (runAdvance run * scale)) size)

style :: NativeFont -> String -> Float -> Float -> (Double, Double, Double, String)
style (NativeFont texture available) label size spacing =
  let (ascender, descender, _) = atlasLineMetrics (textureAtlas texture)
      scale = realToFrac size / max 1 (ascender - descender)
      tracking = realToFrac spacing / scale
      caption = map (\c -> if Set.member c available then c else '?') label
   in (ascender, scale, tracking, caption)

result :: (Show e) => Either e a -> IO a
result = either (ioError . userError . show) pure
