{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoGeneralizedNewtypeDeriving #-}

-- | Authoritative 512 x 512 road graph and resumable integer reference Dijkstra.
-- No distance estimate is ever used as a route or a movement duration.
module Colony.Topology where

import Colony.Types
import Colony.Units (quantityMax)
import Control.DeepSeq (NFData)
import Control.Monad (foldM, unless)
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)

newtype RoadNode = RoadNode Word64 deriving (Eq, Ord, Show, Read, Generic, NFData)

data RoadEdge = RoadEdge
  {roadCost :: !Integer, roadOpen :: !Bool, roadClosedAt :: !(Maybe BoundarySeq)}
  deriving (Eq, Show, Read, Generic, NFData)

data RoadTopology = RoadTopology
  { topologyRevision :: !Word64,
    roadNodes :: !(S.Set RoadNode),
    roadEdges :: !(M.Map (RoadNode, RoadNode) RoadEdge)
  }
  deriving (Eq, Show, Read, Generic, NFData)

data PathResult = PathSearching | PathFound ![RoadNode] !Integer | PathUnavailable
  deriving (Eq, Show, Read, Generic, NFData)

data PathSearch = PathSearch
  { pathId :: !EntityId,
    pathSource :: !RoadNode,
    pathDestination :: !RoadNode,
    pathPriority :: !Integer,
    pathReadySince :: !SimTick,
    pathRevision :: !Word64,
    pathOpenSet :: !(S.Set (Integer, RoadNode)),
    pathClosedSet :: !(S.Set RoadNode),
    pathParents :: !(M.Map RoadNode RoadNode),
    pathCosts :: !(M.Map RoadNode Integer),
    pathResult :: !PathResult,
    pathExpanded :: !Word64
  }
  deriving (Eq, Show, Read, Generic, NFData)

data PathQueue = PathQueue
  { pathSearches :: !(M.Map EntityId PathSearch),
    pathCursor :: !(Maybe EntityId),
    pathLastWork :: !Word64
  }
  deriving (Eq, Show, Read, Generic, NFData)

emptyTopology :: RoadTopology
emptyTopology = RoadTopology 0 S.empty M.empty

emptyPathQueue :: PathQueue
emptyPathQueue = PathQueue M.empty Nothing 0

roadNode :: Integer -> Integer -> Either Failure RoadNode
roadNode x y
  | x >= 0 && x < 512 && y >= 0 && y < 512 = Right (RoadNode (fromInteger (y * 512 + x)))
  | otherwise = Left (InvalidReference "Road coordinate outside 512x512 world")

nodeXY :: RoadNode -> (Integer, Integer)
nodeXY (RoadNode n) = (toInteger (n `mod` 512), toInteger (n `div` 512))

validNode :: RoadNode -> Bool
validNode (RoadNode n) = n < 262144

nodeDistance :: RoadNode -> RoadNode -> Integer
nodeDistance a b = let (x, y) = nodeXY a; (u, v) = nodeXY b in abs (x - u) + abs (y - v)

edgeKey :: RoadNode -> RoadNode -> (RoadNode, RoadNode)
edgeKey a b = if a < b then (a, b) else (b, a)

edgeBetween :: RoadTopology -> RoadNode -> RoadNode -> Maybe RoadEdge
edgeBetween topology a b = M.lookup (edgeKey a b) (roadEdges topology)

openEdge :: RoadTopology -> RoadNode -> RoadNode -> Maybe RoadEdge
openEdge topology a b = case edgeBetween topology a b of Just e | roadOpen e -> Just e; _ -> Nothing

-- Order is normative even though the queue tie break is independent of insertion.
roadNeighbours :: RoadTopology -> RoadNode -> [(RoadNode, Integer)]
roadNeighbours topology node =
  let (x, y) = nodeXY node
   in [(n, roadCost edge) | (a, b) <- [(x, y - 1), (x + 1, y), (x, y + 1), (x - 1, y)], Right n <- [roadNode a b], Just edge <- [openEdge topology node n]]

setRoad :: BoundarySeq -> RoadNode -> RoadNode -> Integer -> Bool -> RoadTopology -> Either Failure RoadTopology
setRoad boundary a b cost active topology = do
  unless (validNode a && validNode b && nodeDistance a b == 1) (Left (InvalidReference "Road edge must join four-neighbour world tiles"))
  unless (cost == 10 || cost == 20) (Left (InvalidReference "Road edge cost must be 10 or 20"))
  let key = edgeKey a b
      next = RoadEdge cost active (if active then Nothing else Just boundary)
  if maybe False (\old -> roadCost old == cost && roadOpen old == active) (M.lookup key (roadEdges topology))
    then Right topology
    else do
      unless (topologyRevision topology < maxBound) (Left CounterOverflow)
      pure topology {topologyRevision = topologyRevision topology + 1, roadNodes = S.insert a (S.insert b (roadNodes topology)), roadEdges = M.insert key next (roadEdges topology)}

