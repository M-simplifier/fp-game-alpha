{-# LANGUAGE PatternSynonyms #-}

module PureFall.Host.Font (Fonts, withFonts, text, textWidth, Face (..)) where

import Control.Exception (bracket, mask, onException)
import Control.Monad (filterM)
import Foreign (Ptr, castPtr, nullPtr, peek, with)
import Foreign.C (withCString)
import Raylib.Core.Text qualified as Text
import Raylib.Core.Textures (setTextureFilter)
import Raylib.Internal.Foreign (c'free, pop)
import Raylib.Types
import System.Directory (doesFileExist)

data Face = Display | Body | Mono deriving (Eq, Show)

data NativeFont = NativeFont (Ptr Font) Bool

data Fonts = Fonts NativeFont NativeFont NativeFont

withFonts :: (Fonts -> IO a) -> IO a
withFonts action = bracket (load displayFaces) unload $ \display ->
  bracket (load bodyFaces) unload $ \body ->
    bracket (load monoFaces) unload $ \mono -> action (Fonts display body mono)
  where
    displayFaces = ["C:/Windows/Fonts/bahnschrift.ttf", "C:/Windows/Fonts/segoeuib.ttf", "C:/Windows/Fonts/arialbd.ttf"]
    bodyFaces = ["C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"]
    monoFaces = ["C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/lucon.ttf"]

load :: [FilePath] -> IO NativeFont
load candidates = mask $ \_ -> do
  fallback <- Text.c'getFontDefault
  let useFallback = pure (NativeFont fallback False)
  ( do
      found <- filterM doesFileExist candidates
      case found of
        [] -> useFallback
        path : _ -> do
          loaded <- withCString path $ \name -> Text.c'loadFontEx name 96 nullPtr 0
          if loaded == nullPtr
            then useFallback
            else do
              valid <- Text.c'isFontValid loaded
              texture <- peek (p'font'texture loaded)
              defaultTexture <- peek (p'font'texture fallback)
              if valid == 0 || texture'id texture == texture'id defaultTexture
                then c'free (castPtr loaded) >> useFallback
                else do
                  let owned = NativeFont loaded True
                  prepared <- (setTextureFilter texture TextureFilterBilinear >> pure owned) `onException` unload owned
                  c'free (castPtr fallback)
                  pure prepared
    )
    `onException` c'free (castPtr fallback)

unload :: NativeFont -> IO ()
unload (NativeFont pointer owned) = do
  if owned then Text.c'unloadFont pointer else pure ()
  c'free (castPtr pointer)

select :: Fonts -> Face -> NativeFont
select (Fonts display body mono) face = case face of Display -> display; Body -> body; Mono -> mono

text :: Fonts -> Face -> String -> Vector2 -> Float -> Color -> IO ()
text fonts face label position size tint = case select fonts face of
  NativeFont pointer _ -> withCString label $ \characters -> with position $ \location -> with tint $ \color ->
    Text.c'drawTextEx pointer characters location (realToFrac size) (realToFrac (size * 0.022)) color

textWidth :: Fonts -> Face -> String -> Float -> IO Float
textWidth fonts face label size = case select fonts face of
  NativeFont pointer _ -> withCString label $ \characters -> do
    Vector2 width _ <- Text.c'measureTextEx pointer characters (realToFrac size) (realToFrac (size * 0.022)) >>= pop
    pure width
