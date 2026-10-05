{-# LANGUAGE OverloadedStrings #-}

-- | The IO shell dispatches already-parsed operations. The tool package never
-- joins the game's dependency graph and does not install or select a compiler.
module FpGame.Command (runCommand) where

import Control.Monad (forM, when)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as Bytes
import Data.Maybe (fromMaybe, isJust)
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import FpGame.CLI
import FpGame.Config
import FpGame.Create
import FpGame.Error
import FpGame.Path
import FpGame.Process
import FpGame.Result
import System.Directory (findExecutable, getCurrentDirectory, renameFile)
import System.FilePath (pathSeparator, (</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Temp (withTempDirectory, withTempFile)
import System.Info qualified as Platform

runCommand :: Options -> IO Result
runCommand options = do
  root <- selectProject (selectedProject options)
  let executeHere executable arguments capture =
        let deadline = case capture of
              Captured -> Just (fromMaybe 180 (timeoutSeconds options))
              Interactive -> timeoutSeconds options
         in execute root (ProcessRequest executable arguments deadline capture)
      cabal action targets extra capture = withCabal root action targets $ \executable arguments -> executeHere executable (arguments ++ extra) capture
  case selectedCommand options of
    Doctor -> doctor root
    Build -> cabal "build" ["all"] [] Captured
    Test -> cabal "test" ["all"] ["--test-show-details=direct"] Captured
    Check Nothing -> cabal "build" ["all"] [] Captured
    Check (Just filename) -> do
      source <- checkedSource root filename
      config <- loadConfig root
      directories <- sourceDirectories root config
      ghc <- requireTool "ghc"
      state <- buildState root
      withTempDirectory state "check-" $ \output ->
        executeHere
          ghc
          ( ["-fno-code", "-fforce-recomp", "-XGHC2021", "-Wall", "-fdiagnostics-color=never", "-outputdir", output]
              ++ map ("-i" ++) directories
              ++ [source]
          )
          Captured
    Run smoke -> do
      when (not smoke && isJust (timeoutSeconds options)) $
        failTool InvalidArguments "Use run --smoke with --timeout for bounded execution. Interactive run follows Cabal's terminal lifetime."
      when (jsonOutput options && not smoke) (failTool InvalidArguments "Interactive run uses the terminal; use --smoke for captured JSON.")
      config <- loadConfig root
      target <- defaultExecutable config
      cabal "run" [target] (if smoke then ["--", "--smoke"] else []) (if smoke then Captured else Interactive)
    Plan createOptions -> do
      source <- maybe getCurrentDirectory pure (selectedProject options)
      Report 0 <$> planProject source createOptions
    Create createOptions -> do
      source <- maybe getCurrentDirectory pure (selectedProject options)
      Report 0 <$> createProject source createOptions

withCabal :: ProjectRoot -> String -> [String] -> (FilePath -> [String] -> IO a) -> IO a
withCabal root action targets run = do
  executable <- requireTool "cabal"
  state <- buildState root
  let config = state </> "cabal.config"
  requireUnlinked (projectPath root) config
  -- Replace the directory entry instead of truncating an existing inode: even a
  -- hard-linked config must not write through to somebody else's file.
  withTempFile state "cabal-config-" $ \temporary handle -> do
    hSetBinaryMode handle True
    Bytes.hPut handle (Text.encodeUtf8 (Text.pack (configuration state)))
    hClose handle
    requireUnlinked (projectPath root) config
    renameFile temporary config
  run executable (["--config-file=" ++ config, action] ++ targets ++ ["--offline", "--builddir=" ++ state </> "dist"])
  where
    configuration state =
      "active-repositories: :none\nstore-dir: "
        ++ portable (state </> "store")
        ++ "\nremote-repo-cache: "
        ++ portable (state </> "package-cache")
        ++ "\n"
    portable = map (\character -> if pathSeparator == '\\' && character == '\\' then '/' else character)

doctor :: ProjectRoot -> IO Result
doctor root = do
  observations <- forM [("ghc", "9.6.7"), ("cabal", "3.12.1.0")] $ \(name, baseline) -> do
    executable <- findExecutable name
    version <- case executable of
      Nothing -> pure Nothing
      Just path -> do
        result <- execute root (ProcessRequest path ["--numeric-version"] (Just 20) Captured)
        pure $ case result of
          Executed _ 0 output _ | not (Text.null (Text.strip output)) -> Just (Text.strip output)
          _ -> Nothing
    let value = object ["path" .= executable, "version" .= version, "tested_version" .= (baseline :: Text.Text), "matches_baseline" .= (version == Just baseline)]
    pure (name, version, value)
  hls <- findExecutable "haskell-language-server-wrapper"
  vscode <- findExecutable "code"
  neovim <- findExecutable "nvim"
  downloads <- baselineDownloads root
  let missing = [name | (name, Nothing, _) <- observations]
      code = if null missing then 0 else 1
      values = object [fromStringKey name .= value | (name, _, value) <- observations]
  pure
    $ Report code
    $ object
      [ "status" .= (if null missing then "ready-to-try" else "missing-tools" :: Text.Text),
        "exit_code" .= code,
        "os" .= osName,
        "architecture" .= Platform.arch,
        "implementation" .= ("haskell" :: Text.Text),
        "tools" .= values,
        "optional_hls" .= hls,
        "editors" .= object ["vscode" .= vscode, "neovim" .= neovim],
        "baseline_downloads" .= downloads,
        "missing" .= missing,
        "setup" .= ("https://www.haskell.org/ghcup/install/" :: Text.Text),
        "scope" .= ("Detects tools; build/test establishes this project. Tool installation remains explicit." :: Text.Text)
      ]
  where
    fromStringKey = fromString
    osName = case Platform.os of
      "mingw32" -> "Windows"
      "darwin" -> "Darwin"
      "linux" -> "Linux"
      other -> other