closeRoad :: BoundarySeq -> RoadNode -> RoadNode -> RoadTopology -> Either Failure RoadTopology
closeRoad boundary a b topology = case edgeBetween topology a b of
  Nothing -> Left TargetGone
  Just edge -> setRoad boundary a b (roadCost edge) False topology

reopenRoad :: BoundarySeq -> RoadNode -> RoadNode -> RoadTopology -> Either Failure RoadTopology
reopenRoad boundary a b topology = case edgeBetween topology a b of
  Nothing -> Left TargetGone
  Just edge -> setRoad boundary a b (roadCost edge) True topology

newPath :: RoadTopology -> EntityId -> RoadNode -> RoadNode -> Integer -> SimTick -> PathSearch
newPath topology ident src dst priority ready =
  PathSearch
    ident
    src
    dst
    priority
    ready
    (topologyRevision topology)
    (S.singleton (0, src))
    S.empty
    M.empty
    (M.singleton src 0)
    PathSearching
    0

requestPath :: RoadTopology -> EntityId -> RoadNode -> RoadNode -> Integer -> SimTick -> PathQueue -> Either Failure PathQueue
requestPath topology ident src dst priority ready queue = do
  unless (M.size (pathSearches queue) < 4096 || M.member ident (pathSearches queue)) (Left PathQueueFull)
  unless (priority >= 0 && priority <= 3) (Left InvalidQuantity)
  unless (validNode src && validNode dst) (Left (InvalidReference "Invalid path endpoint"))
  unless (not (M.member ident (pathSearches queue))) (Left (InvalidReference "Duplicate path request"))
  pure queue {pathSearches = M.insert ident (newPath topology ident src dst priority ready) (pathSearches queue)}

dropPath :: EntityId -> PathQueue -> PathQueue
dropPath ident queue = queue {pathSearches = M.delete ident (pathSearches queue)}

restartStale :: RoadTopology -> PathSearch -> PathSearch
restartStale topology search
  | pathRevision search == topologyRevision topology = search
  | otherwise = newPath topology (pathId search) (pathSource search) (pathDestination search) (pathPriority search) (pathReadySince search)

-- The cap counts settled node expansions, never wall time or recursive calls.
advanceSearch :: Word64 -> RoadTopology -> PathSearch -> Either Failure (PathSearch, Word64)
advanceSearch budget topology original = go budget 0 (restartStale topology original)
  where
    go 0 spent search = Right (search, spent)
    go left spent search
      | pathResult search /= PathSearching = Right (search, spent)
      | otherwise = case S.minView (pathOpenSet search) of
          Nothing -> Right (search {pathResult = PathUnavailable}, spent)
          Just ((cost, node), rest) -> do
            unless (pathExpanded search < maxBound) (Left CounterOverflow)
            let expanded = search {pathOpenSet = rest, pathClosedSet = S.insert node (pathClosedSet search), pathExpanded = pathExpanded search + 1}
            if node == pathDestination search
              then do
                route <- reconstruct expanded node
                Right (expanded {pathResult = PathFound route cost}, spent + 1)
              else do
                next <- foldM (relax node cost) expanded (roadNeighbours topology node)
                go (left - 1) (spent + 1) next
    relax parent base search (node, edgeCost)
      | S.member node (pathClosedSet search) = Right search
      | otherwise = do
          let cost = base + edgeCost
          unless (cost <= quantityMax) (Left CounterOverflow)
          case M.lookup node (pathCosts search) of
            Just old
              | cost > old -> Right search
              | cost == old -> Right search {pathParents = M.insertWith min node parent (pathParents search)}
            old -> Right search {pathOpenSet = S.insert (cost, node) (maybe id (\n -> S.delete (n, node)) old (pathOpenSet search)), pathCosts = M.insert node cost (pathCosts search), pathParents = M.insert node parent (pathParents search)}
    reconstruct search node = walk S.empty node []
      where
        walk seen n suffix
          | S.member n seen = Left (InvariantViolation "Path parent cycle")
          | n == pathSource search = Right (n : suffix)
          | otherwise = case M.lookup n (pathParents search) of
              Nothing -> Left (InvariantViolation "Path parent missing")
              Just p -> walk (S.insert n seen) p (n : suffix)

effectivePathPriority :: SimTick -> PathSearch -> Integer
effectivePathPriority (SimTick now) search = let SimTick ready = pathReadySince search in max 0 (pathPriority search - (max 0 (toInteger now - toInteger ready) `div` 1200))

