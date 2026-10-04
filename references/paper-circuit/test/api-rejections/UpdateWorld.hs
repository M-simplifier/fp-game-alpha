module UpdateWorld where

import Paper.Game

invalid :: World
invalid = initial {previousPosition = Nothing}
