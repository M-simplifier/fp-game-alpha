module Tapline.Input (Key (..), Command (..), commandsFromChars, keyLabel) where

import Data.Maybe (mapMaybe)

data Key = J | K deriving (Eq, Ord, Show)

data Command = Tap Key | TogglePause | Reset deriving (Eq, Show)

-- Stable map/filter: neither deduplication nor sorting is valid here.
commandsFromChars :: [Char] -> [Command]
commandsFromChars = mapMaybe command
  where
    command 'j' = Just (Tap J)
    command 'k' = Just (Tap K)
    command ' ' = Just TogglePause
    command 'r' = Just Reset
    command _ = Nothing

keyLabel :: Key -> String
keyLabel J = "J"
keyLabel K = "K"
