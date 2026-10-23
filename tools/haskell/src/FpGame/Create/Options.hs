{-# LANGUAGE OverloadedStrings #-}

module FpGame.Create.Options
  ( CreateOptions (..),
    ValidOptions,
    GameLicense (..),
    validateOptions,
    gameSlug,
    gameTitle,
    gameLicense,
    licenseName,
    licenseDescription,
    windowsDeviceName,
  )
where

import Control.Monad (forM_, unless, when)
import Data.Char (isControl, toLower)
import Data.Text qualified as Text
import FpGame.Error (ErrorCode (..), ToolError (..))

-- | Raw CLI input. It is validated once into the private template and license
-- choices before any source is read or any directory is created.
data CreateOptions = CreateOptions
  { createSlug :: String,
    createDestination :: FilePath,
    createTitle :: Maybe String,
    createTarget :: String,
    createRendering :: String,
    createLicense :: String,
    createAuthor :: Maybe String
  }
  deriving (Eq, Show)

data GameLicense = Unlicensed | MIT String

data ValidOptions = ValidOptions
  { validatedSlug :: String,
    validatedTitle :: String,
    validatedLicense :: GameLicense
  }

gameSlug :: ValidOptions -> String
gameSlug = validatedSlug

gameTitle :: ValidOptions -> String
gameTitle = validatedTitle

gameLicense :: ValidOptions -> GameLicense
gameLicense = validatedLicense

validateOptions :: CreateOptions -> Either ToolError ValidOptions
validateOptions options = do
  let slug = createSlug options
      parts = Text.splitOn "-" (Text.pack slug)
      lowerAscii c = c >= 'a' && c <= 'z'
      digit c = c >= '0' && c <= '9'
      validPart part = not (Text.null part) && Text.all (\c -> lowerAscii c || digit c) part && Text.any lowerAscii part
      validStart = case slug of
        c : _ -> lowerAscii c
        [] -> False
      title = case createTitle options of
        Nothing -> slug
        Just "" -> slug
        Just value -> value
  unless (validStart && length slug <= 64 && all validPart parts && slug `notElem` ["base", "game-transition", "game-arena"]) $
    invalid InvalidArguments "Use a lowercase Cabal slug, such as my-adventure."
  when (windowsDeviceName slug) $
    invalid InvalidArguments "Choose a portable Cabal slug; Windows device names such as con, nul, com1 and lpt1 cannot be game names."
  validateLine "Title" title
  unless (createTarget options == "native" && createRendering options == "terminal") $
    invalid UnsupportedRoute "This optional example implements native/terminal only. Author a separate game and host for another brief; no substitute template is generated."
  license <- case createLicense options of
    "unlicensed" -> pure Unlicensed
    "MIT" -> case createAuthor options of
      Just author | not (null author) -> pure (MIT author)
      _ -> invalid InvalidArguments "An MIT game license needs an explicit author/credit name."
    _ -> invalid InvalidArguments "Game license must be unlicensed or MIT."
  forM_ (createAuthor options) (validateLine "Author")
  pure ValidOptions {validatedSlug = slug, validatedTitle = title, validatedLicense = license}

validateLine :: String -> String -> Either ToolError ()
validateLine label value =
  when (length value > 120 || any isControl value) $
    invalid InvalidArguments (label <> " must be one line of at most 120 characters.")

invalid :: ErrorCode -> String -> Either ToolError a
invalid code = Left . ToolError code . Text.pack

windowsDeviceName :: String -> Bool
windowsDeviceName name =
  map toLower name `elem` (["con", "prn", "aux", "nul"] <> [prefix <> show number | prefix <- ["com", "lpt"], number <- [1 :: Int .. 9]])

licenseName :: GameLicense -> String
licenseName Unlicensed = "unlicensed"
licenseName (MIT _) = "MIT"

licenseDescription :: GameLicense -> String
licenseDescription Unlicensed = "not chosen; no license granted for your additions"
licenseDescription (MIT _) = "MIT"
