module RejectWorldUpdate where

import Lantern

-- This must not compile: an external caller cannot break state invariants.
escape :: Board -> World
escape board = (initial board) { positions = [] }
