module SimulationChecks (checks) where

import Garden.Session qualified as Session
import Garden.Simulation
import Garden.World

checks :: [(String, Bool)]
checks =
  [ ( "a lateral water transfer moves only once in its sweep",
      let source = point 10 10
          destination = point 9 10
          blocked = [(point x 11, Stone) | x <- [8 .. 12]] ++ [(point 11 10, Stone)]
          world = fixture ((source, Water) : blocked)
          (next, effects) = stepWorld world
       in cellAt next source == Empty
            && cellAt next destination == Water
            && cellAt next (point 8 10) == Empty
            && waterCount next == 1
            && worldTick next == 1
            && effects == [Flowed 1]
    ),
    ( "sand displaces water without losing or moving either particle again",
      let sand = point 10 10
          water = point 10 11
          blocked = [(point x 12, Stone) | x <- [9 .. 11]] ++ [(point 9 11, Stone), (point 11 11, Stone)]
          (next, effects) = stepWorld (fixture ((sand, Sand) : (water, Water) : blocked))
       in cellAt next sand == Water
            && cellAt next water == Sand
            && waterCount next == 1
            && length [() | (_, Sand) <- occupied next] == 1
            && effects == [Flowed 1]
    ),
    ( "growth claims one water cell in row-major order",
      let first = point 10 10
          second = point 12 10
          water = point 11 10
          blocked = [(point x 11, Stone) | x <- [10 .. 12]]
          world = fixture ([(first, Plant), (second, Plant), (water, Water), (point 11 8, Light)] ++ blocked)
          (next, effects) = stepWorld world
          (resting, laterEffects) = stepWorld next
       in effects == [Grew first (point 10 9) water]
            && cellAt next water == Empty
            && cellAt next (point 10 9) `elem` [Plant, Flower]
            && cellAt next (point 12 9) == Empty
            && length [() | (_, material) <- occupied next, material `elem` [Plant, Flower]] == 3
            && occupied resting == occupied next
            && null laterEffects
    ),
    ( "painting clips its footprint and reports changed cells only",
      let start = Session.newSession seed
          commands = map Session.Input [Session.Select PlaceStone, Session.Paint (point 0 0)]
          (painted, effects) = Session.applyEvents commands start
          (same, repeated) = Session.advance (Session.Input (Session.Paint (point 0 0))) painted
          world = Session.sessionWorld painted
       in all ((== Stone) . cellAt world) [point 0 0, point 1 0, point 0 1]
            && cellAt world (point 1 1) == Empty
            && worldTick world == 0
            && effects == [Selected PlaceStone, Painted PlaceStone 3]
            && same == painted
            && null repeated
    ),
    ( "ordered edit batches retain chronological effects without ticking",
      let start = Session.newSession seed
          (next, effects) =
            Session.applyEvents
              (map Session.Input [Session.Select PlaceStone, Session.Paint (point 0 0), Session.Select Erase, Session.EraseAt (point 0 0)])
              start
       in Session.sessionWorld next == Session.sessionWorld start
            && Session.selectedMaterial next == Erase
            && effects == [Selected PlaceStone, Painted PlaceStone 3, Selected Erase, Painted Erase 3]
    ),
    ( "world edits keep last-write priority and remove empty entries",
      let location = point 2 2
          next = writeCells [(location, Sand), (location, Water), (location, Empty)] (emptyWorld seed)
       in null (occupied next) && cellAt next location == Empty && worldTick next == 0
    )
  ]
  where
    waterCount world = length [() | (_, Water) <- occupied world]

seed :: Seed
seed = seedFromText "simulation-boundaries"

fixture :: [(Coord, Cell)] -> World
fixture edits = writeCells edits (emptyWorld seed)

point :: Int -> Int -> Coord
point x y = case coord x y of
  Just position -> position
  Nothing -> error "invalid simulation test coordinate"
