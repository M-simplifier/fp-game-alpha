{-# LANGUAGE OverloadedStrings #-}

-- | Cabal owns compiler selection and project-file parsing. Queries use the same
-- offline, project-local state as builds; they never install or select tools.
module FpGame.Cabal
  ( Compiler (..),
    parseCompiler,
    selectedCompiler,
    withCabal,
  )
where

import Control.Exception (IOException, bracket, catch)
import Control.Monad (when)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.ByteString qualified as Bytes
import Data.Char (isControl)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import FpGame.Error
import FpGame.Path
import FpGame.Process
import FpGame.Result
import System.Directory (createDirectory, removeDirectory, renameFile)
import System.FilePath (isAbsolute, normalise, pathSeparator, (</>))
import System.IO (hClose, hSetBinaryMode)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempDirectory, withTempFile)

data Compiler = Compiler
  { compilerExecutable :: FilePath,
    compilerIdentifier :: String
  }
  deriving (Eq, Show)

instance FromJSON Compiler where
  parseJSON = withObject "Cabal path result" $ \result -> do
    compiler <- result .: "compiler"
    withObject
      "Cabal compiler"
      ( \fields -> do
          flavour <- fields .: "flavour"
          when (flavour /= ("ghc" :: String)) (fail "The selected compiler is not GHC.")
          Compiler <$> fields .: "path" <*> fields .: "id"
      )
      compiler

parseCompiler :: Text.Text -> Either String Compiler
parseCompiler output = do
  compiler <- eitherDecodeStrict' (Text.encodeUtf8 output)
  let path = compilerExecutable compiler
  if null path || any isControl path || null (compilerIdentifier compiler)
    then Left "Cabal returned an empty or invalid compiler path/identifier."
    else Right compiler

selectedCompiler :: ProjectRoot -> IO Compiler
selectedCompiler root = do
  cabal <- requireTool "cabal"
  withQueryCache root $ \state -> do
    let config = state </> "cabal.config"
        command =
          [ "--config-file=" ++ config,
            "path",
            "--offline",
            "--builddir=" ++ state </> "dist",
            "--output-format=json",
            "--verbose=0"
          ]
    Bytes.writeFile config (Text.encodeUtf8 (Text.pack (configuration state)))
    result <- execute root (ProcessRequest cabal command (Just 20) Captured)
    case result of
      Executed _ 0 output _ -> case parseCompiler output of
        Left problem -> failTool InvalidConfig ("Invalid Cabal compiler query: " ++ problem)
        Right compiler ->
          -- Preserve wrapper identity, including relative project invocations.
          pure compiler {compilerExecutable = resolve (compilerExecutable compiler)}
      Executed provenance code output errors ->
        failTool InvalidConfig $
          "Cabal compiler selection failed (exit "
            ++ show code
            ++ "). No PATH fallback.\n"
            ++ show provenance
            ++ "\n"
            ++ Text.unpack errors
            ++ Text.unpack output
      _ -> failTool ToolIO "Cabal compiler selection returned an unexpected result."
  where
    resolve path = if isAbsolute path then path else normalise (projectPath root </> path)

-- Cabal's query writes cache files. Scope them to a uniquely owned directory in
-- the project and clean it on success/failure. Remove a .build directory we
-- created only if still empty; never remove existing or concurrently added data.
withQueryCache :: ProjectRoot -> (FilePath -> IO a) -> IO a
withQueryCache root action = do
  let state = projectPath root </> ".build"
  requireUnlinked (projectPath root) state
  bracket (reserve state) (release state) $ \_ ->
    withTempDirectory state "compiler-query-" action
  where
    reserve state = (createDirectory state >> pure True) `catch` exists
    exists :: IOException -> IO Bool
    exists problem
      | isAlreadyExistsError problem = pure False
      | otherwise = ioError problem
    release state owned = when owned (removeDirectory state `catch` keepState)
    keepState :: IOException -> IO ()
    keepState _ = pure ()

withCabal :: ProjectRoot -> String -> [String] -> (FilePath -> [String] -> IO a) -> IO a
withCabal root action targets run = do
  executable <- requireTool "cabal"
  state <- buildState root
  let config = state </> "cabal.config"
  requireUnlinked (projectPath root) config
  -- Replace the entry, never truncate a possibly hard-linked existing inode.
  withTempFile state "cabal-config-" $ \temporary handle -> do
    hSetBinaryMode handle True
    Bytes.hPut handle (Text.encodeUtf8 (Text.pack (configuration state)))
    hClose handle
    requireUnlinked (projectPath root) config
    renameFile temporary config
  run executable (["--config-file=" ++ config, action] ++ targets ++ ["--offline", "--builddir=" ++ state </> "dist"])

configuration :: FilePath -> String
configuration state =
  "active-repositories: :none\nstore-dir: "
    ++ portable (state </> "store")
    ++ "\nremote-repo-cache: "
    ++ portable (state </> "package-cache")
    ++ "\nlogs-dir: "
    ++ portable (state </> "logs")
    ++ "\n"
  where
    portable = map (\character -> if pathSeparator == '\\' && character == '\\' then '/' else character)
