{-# LANGUAGE OverloadedStrings #-}

-- | Prepare the optional terminal example from an explicit foundation source,
-- then publish it without replacing existing user files.
module FpGame.Create
  ( CreateOptions (..),
    planProject,
    createProject,
  )
where

import Control.Exception (IOException, catch, throwIO)
import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import FpGame.Create.Distribution
  ( Distribution,
    distributionDownloads,
    distributionFiles,
    distributionLicense,
    fileHashes,
    prerequisites,
    renderDistribution,
    renderSources,
    selectedSources,
    templateName,
  )
import FpGame.Create.Filesystem
  ( SourceSnapshot,
    checkedDestination,
    checkedSourceRoot,
    publishFiles,
    readSelection,
    snapshotFiles,
    verifySnapshot,
  )
import FpGame.Create.Options (CreateOptions (..), validateOptions)
import FpGame.Error (ErrorCode (..), failTool)
import FpGame.Path (selectProject)
import FpGame.Process (Capture (Captured), ProcessRequest (..), execute)
import FpGame.Result (Result (..))
import System.Directory (canonicalizePath, doesDirectoryExist, findExecutable)
import System.FilePath (equalFilePath, (</>))

data PreparedProject = PreparedProject
  { preparedDestination :: FilePath,
    preparedSnapshot :: SourceSnapshot,
    preparedDistribution :: Distribution
  }

-- | Read and validate the complete distribution without creating directories.
planProject :: FilePath -> CreateOptions -> IO Value
planProject source options = do
  prepared <- prepareProject source options
  pure $
    object
      [ "status" .= ("planned" :: String),
        "exit_code" .= (0 :: Int),
        "destination" .= preparedDestination prepared,
        "template" .= templateName,
        "target" .= ("native" :: String),
        "rendering" .= ("terminal" :: String),
        "game_license" .= distributionLicense (preparedDistribution prepared),
        "files" .= fileHashes (distributionFiles (preparedDistribution prepared)),
        "baseline_downloads" .= distributionDownloads (preparedDistribution prepared),
        "prerequisites" .= prerequisites,
        "mutates" .= False,
        "next" .= ("create, then build/test/run and implement the agreed game mechanic" :: String)
      ]

-- | Reserve a previously nonexistent root and create every file exclusively.
-- Failure may leave a partial directory and an incomplete marker; no failed
-- creation is automatically deleted or regenerated over. The marker is useful
-- recovery information, not a claim of crash consistency or disk durability.
createProject :: FilePath -> CreateOptions -> IO Value
createProject source options = do
  prepared <- prepareProject source options
  verifySnapshot (preparedSnapshot prepared)
  let destination = preparedDestination prepared
  publishFiles destination (distributionFiles (preparedDistribution prepared))
  pure $
    object
      [ "status" .= ("created" :: String),
        "exit_code" .= (0 :: Int),
        "destination" .= destination,
        "files" .= Map.size (distributionFiles (preparedDistribution prepared)),
        "next" .= ("Enter the game directory; build/test/play, then continue with $game-dev." :: String)
      ]

prepareProject :: FilePath -> CreateOptions -> IO PreparedProject
prepareProject source options = do
  validated <- either throwIO pure (validateOptions options)
  sourceRoot <- checkedSourceRoot source
  destination <- checkedDestination sourceRoot (createDestination options)
  templateExists <- doesDirectoryExist (sourceRoot </> "templates" </> templateName)
  unless templateExists $
    failTool InvalidProject "This game already owns its editable source. Continue development here; the optional template is available only in the foundation checkout."
  snapshot <- readSelection sourceRoot selectedSources
  rendered <- either throwIO pure (renderSources validated (snapshotFiles snapshot))
  provenance <- sourceProvenance sourceRoot
  distribution <- either throwIO pure (renderDistribution rendered provenance)
  pure (PreparedProject destination snapshot distribution)

-- A relocated source snapshot inside an unrelated Git repository must not
-- accidentally record that parent's commit as its own upstream revision.
sourceProvenance :: FilePath -> IO (Maybe String, Maybe String)
sourceProvenance root = probe `catch` unavailable
  where
    probe = do
      reported <- gitOutput root ["rev-parse", "--show-toplevel"]
      metadataRoot <- traverse canonicalizePath reported
      if maybe False (equalFilePath root) metadataRoot
        then do
          revision <- gitOutput root ["rev-parse", "HEAD"]
          state <- gitOutput root ["status", "--porcelain"]
          pure (revision, state)
        else pure (Nothing, Nothing)
    unavailable :: IOException -> IO (Maybe String, Maybe String)
    unavailable _ = pure (Nothing, Nothing)

gitOutput :: FilePath -> [String] -> IO (Maybe String)
gitOutput root arguments = do
  executable <- findExecutable "git"
  case executable of
    Nothing -> pure Nothing
    Just git -> do
      project <- selectProject (Just root)
      let flags = ["--no-optional-locks", "-c", "safe.directory=" <> root, "-c", "core.fsmonitor=false"]
      result <- execute project (ProcessRequest git (flags <> arguments) (Just 20) Captured)
      pure $ case result of
        Executed _ 0 output _ -> Just (Text.unpack (Text.strip output))
        _ -> Nothing
