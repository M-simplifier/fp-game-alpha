module Main (main) where

import RedDune.ContentPack
import RedDune.Host
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  store <- maybe ".red-dune-saves" id <$> lookupEnv "RED_DUNE_STORE"
  packPath <- lookupEnv "RED_DUNE_PACK"
  pack <- case packPath of Nothing -> pure defaultPack; Just path -> readFile path >>= either die pure . decodePack
  case args of
    [] -> runHost (HostConfig 8787 store "ui") pack
    ["--port", value] | Just port <- (readMaybe value :: Maybe Integer), port >= 1024, port <= 65535 -> runHost (HostConfig (fromInteger port) store "ui") pack
    _ -> die "Usage: red-dune-live [--port 8787]. Optional RED_DUNE_STORE and RED_DUNE_PACK. Run from references/red-dune-live."
