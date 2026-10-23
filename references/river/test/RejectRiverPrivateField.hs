module RejectRiverPrivateField where

import Life.Domain

forged :: Game
forged = initialGame {gDay = 99}
