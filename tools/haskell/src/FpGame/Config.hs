{-# LANGUAGE OverloadedStrings #-}

module FpGame.Config
  ( ProjectConfig,
    loadConfig,
    sourceDirectories,
    defaultExecutable,
    baselineDownloads,
  )
where

import Control.Monad (filterM, unless)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict', object, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as Bytes
import Data.Text (Text)
import Data.Text qualified as Text
import FpGame.Error
import FpGame.Path
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.Info qualified as Platform

-- No implicit reader/compiler configuration leaks into a game's build profile.
data ProjectConfig = ProjectConfig [FilePath] (Maybe Text) deriving (Eq, Show)

instance FromJSON ProjectConfig where
  parseJSON = withObject "fp-game.json" $ \fields -> do
    schema <- fields .:? "schema" .!= (1 :: Int)
    unless (schema == 1) (fail "Unsupported fp-game.json schema; expected 1.")
    ProjectConfig <$> fields .: "source_dirs" <*> fields .:? "default_executable"

loadConfig :: ProjectRoot -> IO ProjectConfig
loadConfig root = do
  let path = projectPath root </> "fp-game.json"
  exists <- doesFileExist path
  if exists
    then do
      requireUnlinked (projectPath root) path
      bytes <- Bytes.readFile path
      case eitherDecodeStrict' bytes of
        Left message -> failTool InvalidConfig ("Invalid fp-game.json: " ++ message)
        Right config -> pure config
    else pure (ProjectConfig foundationSources Nothing)
  where
    foundationSources =
      [ "libraries/game-transition/src",
        "libraries/game-arena/src",
        "references/lantern/src",
        "references/garden/src",
        "references/tapline/src",
        "references/river/src",
        "references/station/src",
        "src"
      ]

sourceDirectories :: ProjectRoot -> ProjectConfig -> IO [FilePath]
sourceDirectories root (ProjectConfig names _) = mapM (resolveIn root) names >>= filterM doesDirectoryExist

defaultExecutable :: ProjectConfig -> IO String
defaultExecutable (ProjectConfig _ executable) = case executable of
  Just name | validTarget name -> pure (Text.unpack name)
  _ -> failTool InvalidConfig "fp-game.json must declare a nonempty default_executable starting with a letter or digit and containing only letters, digits, hyphens or underscores."
  where
    validTarget name = case Text.uncons name of
      Just (first, _) -> asciiLetterOrDigit first && Text.all (\c -> asciiLetterOrDigit c || c `elem` ("-_" :: String)) name
      Nothing -> False
    asciiLetterOrDigit character = character `elem` (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'])

baselineDownloads :: ProjectRoot -> IO Value
baselineDownloads root = do
  let path = projectPath root </> "tools" </> "toolchains.json"
  exists <- doesFileExist path
  if not exists
    then pure (object [])
    else do
      bytes <- Bytes.readFile path
      case eitherDecodeStrict' bytes of
        Left message -> failTool InvalidConfig ("Invalid toolchains.json: " ++ message)
        Right value -> pure (profile value)
  where
    profile (Object fields) = case KeyMap.lookup "profiles" fields of
      Just (Object profiles) -> maybe (object []) id (KeyMap.lookup (Key.fromString profileName) profiles)
      _ -> object []
    profile _ = object []
    profileName = operatingSystem ++ "-" ++ architecture
    operatingSystem = case Platform.os of
      "mingw32" -> "Windows"
      "darwin" -> "Darwin"
      "linux" -> "Linux"
      other -> other
    architecture = case Platform.arch of
      "aarch64" -> "arm64"
      other -> other
