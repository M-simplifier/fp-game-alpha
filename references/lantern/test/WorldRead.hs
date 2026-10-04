module WorldRead where

import Lantern

-- Public observation works without exposing a record-update field.
observeWorld :: Board -> ([Int], Int)
observeWorld board = (positions world, remaining world)
  where world = initial board
