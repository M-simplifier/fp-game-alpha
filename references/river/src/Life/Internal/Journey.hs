module Life.Internal.Journey (walkToCell, scenarioGame) where

import Data.List (foldl')
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Life.Internal.Core

-- | Walk with real ticks along a breadth-first route.  Used by executable
-- render-checks and tests; this never directly rewrites or teleports Game.
-- Unreachable or invalid destinations leave the original state unchanged.
walkToCell :: Cell -> Game -> Game
walkToCell target start = case route (playerCell start) target start of
  Nothing -> start
  Just waypoints -> foldl' walkSegment start (playerCell start : waypoints)
  where
    walkSegment g c = go (40 :: Int) g
      where
        (tx, tz) = center c
        go 0 current = current
        go budget current
          | abs (tx - gPlayerX current) < 10 && abs (tz - gPlayerZ current) < 10 = current
          | otherwise =
              let dx = signum (tx - gPlayerX current)
                  dz = if dx == 0 then signum (tz - gPlayerZ current) else 0
               in go (budget - 1) (fst (advance (Tick dx dz) current))

route :: Cell -> Cell -> Game -> Maybe [Cell]
route start target g
  | not (walkableCell target g) = Nothing
  | otherwise = search (Seq.singleton (start, [])) (Set.singleton start)
  where
    search queue visited = case Seq.viewl queue of
      Seq.EmptyL -> Nothing
      (c, reversed) Seq.:< rest
        | c == target -> Just (reverse reversed)
        | otherwise ->
            let next = filter (\n -> walkableCell n g && Set.notMember n visited) (neighbors c)
                queue' = foldl' (\q n -> q Seq.|> (n, n : reversed)) rest next
                visited' = foldl' (flip Set.insert) visited next
             in search queue' visited'
    neighbors (Cell x z) = [Cell (x + 1) z, Cell x (z + 1), Cell (x - 1) z, Cell x (z - 1)]

-- | Representative scenes are real legal command traces.  DayTwo includes a
-- sheltered crop and a sheltered log beside exposed peers.  DayThree has ripe
-- exposed crops and a delayed roofed crop, so the tradeoff remains visible.
scenarioGame :: Scenario -> Game
scenarioGame scenario = case scenario of
  DayOne -> day1
  DayTwo -> day2
  DayThree -> day3
  AfterDinner -> finished
  where
    useAt c = fst . advance Interact . walkToCell c
    plantAndWater g c = fst (advance Interact (useAt c g))
    planted = foldl' plantAndWater initialGame cropCells
    loaded = foldl' (flip useAt) planted woodCells
    promised = useAt (neighborCell loaded) loaded
    roofAt c = fst . advance (BuildAt c) . fst . advance (ChooseBuild Roof) . walkToCell c
    day1 = roofAt (Cell 8 5) (roofAt (Cell 7 9) promised)
    day2 = useAt homeCell day1
    day3 = useAt homeCell day2
    withTurnip = useAt (Cell 9 5) day3
    withWood = useAt (Cell 7 9) withTurnip
    dinner = useAt cookingCell withWood
    finished = useAt (neighborCell dinner) dinner
