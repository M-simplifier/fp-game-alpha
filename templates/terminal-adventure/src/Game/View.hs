-- | Pure presentation: rendering never repeats movement or exit rules.
module Game.View (render, renderEvent) where

import Game.Model

render :: World -> String
render world =
  unlines
    ( [concat [tile column row | column <- [0 .. worldWidth - 1]] | row <- [0 .. worldHeight - 1]]
        ++ ["Turn " ++ show (turnCount world), if isWon world then "Escaped!" else "Walk to E, then use exit."]
    )
  where
    tile column row
      | coordinates (position world) == (column, row) = "@ "
      | (column, row) == exitCell = "E "
      | otherwise = ". "

renderEvent :: Event -> String
renderEvent (Moved destination) = "Moved to " ++ show (coordinates destination)
renderEvent HitWall = "A wall blocks that move."
renderEvent ExitUnavailable = "The exit is not available here."
renderEvent Won = "You escaped."
renderEvent AlreadyFinished = "The game is complete. Start a new game to play again."
