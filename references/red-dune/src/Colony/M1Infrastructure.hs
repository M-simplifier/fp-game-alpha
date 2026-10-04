-- Geometry-to-transport adapter, used only by schema4. It does not simulate a
-- second transport system: routes, reservations and movement stay in Transport.
module Colony.M1Infrastructure where
import Colony.Content
import Colony.Construction
import qualified Colony.Space as Space
import Colony.Topology
import Colony.Transport
import Colony.Types
import Control.Monad(foldM,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

nodeOf :: Space.Tile -> Either Failure RoadNode
nodeOf(Space.Tile x y)=roadNode x y
tileOf :: RoadNode -> Space.Tile
tileOf node=let(x,y)=nodeXY node in Space.Tile x y

-- Road plans may acquire an adjacent material-delivery port after their neighbour
-- is really completed. A building keeps its fixed external connector.
refreshConstructionPorts :: Content -> Inventory -> ConstructionState -> Space.SpatialState -> Either Failure Space.SpatialState
refreshConstructionPorts content inventory construction initial=foldM refresh(Space.refreshCachePorts initial)
  [job|job<-M.elems(constructionJobs construction),not(constructionTerminal job)]
  where
    refresh space job=do
      placement<-maybe(Left TargetGone)Right(M.lookup(constructionSiteId job)(Space.spatialPlacements space))
      location<-either(Left . Space.spaceFailure)Right(materialLocation content space placement)
      a<-either(Left . Space.spaceFailure)Right(Space.registerOwnerLocation inventory(constructionInput job)location space)
      either(Left . Space.spaceFailure)Right(Space.registerOwnerLocation inventory(constructionEscrow job)location a)

spatialPorts :: Space.SpatialState -> Either Failure(M.Map Owner RoadNode)
spatialPorts space=fmap M.fromList $ mapM make
  [(owner,tile)|(owner,location)<-M.toAscList(Space.spatialOwnerLocations space)
    ,let Owner kind _=owner,kind `elem` [Warehouse,MachineInput,MachineOutput,Tank,Pantry,GroundCache]
    ,Just tile<-[Space.ownerRoadConnector location],S.member tile(Space.spatialRoads space)]
  where make(owner,tile)=(owner,) <$> nodeOf tile
spatialRoadCaches :: Space.SpatialState -> Either Failure(M.Map RoadNode Owner)
spatialRoadCaches space=fmap M.fromList $ mapM(\(tile,cache)->(,Space.cacheOwner cache) <$> nodeOf tile)
  [(tile,cache)|(tile,cache)<-M.toAscList(Space.spatialCaches space),S.member tile(Space.spatialRoads space)]

syncInfrastructure :: Content -> Inventory -> BoundarySeq -> ConstructionState -> Space.SpatialState -> TransportState
                   -> Either Failure(Space.SpatialState,TransportState)
syncInfrastructure content inventory boundary construction initial transport=do
  space<-refreshConstructionPorts content inventory construction initial
  nodes<-S.fromList <$> mapM nodeOf(S.toAscList(Space.spatialRoads space))
  let oldTopology=transportTopology transport
  unless(roadNodes oldTopology `S.isSubsetOf` nodes)(Left(InvalidReference "M1 built road removal is not implemented"))
  topology<-foldM add(oldTopology{roadNodes=nodes})
    [(tile,other)|tile@(Space.Tile x y)<-S.toAscList(Space.spatialRoads space)
      ,other<-[Space.Tile(x+1)y,Space.Tile x(y+1)],S.member other(Space.spatialRoads space)]
  ports<-spatialPorts space
  caches<-spatialRoadCaches space
  let topologyChanged=roadNodes oldTopology/=nodes||roadEdges oldTopology/=roadEdges topology
      portsChanged=ports/=transportPorts transport
      oldRevision=topologyRevision oldTopology
  revised<-if topologyChanged||portsChanged then do
      unless(oldRevision<maxBound)(Left CounterOverflow)
      pure topology{topologyRevision=oldRevision+1}
    else pure topology
  let changed=topologyChanged||portsChanged
      removed=M.fromList[(owner,boundary)|owner<-M.keys(transportPorts transport),not(M.member owner ports),not(M.member owner(invStorage inventory))]
      next=transport{transportTopology=revised,transportPorts=ports,transportGroundCaches=caches
        ,transportRemovedPorts=M.union removed(M.withoutKeys(transportRemovedPorts transport)(M.keysSet ports))}
      reset=next{transportPaths=emptyPathQueue
        ,transportRequests=M.map(\request->if requestStatus request==RequestOpen&&requestRemaining request>0
            then request{requestPathResult=PathSearching,requestBlock=Just Searching} else request)(transportRequests next)
        ,transportVehicles=M.map(\vehicle->case vehiclePosition vehicle of
            AtRoadNode _->vehicle{vehicleRoute=[]};_->vehicle)(transportVehicles next)}
  pure(space,if changed then reset else next)
  where
    add topology(tile,other)=do
      a<-nodeOf tile;b<-nodeOf other
      let terrain=Space.mapTerrain(Space.spatialMap initial)
          cost=if any(\t->M.lookup t terrain==Just Space.Pass)[tile,other]then 20 else 10
      -- New construction never implicitly reopens a previously closed edge.
      case edgeBetween topology a b of
        Just edge|roadCost edge==cost->Right topology
                 |otherwise->Left(InvariantViolation "road terrain/cost mismatch")
        Nothing->setRoad boundary a b cost True topology

-- The existing transport return fallback can allocate only at its current road
-- node. Bind every such physical cache to the same unique spatial tile owner in
-- the caller's whole transaction, including caches created by P1/P2/P4.
bindTransportCaches :: Content -> Inventory -> TransportState -> Space.SpatialState -> Either Failure Space.SpatialState
bindTransportCaches content inventory transport initial=foldM bind initial(M.toAscList(transportGroundCaches transport))
  where
    bind space(node,owner)=do
      storage<-maybe(Left MissingOwner)Right(M.lookup owner(invStorage inventory))
      let tile=tileOf node;colony=storageColony storage
          context=Space.CacheContext tile colony(Space.TransportReturn tile)
      either(Left . Space.spaceFailure)Right(Space.cacheEligible content space context tile)
      let cache=Space.CacheRecord owner colony(S.singleton context)
      combined<-case M.lookup tile(Space.spatialCaches space)of
        Nothing->Right cache
        Just old->do
          unless(Space.cacheOwner old==owner)(Left(InvariantViolation "multiple transport/cache owners at one tile"))
          Right old{Space.cacheContexts=S.insert context(Space.cacheContexts old)}
      either(Left . Space.spaceFailure)Right(Space.validateCacheStorage inventory tile combined)
      pure(Space.refreshCachePorts space{Space.spatialCaches=M.insert tile combined(Space.spatialCaches space)})