-- Each priority class is visited in ready/id order with a persisted round-robin
-- cursor. A long search cannot monopolize all 8192 expansions ahead of peers.
advancePaths :: SimTick -> RoadTopology -> PathQueue -> Either Failure PathQueue
advancePaths tick topology original = go 8192 refreshed {pathLastWork = 0}
  where
    refreshed = original {pathSearches = M.map (restartStale topology) (pathSearches original)}
    go 0 queue = Right queue
    go remaining queue = case eligible queue of
      [] -> Right queue
      search : _ -> do
        (next, used) <- advanceSearch (min 256 remaining) topology search
        let updated = queue {pathSearches = M.insert (pathId search) next (pathSearches queue), pathCursor = Just (pathId search), pathLastWork = pathLastWork queue + used}
        -- An exhausted frontier is terminal, so zero-work visits cannot repeat.
        go (remaining - used) updated
    eligible queue = case sortOn (\s -> (effectivePathPriority tick s, pathReadySince s, pathId s)) [s | s <- M.elems (pathSearches queue), pathResult s == PathSearching] of
      [] -> []
      xs@(first : _) ->
        let rank = effectivePathPriority tick first; peers = takeWhile ((== rank) . effectivePathPriority tick) xs
         in case pathCursor queue of
              Nothing -> peers
              Just cursor -> case break ((== cursor) . pathId) peers of
                (_, []) -> peers
                (before, current : after) -> after ++ before ++ [current]

referencePath :: RoadTopology -> RoadNode -> RoadNode -> Either Failure PathResult
referencePath topology src dst = pathResult . fst <$> advanceSearch 262144 topology (newPath topology (EntityId 0) src dst 0 (SimTick 0))

validateTopology :: RoadTopology -> PathQueue -> Either Failure ()
validateTopology topology queue = do
  let check ok msg = unless ok (Left (InvariantViolation msg))
  check (all validNode (S.toList (roadNodes topology))) "Invalid road node"
  mapM_
    ( \((a, b), edge) -> do
        check (a < b && nodeDistance a b == 1 && S.member a (roadNodes topology) && S.member b (roadNodes topology)) "Invalid four-neighbour edge"
        check (roadCost edge `elem` [10, 20]) "Invalid road traversal cost"
        check (roadOpen edge == (roadClosedAt edge == Nothing)) "Road tombstone status mismatch"
    )
    (M.toList (roadEdges topology))
  check (M.size (pathSearches queue) <= 4096 && pathLastWork queue <= 8192) "Path work/queue limit exceeded"
  mapM_
    ( \(ident, search) -> do
        check (ident == pathId search && pathPriority search >= 0 && pathPriority search <= 3) "Invalid path identity or priority"
        check (validNode (pathSource search) && validNode (pathDestination search)) "Invalid path endpoints"
        check (pathRevision search <= topologyRevision topology) "Path revision is from the future"
        check (M.lookup (pathSource search) (pathCosts search) == Just 0) "Path source cost missing"
        check (all validNode (M.keys (pathCosts search))) "Path discovered invalid world node"
        check (pathClosedSet search `S.isSubsetOf` M.keysSet (pathCosts search)) "Path closed node has no cost"
        check (all (\n -> n >= 0 && n <= quantityMax) (M.elems (pathCosts search))) "Invalid path cost"
        check (all (\(cost, node) -> M.lookup node (pathCosts search) == Just cost && not (S.member node (pathClosedSet search))) (S.toList (pathOpenSet search))) "Invalid path frontier"
        check (all (\(child, parent) -> nodeDistance child parent == 1 && M.member child (pathCosts search) && M.member parent (pathCosts search)) (M.toList (pathParents search))) "Invalid path parent edge"
        check (M.keysSet (pathParents search) == S.delete (pathSource search) (M.keysSet (pathCosts search))) "Path predecessor coverage mismatch"
        if pathRevision search == topologyRevision topology
          then
            mapM_
              ( \(child, parent) -> case (openEdge topology parent child, M.lookup parent (pathCosts search), M.lookup child (pathCosts search)) of
                  (Just edge, Just base, Just cost) -> check (cost == base + roadCost edge) "Path predecessor cost mismatch"
                  _ -> check False "Path predecessor is not a live edge"
              )
              (M.toList (pathParents search))
          else Right ()
        case pathResult search of
          PathFound nodes cost -> do
            check (not (null nodes) && head nodes == pathSource search && last nodes == pathDestination search) "Invalid path result endpoints"
            check (all (\(a, b) -> nodeDistance a b == 1) (zip nodes (drop 1 nodes))) "Nonlocal path result"
            check (cost >= 0 && cost <= quantityMax && M.lookup (pathDestination search) (pathCosts search) == Just cost) "Invalid path result cost"
            if pathRevision search == topologyRevision topology
              then do
                let edges = [openEdge topology a b | (a, b) <- zip nodes (drop 1 nodes)]
                check (all (\edge -> case edge of Just _ -> True; _ -> False) edges) "Path result crosses closed/missing edge"
                check (sum [roadCost edge | Just edge <- edges] == cost) "Path result total cost mismatch"
              else Right ()
          _ -> Right ()
    )
    (M.toList (pathSearches queue))
