module ReadRiver where

import Life.Domain

visibleDay :: Int
visibleDay = dayNumber initialGame

visiblePosition :: (Int, Int)
visiblePosition = playerPosition initialGame
