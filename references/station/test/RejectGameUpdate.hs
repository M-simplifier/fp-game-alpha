module RejectGameUpdate where

import Station.Domain

forged :: GameState
forged = initialGame {stats = Stats 0 0 0}
