-- | Game-specific laws, independent of the window, clock and renderer.
module Garden.Simulation (Effect (..), stepWorld, nearby, supported) where

import Data.List (find, foldl', sortOn)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Garden.World

data Effect
  = Flowed !Int
  | Germinated !Coord
  | Grew !Coord !Coord !Coord -- parent, new leaf, consumed water
  | Painted !Material !Int
  | Selected !Material
  | Paused !Bool
  | Reset
  deriving (Eq, Show)

nearby :: Int -> Cell -> World -> Coord -> [Coord]
nearby radius c w p =
  [ q | dy <- [-radius .. radius], dx <- [-radius .. radius]
      , Just q <- [offset p (dx,dy)], cellAt w q == c ]

supported :: World -> Coord -> (Bool, Bool)
supported w p = (not (null (nearby 3 Water w p)), not (null (nearby 10 Light w p)))

-- | Movement is bottom-up with alternating horizontal priority. Each moved
-- particle, including displaced water, is marked and moves at most once.
-- Growth reads one post-movement snapshot; resource claims resolve row-major.
stepWorld :: World -> (World, [Effect])
stepWorld original = (advanceTime grown, flowEffects ++ reverse growthEffects)
  where
    t = worldTick original
    order = sortOn priority coords
    priority p = let (x,y) = xy p in (-y, if even t then -x else x)
    (fallen, _, movedCount) = foldl' move (original, Set.empty, 0) order
    flowEffects = [Flowed movedCount | movedCount > 0]
    (grown, growthEffects)
      | t `mod` 3 /= 0 = (fallen, [])
      | otherwise = foldl' grow (fallen, []) (occupied fallen)
    move state@(w, moved, n) p
      | Set.member p moved = state
      | c `notElem` [Water, Sand, SeedCell] = state
      | Just below <- offset p (0,1), cellAt w below == Empty = transfer below
      | c == Sand, Just below <- offset p (0,1), cellAt w below == Water
      , Set.notMember below moved =
          (writeCells [(p,Water),(below,Sand)] w,
            Set.insert p (Set.insert below moved), n + 1)
      | Just destination <- find ((== Empty) . cellAt w) candidates = transfer destination
      | otherwise = state
      where
        c = cellAt w p
        d = if sample (worldSeed w) p t `mod` 2 == 0 then -1 else 1
        candidates = mapMaybe (offset p) ([(d,1),(-d,1)] ++ if c == Water then [(d,0),(-d,0)] else [])
        transfer q = (writeCells [(p,Empty),(q,c)] w, Set.insert q moved, n + 1)
    grow state@(w, effects) (p,c)
      | c `notElem` [SeedCell,Plant] = state
      | supported fallen p /= (True,True) = state
      | c == SeedCell = (writeCells [(p,Plant)] w, Germinated p : effects)
      | t `mod` 12 /= 0 = state
      | Just q <- find ((== Empty) . cellAt w) (mapMaybe (offset p) [(0,-1),(-1,-1),(1,-1)])
      , Just drink <- find ((== Water) . cellAt w) (nearby 3 Water fallen p) =
          let leaf = if sample (worldSeed w) q t `mod` 7 == 0 then Flower else Plant
           in (writeCells [(drink,Empty),(q,leaf)] w, Grew p q drink : effects)
      | otherwise = state
