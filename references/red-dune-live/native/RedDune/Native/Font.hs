-- raylib's TrueType reader expects one face at offset zero. Windows Japanese
-- fonts are collections. Rebase their first face in memory; no system font is
-- copied to the package or modified on disk.
module RedDune.Native.Font (NativeFont, fontFace, loadNativeFont, unloadNativeFont, drawNativeText, measureNativeText) where

import Control.Exception (onException)
import Control.Monad (forM, unless)
import Data.ByteString qualified as BS
import Data.List (mapAccumL)
import Data.Word (Word8)
import Foreign (Ptr, castPtr, nullPtr, peek, with, withArrayLen)
import Foreign.C (CInt, withCString)
import Raylib.Core.Text (c'drawTextEx, c'isFontValid, c'loadFontFromMemory, c'measureTextEx, c'unloadFont)
import Raylib.Core.Textures (setTextureFilter)
import Raylib.Internal.Foreign (c'free, pop)
import Raylib.Types (Color, Font, TextureFilter (TextureFilterBilinear), Vector2)
import Raylib.Types.Core.Text (p'font'glyphCount, p'font'texture)

-- A font owns native glyphs and a GPU atlas for the window's lifetime. Borrow
-- it for every draw instead of serializing hundreds of glyph images per label.
newtype NativeFont = NativeFont (Ptr Font)

-- Keep the binary font in one bounded buffer, rather than converting its
-- millions of bytes to boxed Integers through the high-level convenience API.
loadNativeFont :: BS.ByteString -> [Int] -> IO NativeFont
loadNativeFont bytes glyphs = BS.useAsCStringLen bytes $ \(pointer, size) ->
  withCString ".ttf" $ \kind -> withArrayLen (map fromIntegral glyphs :: [CInt]) $ \count codes -> do
    loaded <- c'loadFontFromMemory kind (castPtr pointer) (fromIntegral size) 48 codes (fromIntegral count)
    unless (loaded /= nullPtr) (ioError (userError "The system Japanese font could not be allocated"))
    let font = NativeFont loaded
    ( do
        valid <- c'isFontValid loaded
        actual <- peek (p'font'glyphCount loaded)
        unless (valid /= 0 && actual == fromIntegral count) (ioError (userError "The system Japanese font could not be loaded"))
        texture <- peek (p'font'texture loaded)
        _ <- setTextureFilter texture TextureFilterBilinear
        pure font
      )
      `onException` unloadNativeFont font

unloadNativeFont :: NativeFont -> IO ()
unloadNativeFont (NativeFont pointer) = c'unloadFont pointer >> c'free (castPtr pointer)

drawNativeText :: NativeFont -> String -> Vector2 -> Float -> Float -> Color -> IO ()
drawNativeText (NativeFont font) label position size spacing color =
  withCString label $ \text -> with position $ \point -> with color $ \tint ->
    c'drawTextEx font text point (realToFrac size) (realToFrac spacing) tint

measureNativeText :: NativeFont -> String -> Float -> Float -> IO Vector2
measureNativeText (NativeFont font) label size spacing = withCString label $ \text ->
  c'measureTextEx font text (realToFrac size) (realToFrac spacing) >>= pop

fontFace :: BS.ByteString -> Either String BS.ByteString
fontFace bytes
  | BS.take 4 bytes /= BS.pack [116, 116, 99, 102] = Right bytes
  | otherwise = do
      offset <- number 12 4
      count <- number (offset + 4) 2
      unless (count > 0 && count <= 256 && offset + 12 + 16 * count <= BS.length bytes) (Left "Invalid system font collection directory")
      let headerSize = 12 + 16 * count
      tables <- forM [0 .. count - 1] $ \index -> do
        let position = offset + 12 + 16 * index
        source <- number (position + 8) 4
        size <- number (position + 12) 4
        unless (source + size <= BS.length bytes) (Left "Invalid system font table")
        let padding = (4 - size `mod` 4) `mod` 4
        pure (BS.take 8 (BS.drop position bytes), size, BS.take size (BS.drop source bytes) <> BS.replicate padding 0)
      let (_, rebased) =
            mapAccumL
              ( \cursor (record, size, payload) ->
                  (cursor + BS.length payload, (record <> word cursor <> word size, payload))
              )
              headerSize
              tables
      pure (BS.take 12 (BS.drop offset bytes) <> BS.concat (map fst rebased) <> BS.concat (map snd rebased))
  where
    number position size = do
      unless (position >= 0 && position + size <= BS.length bytes) (Left "Truncated system font collection")
      pure (BS.foldl' (\total byte -> total * 256 + fromIntegral byte) 0 (BS.take size (BS.drop position bytes)))
    word :: Int -> BS.ByteString
    word value = BS.pack [fromIntegral (value `div` factor `mod` 256) :: Word8 | factor <- [16777216, 65536, 256, 1]]
