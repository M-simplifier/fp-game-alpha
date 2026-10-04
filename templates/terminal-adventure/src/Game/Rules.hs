-- | The authoritative rules. Inputs are whole turns; outputs describe feedback.
module Game.Rules (advance, adventureStep, smokeCommands) where

import Game.Model
import qualified Game.Model.Internal as Internal
import Game.Transition (Step (..))

adventureStep :: Step World Command [Event]
adventureStep = Step advance

advance :: Command -> World -> (World, [Event])
advance command world
  | isWon world = (world, [AlreadyFinished])
  | otherwise =
      let currentTurn = turnCount world
          next = world { Internal.worldTurn = Internal.Turn (currentTurn + 1) }
      in case command of
        Move direction -> resolveMovement direction next
        UseExit
          | coordinates (position next) == exitCell -> (next { Internal.worldProgress = Internal.Escaped }, [Won])
          | otherwise -> (next, [ExitUnavailable])

resolveMovement :: Direction -> World -> (World, [Event])
resolveMovement direction world =
  let (column, row) = coordinates (position world)
      (dx, dy) = case direction of
        North -> (0, -1)
        South -> (0, 1)
        East -> (1, 0)
        West -> (-1, 0)
      destination = (column + dx, row + dy)
      (nextColumn, nextRow) = destination
      inside = nextColumn >= 0 && nextColumn < worldWidth && nextRow >= 0 && nextRow < worldHeight
  in if inside
     then let nextPosition = Internal.Position (Internal.Column nextColumn) (Internal.Row nextRow)
          in (world { Internal.worldPosition = nextPosition }, [Moved nextPosition])
     else (world, [HitWall])

-- | A deterministic playthrough used by the runtime smoke check.
smokeCommands :: [Command]
smokeCommands = [Move East, Move East, Move South, UseExit]
