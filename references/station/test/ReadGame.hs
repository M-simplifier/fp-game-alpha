module ReadGame where

import Station.Domain

resources :: Stats
resources = stats initialGame

visibleTurn :: Maybe TurnId
visibleTurn = currentTurn initialGame
