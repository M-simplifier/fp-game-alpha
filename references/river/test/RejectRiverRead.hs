module RejectRiverRead where

import Life.Domain
import Text.Read (readMaybe)

forged :: Maybe Game
forged = readMaybe "Game {}"
