module FpGame.CLI
  ( Command (..),
    Options (..),
    parseOptions,
    usage,
  )
where

import Control.Monad (unless)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import FpGame.Create (CreateOptions (..))
import Text.Read (readMaybe)

data Command
  = Doctor
  | Build
  | Test
  | Check (Maybe FilePath)
  | Run Bool
  | Plan CreateOptions
  | Create CreateOptions
  deriving (Show)

data Options = Options
  { selectedCommand :: Command,
    selectedProject :: Maybe FilePath,
    jsonOutput :: Bool,
    timeoutSeconds :: Maybe Int
  }
  deriving (Show)

usage :: String
usage =
  unlines
    [ "Usage: fp-game COMMAND [OPTIONS]",
      "  doctor                       Observe installed tools; never installs",
      "  build | test                 Offline isolated Cabal build/test",
      "  check [FILE.hs]              Build all, or check one saved source",
      "  run [--smoke]                Run the configured game",
      "  plan NAME DEST               Plan an optional independent starter",
      "  create NAME DEST [--dry-run]  Create once; never regenerate existing work",
      "Common: --project DIR --json",
      "Captured commands: --timeout SECONDS (1..86400, default 180)",
      "For run, --timeout requires --smoke; interactive run uses the terminal.",
      "Create: --title TITLE --target native --rendering terminal",
      "        --license unlicensed|MIT --author NAME",
      "Aliases: create-plan = plan; scaffold = create",
      "The project defaults to the current directory. For plan/create it is the",
      "foundation source root; DEST is the independent new game directory.",
      "Other game briefs and hosts are authored from their own requirements.",
      "inspect/context and durable AI play remain available in the legacy tools."
    ]

parseOptions :: [String] -> Either String Options
parseOptions (action : arguments) = do
  unless (action `elem` commands) (Left ("Unknown command: " ++ action))
  (values, flags, positional) <- collect Map.empty Set.empty [] arguments
  let value = (`Map.lookup` values)
      flag = (`Set.member` flags)
      creation = action `elem` ["plan", "create-plan", "create", "scaffold"]
      allowedValues = ["--project", "--timeout"] ++ if creation then createValues else []
      allowedFlags = ["--json"] ++ ["--smoke" | action == "run"] ++ ["--dry-run" | action `elem` ["create", "scaffold"]]
  unless (all (`elem` allowedValues) (Map.keys values) && all (`elem` allowedFlags) (Set.toList flags)) $
    Left "An option does not apply to this command."
  seconds <- case value "--timeout" of
    Nothing -> Right Nothing
    Just raw -> case readMaybe raw :: Maybe Integer of
      Just number | number >= 1 && number <= 86400 -> Right (Just (fromInteger number))
      _ -> Left "--timeout must be an integer from 1 to 86400."
  command <- case (action, positional) of
    ("doctor", []) -> Right Doctor
    ("build", []) -> Right Build
    ("test", []) -> Right Test
    ("check", []) -> Right (Check Nothing)
    ("check", [file]) -> Right (Check (Just file))
    ("run", []) -> Right (Run (flag "--smoke"))
    (_, [name, destination]) | creation -> do
      let createOptions =
            CreateOptions
              { createSlug = name,
                createDestination = destination,
                createTitle = value "--title",
                createTarget = maybe "native" id (value "--target"),
                createRendering = maybe "terminal" id (value "--rendering"),
                createLicense = maybe "unlicensed" id (value "--license"),
                createAuthor = value "--author"
              }
      unless (createTarget createOptions `elem` ["native", "web", "server", "mobile"]) $
        Left "--target must be native, web, server or mobile."
      unless (createRendering createOptions `elem` ["terminal", "2d", "3d", "miso"]) $
        Left "--rendering must be terminal, 2d, 3d or miso."
      unless (createLicense createOptions `elem` ["unlicensed", "MIT"]) $
        Left "--license must be unlicensed or MIT."
      Right (if action `elem` ["plan", "create-plan"] || flag "--dry-run" then Plan createOptions else Create createOptions)
    _ -> Left "Incorrect positional arguments."
  Right (Options command (value "--project") (flag "--json") seconds)
  where
    commands = ["doctor", "build", "test", "check", "run", "plan", "create-plan", "create", "scaffold"]
    createValues = ["--title", "--target", "--rendering", "--license", "--author"]
    valueNames = ["--project", "--timeout"] ++ createValues
    flagNames = ["--json", "--smoke", "--dry-run"]
    collect values flags positional [] = Right (values, flags, reverse positional)
    collect values flags positional ("--" : rest) = Right (values, flags, reverse positional ++ rest)
    collect values flags positional (name : rest)
      | name `elem` valueNames = case rest of
          value : remaining | not (Map.member name values) -> collect (Map.insert name value values) flags positional remaining
          _ -> Left ("Missing value or repeated option: " ++ name)
      | name `elem` flagNames =
          if Set.member name flags
            then Left ("Repeated option: " ++ name)
            else collect values (Set.insert name flags) positional rest
      | "-" `isPrefixOf` name = Left ("Unknown option: " ++ name)
      | otherwise = collect values flags (name : positional) rest
parseOptions [] = Left "Choose a command."
