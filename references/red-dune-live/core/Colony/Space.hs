{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Pure reduced-map geometry and return-cache placement for profile 6/7.
-- Inventory alone owns stock, storage capacity, and the global ID allocator.
-- Coordinates are local scenario coordinates, indexed on the global 512 stride.
module Colony.Space where

import Colony.Content
import Colony.Inventory qualified as I
import Colony.Types
import Colony.Units (Resource, qtyValue)
import Control.DeepSeq (NFData)
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict (get)
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)

data Tile = Tile !Integer !Integer deriving (Eq, Show, Read, Generic, NFData)

-- Row-major on valid tiles; coordinate ties preserve Eq consistency even for
-- rejected coordinates such as (512,0) versus (0,1).
instance Ord Tile where
  compare a@(Tile x y) b@(Tile u v)
    -- On valid coordinates, row-major index ordering is exactly (y,x).
    -- Avoid allocating two Integer products/sums on every Map/Set comparison.
    -- Keep the old total order for rejected coordinates and arithmetic ties.
    | valid x && valid y && valid u && valid v = case compare y v of
        EQ -> compare x u
        result -> result
    | otherwise = compare (tileIndex a, x, y) (tileIndex b, u, v)
    where
      valid n = n >= 0 && n < 512

data Rect = Rect !Tile !Integer !Integer deriving (Eq, Ord, Show, Read, Generic, NFData)

data Rotation = R0 | R90 | R180 | R270 deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, NFData)

data Terrain = Flat | Rock | Cliff | Aquifer | Salt | Pass deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, NFData)

data MapSpec = MapSpec
  { mapFixtureId :: !String,
    mapFixtureVersion :: !Word64,
    mapActiveBounds :: !Rect,
    mapCropOrigin :: !Tile,
    mapTerrain :: !(M.Map Tile Terrain)
  }
  deriving (Eq, Show, Read, Generic, NFData)

data SourceRegion = SourceRegion
  { sourceRegionId :: !EntityId,
    sourceRegionKind :: !String,
    sourceRegionResource :: !Resource,
    sourceRegionBounds :: !Rect
  }
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data PortGeometry = PortGeometry
  {boundaryPort :: !Tile, roadConnector :: !Tile}
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data PlacementShape = BuildingShape !String !Tile !Rotation | RoadShape !Tile
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data PlacementStage = PlanReserved | BuildingSite | Built
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data Placement = Placement
  { placementId :: !EntityId,
    placementColony :: !EntityId,
    placementShape :: !PlacementShape,
    placementStage :: !PlacementStage,
    placementSource :: !(Maybe EntityId),
    placementRevision :: !Word64
  }
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data OwnerLocation = OwnerLocation
  {ownerTile :: !Tile, ownerRoadConnector :: !(Maybe Tile)}
  deriving (Eq, Ord, Show, Read, Generic, NFData)

-- The reason carries its authority context. Aid is represented for validation,
-- but this module does not implement or authorize the EmergencyAid command.
data CacheReason
  = ConstructionReturn !EntityId
  | RecipeReturn !EntityId
  | TransportReturn !Tile
  | EmergencyAid !Tile
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data CacheContext = CacheContext
  {cacheOrigin :: !Tile, cacheColony :: !EntityId, cacheReason :: !CacheReason}
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data CacheRecord = CacheRecord
  { cacheOwner :: !Owner,
    cacheOwnerColony :: !EntityId,
    cacheContexts :: !(S.Set CacheContext)
  }
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data SpatialState = SpatialState
  { spatialMap :: !MapSpec,
    spatialSources :: !(M.Map EntityId SourceRegion),
    spatialPlacements :: !(M.Map EntityId Placement),
    spatialRoads :: !(S.Set Tile),
    spatialPipes :: !(S.Set Tile),
    spatialWires :: !(S.Set Tile),
    spatialOwnerLocations :: !(M.Map Owner OwnerLocation),
    spatialCaches :: !(M.Map Tile CacheRecord),
    spatialDepotRuins :: !(M.Map Tile EntityId),
    spatialBlockingRevision :: !Word64
  }
  deriving (Eq, Show, Read, Generic, NFData)

data SpaceError
  = InvalidMap !String
  | OutsideWorld !Tile
  | OutsideScenario !Tile
  | IllegalTerrain !Tile !Terrain
  | UnknownPrototype !String
  | InvalidFootprint
  | FootprintConflict !Tile !EntityId
  | RoadConflict !Tile
  | PortConflict !Tile
  | CacheConflict !Tile
  | SourceConflict !Tile
  | InvalidSource !EntityId !String
  | NoCompatibleSource
  | SourceDepleted !EntityId
  | UnneededSource !EntityId
  | DuplicatePlacement !EntityId
  | PlacementMissing !EntityId
  | InvalidPlacementStage
  | InvalidCacheContext !String
  | ForeignCache !Tile !EntityId
  | InvalidCacheStorage !Tile
  | InvalidOwnerLocation !Owner
  | SpatialCounterOverflow
  | UnallocatedSpatialId !EntityId
  | InvalidSpatialState !String
  deriving (Eq, Ord, Show, Read, Generic, NFData)

worldBounds :: Rect
worldBounds = Rect (Tile 0 0) 512 512

cacheCapacity :: Integer
cacheCapacity = 2000000

emptySpatial :: MapSpec -> SpatialState
emptySpatial spec = SpatialState spec M.empty M.empty S.empty S.empty S.empty M.empty M.empty M.empty 0

tileIndex :: Tile -> Integer
tileIndex (Tile x y) = y * 512 + x

manhattan :: Tile -> Tile -> Integer
manhattan (Tile x y) (Tile a b) = abs (x - a) + abs (y - b)

rectTiles :: Rect -> S.Set Tile
rectTiles (Rect (Tile x y) w h) = S.fromList [Tile a b | b <- [y .. y + h - 1], a <- [x .. x + w - 1]]

insideRect :: Rect -> Tile -> Bool
insideRect (Rect (Tile x y) w h) (Tile a b) = w > 0 && h > 0 && a >= x && a < x + w && b >= y && b < y + h

translate :: Tile -> Tile -> Tile
translate (Tile x y) (Tile a b) = Tile (x + a) (y + b)

validRect :: Rect -> Bool
validRect (Rect origin@(Tile x y) w h) = w > 0 && h > 0 && insideRect worldBounds origin && insideRect worldBounds (Tile (x + w - 1) (y + h - 1))

checkTile :: MapSpec -> Tile -> Either SpaceError ()
checkTile spec tile
  | not (insideRect worldBounds tile) = Left (OutsideWorld tile)
  | not (insideRect (mapActiveBounds spec) tile) = Left (OutsideScenario tile)
  | otherwise = Right ()

terrainAt :: MapSpec -> Tile -> Terrain
terrainAt spec tile = M.findWithDefault Flat tile (mapTerrain spec)

walkable :: Terrain -> Bool
walkable terrain = terrain `elem` [Flat, Rock, Pass]

validateMap :: MapSpec -> Either SpaceError ()
validateMap spec = do
  unless (not (null (mapFixtureId spec)) && mapFixtureVersion spec > 0) (Left (InvalidMap "missing fixture identity/version"))
  unless (validRect (mapActiveBounds spec)) (Left (InvalidMap "invalid active bounds"))
  let Rect (Tile x y) w h = mapActiveBounds spec
      crop = mapCropOrigin spec
  unless (insideRect worldBounds crop) (Left (InvalidMap "invalid crop origin"))
  unless (validRect (Rect (translate crop (Tile x y)) w h)) (Left (InvalidMap "crop exceeds full-world bounds"))
  forM_ (M.keys (mapTerrain spec)) (checkTile spec)

-- Clockwise rotation in screen coordinates; even widths keep the content's
-- west-biased south-edge port. Rotate the OUTSIDE tile with the same transform.
rotateLocal :: (Integer, Integer) -> Rotation -> Tile -> Tile
rotateLocal _ R0 p = p
rotateLocal (_, h) R90 (Tile x y) = Tile (h - 1 - y) x
rotateLocal (w, h) R180 (Tile x y) = Tile (w - 1 - x) (h - 1 - y)
rotateLocal (w, _) R270 (Tile x y) = Tile y (w - 1 - x)

footprintGeometry :: (Integer, Integer) -> Tile -> Rotation -> Either SpaceError (S.Set Tile, PortGeometry)
footprintGeometry size@(w, h) origin rotation = do
  unless (w > 0 && h > 0 && w <= 512 && h <= 512) (Left InvalidFootprint)
  let rotate = translate origin . rotateLocal size rotation
      portX = (w - 1) `div` 2
  pure (S.map rotate (rectTiles (Rect (Tile 0 0) w h)), PortGeometry (rotate (Tile portX (h - 1))) (rotate (Tile portX h)))

placementGeometry :: Content -> Placement -> Either SpaceError (S.Set Tile, Maybe PortGeometry)
placementGeometry content placement = case placementShape placement of
  RoadShape tile -> Right (S.singleton tile, Nothing)
  BuildingShape prototype origin rotation -> do
    building <- maybe (Left (UnknownPrototype prototype)) Right (M.lookup prototype (contentBuildings content))
    (tiles, portGeometry) <- footprintGeometry (buildingFootprint building) origin rotation
    pure (tiles, Just portGeometry)

reservedTiles :: Content -> SpatialState -> Either SpaceError (M.Map Tile EntityId)
reservedTiles content state = fmap M.fromList $ fmap concat $ mapM one (M.elems (spatialPlacements state))
  where
    one p = do (tiles, _) <- placementGeometry content p; pure [(t, placementId p) | t <- S.toList tiles]

blockingTiles :: Content -> SpatialState -> Either SpaceError (S.Set Tile)
blockingTiles content state = fmap S.unions $ mapM one (M.elems (spatialPlacements state))
  where
    one p = case placementShape p of
      RoadShape _ -> pure S.empty
      _
        | placementStage p == PlanReserved -> pure S.empty
        | otherwise -> fst <$> placementGeometry content p

portTiles :: Content -> SpatialState -> Either SpaceError (S.Set Tile)
portTiles content state = do
  buildingPorts <- mapM (fmap snd . placementGeometry content) (M.elems (spatialPlacements state))
  pure
    ( S.fromList
        ( concat [[boundaryPort p, roadConnector p] | Just p <- buildingPorts]
            ++ [tile | location <- M.elems (spatialOwnerLocations state), Just tile <- [ownerRoadConnector location]]
        )
    )

sourceTiles :: SpatialState -> S.Set Tile
sourceTiles = S.unions . map (rectTiles . sourceRegionBounds) . M.elems . spatialSources

sourceRequirements :: Content -> String -> S.Set (String, Resource)
sourceRequirements content prototype =
  S.fromList
    [ (kind, naturalSourceResource source)
    | recipe <- M.elems (contentRecipes content),
      recipeBuilding recipe == prototype,
      kind <- M.keys (recipeNaturalSources recipe),
      Just source <- [M.lookup kind (contentNaturalSources content)]
    ]

validateSourceRegion :: Content -> Inventory -> MapSpec -> SourceRegion -> Either SpaceError ()
validateSourceRegion content inventory spec region = do
  let ident = sourceRegionId region
      Rect _ w h = sourceRegionBounds region
  unless (w == 8 && h == 8 && validRect (sourceRegionBounds region)) (Left (InvalidSource ident "source region must be explicit 8x8"))
  forM_ (S.toList (rectTiles (sourceRegionBounds region))) (checkTile spec)
  source <- maybe (Left (InvalidSource ident "unknown source kind")) Right (M.lookup (sourceRegionKind region) (contentNaturalSources content))
  unless (naturalSourceResource source == sourceRegionResource region) (Left (InvalidSource ident "kind/resource mismatch"))
  deposit <- maybe (Left (InvalidSource ident "missing Inventory deposit")) Right (M.lookup ident (invDeposits inventory))
  unless
    (depositId deposit == ident && depositKind deposit == sourceRegionKind region && depositResource deposit == sourceRegionResource region)
    (Left (InvalidSource ident "Inventory deposit identity/kind/resource mismatch"))

sourceAdjacent :: S.Set Tile -> SourceRegion -> Bool
sourceAdjacent footprint region =
  not (S.null footprint)
    && let regionTiles = rectTiles (sourceRegionBounds region)
        in S.null (S.intersection footprint regionTiles) && any (\a -> any ((== 1) . manhattan a) (S.toList regionTiles)) (S.toList footprint)

selectSource :: Content -> Inventory -> SpatialState -> String -> S.Set Tile -> Maybe EntityId -> Either SpaceError (Maybe EntityId)
selectSource content inventory state prototype footprint requested
  | S.null requirements = case requested of Nothing -> Right Nothing; Just ident -> Left (UnneededSource ident)
  | otherwise = case requested of
      Just ident -> checkSource True ident >> pure (Just ident)
      Nothing -> case [ident | ident <- M.keys (spatialSources state), Right () <- [checkSource True ident]] of
        ident : _ -> Right (Just ident)
        [] -> case [ident | ident <- M.keys (spatialSources state), Right () <- [checkSource False ident]] of
          depleted : _ -> Left (SourceDepleted depleted)
          [] -> Left NoCompatibleSource
  where
    requirements = sourceRequirements content prototype
    checkSource needStock ident = validateBinding content inventory state requirements footprint needStock ident

validateBinding :: Content -> Inventory -> SpatialState -> S.Set (String, Resource) -> S.Set Tile -> Bool -> EntityId -> Either SpaceError ()
validateBinding content inventory state requirements footprint needStock ident = do
  region <- maybe (Left (InvalidSource ident "unknown source region")) Right (M.lookup ident (spatialSources state))
  validateSourceRegion content inventory (spatialMap state) region
  unless (S.member (sourceRegionKind region, sourceRegionResource region) requirements) (Left (InvalidSource ident "incompatible extractor kind/resource"))
  unless (sourceAdjacent footprint region) (Left (InvalidSource ident "extractor must be adjacent without overlap"))
  when needStock $ case M.lookup ident (invDeposits inventory) of
    Just deposit | qtyValue (depositQty deposit) > 0 -> Right ()
    _ -> Left (SourceDepleted ident)

-- A placement identity is allocated by the caller's InventoryTx, never here.
reserveBuildingPlan :: Content -> Inventory -> EntityId -> EntityId -> String -> Tile -> Rotation -> Maybe EntityId -> SpatialState -> Either SpaceError (Placement, SpatialState)
reserveBuildingPlan content inventory ident colony prototype origin rotation selected state = do
  unless (not (M.member ident (spatialPlacements state))) (Left (DuplicatePlacement ident))
  let base = Placement ident colony (BuildingShape prototype origin rotation) PlanReserved Nothing 1
  (tiles, _) <- placementGeometry content base
  source <- selectSource content inventory state prototype tiles selected
  let placement = base {placementSource = source}
  validatePlacement content inventory state placement
  pure (placement, state {spatialPlacements = M.insert ident placement (spatialPlacements state)})

reserveRoadPlan :: Content -> Inventory -> EntityId -> EntityId -> Tile -> SpatialState -> Either SpaceError (Placement, SpatialState)
reserveRoadPlan content inventory ident colony tile state = do
  unless (not (M.member ident (spatialPlacements state))) (Left (DuplicatePlacement ident))
  let placement = Placement ident colony (RoadShape tile) PlanReserved Nothing 1
  validatePlacement content inventory state placement
  pure (placement, state {spatialPlacements = M.insert ident placement (spatialPlacements state)})

validatePlacement :: Content -> Inventory -> SpatialState -> Placement -> Either SpaceError ()
validatePlacement content inventory state placement = do
  checkAllocated inventory (placementId placement)
  checkAllocated inventory (placementColony placement)
  unless (placementRevision placement > 0) (Left (InvalidSpatialState "zero placement revision"))
  let others = state {spatialPlacements = M.delete (placementId placement) (spatialPlacements state)}
  (tiles, maybePort) <- placementGeometry content placement
  occupied <- reservedTiles content others
  ports <- portTiles content others
  let sources = sourceTiles state
  forM_ (S.toList tiles) $ \tile -> do
    checkWalkable (spatialMap state) tile
    case M.lookup tile occupied of { Just ident -> Left (FootprintConflict tile ident); Nothing -> Right () }
    when (S.member tile sources) (Left (SourceConflict tile))
    when (M.member tile (spatialCaches state) && not (isBuiltRoad placement)) (Left (CacheConflict tile))
    case placementShape placement of
      BuildingShape {} -> do
        when (S.member tile (spatialRoads state)) (Left (RoadConflict tile))
        when (S.member tile ports) (Left (PortConflict tile))
      RoadShape _ -> when (placementStage placement /= Built && S.member tile (spatialRoads state)) (Left (RoadConflict tile))
  case maybePort of
    Nothing -> unless (placementSource placement == Nothing) (Left (InvalidSpatialState "road has source binding"))
    Just portGeometry -> do
      let connector = roadConnector portGeometry
      checkWalkable (spatialMap state) connector
      when (S.member connector sources) (Left (SourceConflict connector))
      case M.lookup connector (spatialCaches state) of
        Just cache | any ordinaryContext (S.toList (cacheContexts cache)) -> Left (CacheConflict connector)
        _ -> pure ()
      case M.lookup connector occupied of
        Just ident -> case M.lookup ident (spatialPlacements others) of
          Just p | RoadShape _ <- placementShape p -> Right ()
          _ -> Left (FootprintConflict connector ident)
        Nothing -> Right ()
      case placementShape placement of
        BuildingShape prototype _ _ -> do
          let requirements = sourceRequirements content prototype
          case placementSource placement of
            Nothing -> unless (S.null requirements) (Left NoCompatibleSource)
            Just ident -> validateBinding content inventory state requirements tiles False ident
        _ -> pure ()
  where
    checkAllocated inv ident@(EntityId n) = unless (n > 0 && n < invNextId inv) (Left (UnallocatedSpatialId ident))
    isBuiltRoad p = case placementShape p of RoadShape _ -> placementStage p == Built; _ -> False
    ordinaryContext context = case cacheReason context of TransportReturn _ -> False; EmergencyAid _ -> False; _ -> True

checkWalkable :: MapSpec -> Tile -> Either SpaceError ()
checkWalkable spec tile = do
  checkTile spec tile
  let terrain = terrainAt spec tile
  unless (walkable terrain) (Left (IllegalTerrain tile terrain))

startPlacement :: Content -> Inventory -> EntityId -> SpatialState -> Either SpaceError SpatialState
startPlacement content inventory ident state = do
  placement <- lookupPlacement ident state
  unless (placementStage placement == PlanReserved) (Left InvalidPlacementStage)
  validatePlacement content inventory state placement
  updateStage ident BuildingSite state

completePlacement :: Content -> Inventory -> EntityId -> SpatialState -> Either SpaceError SpatialState
completePlacement content inventory ident state = do
  placement <- lookupPlacement ident state
  unless (placementStage placement == BuildingSite) (Left InvalidPlacementStage)
  validatePlacement content inventory state placement
  next <- updateStage ident Built state
  pure $ case placementShape placement of
    RoadShape tile -> refreshCachePorts next {spatialRoads = S.insert tile (spatialRoads next)}
    _ -> next

removePlacement :: EntityId -> SpatialState -> Either SpaceError SpatialState
removePlacement ident state = do
  placement <- lookupPlacement ident state
  when (placementStage placement == Built) (Left InvalidPlacementStage)
  revision <- if placementStage placement == BuildingSite then increment (spatialBlockingRevision state) else Right (spatialBlockingRevision state)
  pure state {spatialPlacements = M.delete ident (spatialPlacements state), spatialBlockingRevision = revision}

lookupPlacement :: EntityId -> SpatialState -> Either SpaceError Placement
lookupPlacement ident state = maybe (Left (PlacementMissing ident)) Right (M.lookup ident (spatialPlacements state))

increment :: Word64 -> Either SpaceError Word64
increment n = if n == maxBound then Left SpatialCounterOverflow else Right (n + 1)

updateStage :: EntityId -> PlacementStage -> SpatialState -> Either SpaceError SpatialState
updateStage ident stage state = do
  placement <- lookupPlacement ident state
  revision <- increment (placementRevision placement)
  blockingRevision <- increment (spatialBlockingRevision state)
  pure state {spatialPlacements = M.insert ident (placement {placementStage = stage, placementRevision = revision}) (spatialPlacements state), spatialBlockingRevision = blockingRevision}

cacheEligible :: Content -> SpatialState -> CacheContext -> Tile -> Either SpaceError ()
cacheEligible content state context tile = do
  checkTile (spatialMap state) (cacheOrigin context)
  checkTile (spatialMap state) tile
  unless (manhattan (cacheOrigin context) tile <= 16) (Left (InvalidCacheContext "outside radius 16"))
  occupied <- reservedTiles content state
  ports <- portTiles content state
  case M.lookup tile occupied of
    Just ident -> case M.lookup ident (spatialPlacements state) of
      Just p | placementShape p == RoadShape tile && placementStage p == Built -> pure ()
      _ -> Left (FootprintConflict tile ident)
    Nothing -> pure ()
  when (S.member tile (sourceTiles state)) (Left (SourceConflict tile))
  case cacheReason context of
    TransportReturn arrival -> do
      unless
        (tile == arrival && cacheOrigin context == arrival && S.member arrival (spatialRoads state))
        (Left (InvalidCacheContext "transport return requires its arrival road node"))
      checkWalkable (spatialMap state) tile
    EmergencyAid ruin ->
      unless
        (tile == ruin && cacheOrigin context == ruin && M.lookup ruin (spatialDepotRuins state) == Just (cacheColony context))
        (Left (InvalidCacheContext "aid requires a registered depot ruin in its colony"))
    _ -> do
      checkWalkable (spatialMap state) tile
      when (S.member tile (spatialRoads state)) (Left (RoadConflict tile))
      when (S.member tile ports) (Left (PortConflict tile))
  case M.lookup tile (spatialCaches state) of
    Just cache | cacheOwnerColony cache /= cacheColony context -> Left (ForeignCache tile (cacheOwnerColony cache))
    _ -> Right ()

cacheCandidates :: Content -> SpatialState -> CacheContext -> [Tile]
cacheCandidates content state context = filter eligible $ sortOn (\t -> (manhattan origin t, tileIndex t)) candidates
  where
    origin@(Tile x y) = cacheOrigin context
    candidates = case cacheReason context of
      TransportReturn arrival -> [arrival]
      EmergencyAid ruin -> [ruin]
      _ -> [Tile a b | b <- [y - 16 .. y + 16], a <- [x - 16 .. x + 16], abs (a - x) + abs (b - y) <= 16]
    eligible tile = case cacheEligible content state context tile of Right () -> True; _ -> False

cacheRoadPort :: SpatialState -> Tile -> Maybe Tile
cacheRoadPort state tile = case sortOn tileIndex [road | road <- S.toList (spatialRoads state), manhattan tile road <= 1] of
  [] -> Nothing
  roads -> if S.member tile (spatialRoads state) then Just tile else Just (head roads)

refreshCachePorts :: SpatialState -> SpatialState
refreshCachePorts state = state {spatialOwnerLocations = foldr add (spatialOwnerLocations state) (M.toList (spatialCaches state))}
  where
    add (tile, cache) = M.insert (cacheOwner cache) (OwnerLocation tile (cacheRoadPort state tile))

-- This action and the physical transfer MUST run in the same runInventory call.
-- A downstream NoCapacity rolls back fresh storage IDs and all spatial results.
ensureGroundCache :: Content -> CacheContext -> Tile -> SpatialState -> I.InventoryTx (Owner, SpatialState)
ensureGroundCache content context tile state = do
  either (I.throwTx . spaceFailure) pure (cacheEligible content state context tile)
  inventory <- get
  let EntityId colonyId = cacheColony context
  I.require (colonyId > 0 && colonyId < invNextId inventory) (spaceFailure (UnallocatedSpatialId (cacheColony context)))
  case M.lookup tile (spatialCaches state) of
    Just cache -> do
      either (I.throwTx . spaceFailure) pure (validateCacheStorage inventory tile cache)
      let changed = cache {cacheContexts = S.insert context (cacheContexts cache)}
      pure (cacheOwner cache, refreshCachePorts state {spatialCaches = M.insert tile changed (spatialCaches state)})
    Nothing -> do
      ident <- I.freshId
      let owner = Owner GroundCache ident
          cache = CacheRecord owner (cacheColony context) (S.singleton context)
      I.addStorage owner (Storage cacheCapacity Nothing (cacheColony context))
      pure (owner, refreshCachePorts state {spatialCaches = M.insert tile cache (spatialCaches state)})

validateCacheStorage :: Inventory -> Tile -> CacheRecord -> Either SpaceError ()
validateCacheStorage inventory tile cache = case (cacheOwner cache, M.lookup (cacheOwner cache) (invStorage inventory)) of
  (Owner GroundCache _, Just storage) | storageCapacity storage == cacheCapacity && storageResource storage == Nothing && storageColony storage == cacheOwnerColony cache -> Right ()
  _ -> Left (InvalidCacheStorage tile)

spaceFailure :: SpaceError -> Failure
spaceFailure = InvalidReference . ("Spatial: " ++) . show

-- Optional commit boundary for callers without a larger World transaction.
-- Geometry and inventory both become visible only after both validators pass.
runSpatialTransaction :: Content -> SpatialState -> (SpatialState -> I.InventoryTx (a, SpatialState)) -> Inventory -> Either Failure ((a, SpatialState), Inventory)
runSpatialTransaction content before action = I.runInventory $ do
  (result, after) <- action before
  inventory <- get
  either (I.throwTx . spaceFailure) pure (validateSpatial content inventory after)
  pure (result, after)

registerOwnerLocation :: Inventory -> Owner -> OwnerLocation -> SpatialState -> Either SpaceError SpatialState
registerOwnerLocation inventory owner location state = do
  unless (M.member owner (invStorage inventory)) (Left (InvalidOwnerLocation owner))
  validateOwnerLocation state owner location
  case ownerRoadConnector location of
    Just connector -> case M.lookup connector (spatialCaches state) of
      Just cache | any ordinary (S.toList (cacheContexts cache)) -> Left (CacheConflict connector)
      _ -> pure ()
    Nothing -> pure ()
  pure state {spatialOwnerLocations = M.insert owner location (spatialOwnerLocations state)}
  where
    ordinary context = case cacheReason context of ConstructionReturn _ -> True; RecipeReturn _ -> True; _ -> False

validateOwnerLocation :: SpatialState -> Owner -> OwnerLocation -> Either SpaceError ()
validateOwnerLocation state owner location = do
  checkTile (spatialMap state) (ownerTile location)
  case ownerRoadConnector location of
    Nothing -> pure ()
    Just road -> do
      checkTile (spatialMap state) road
      unless (manhattan (ownerTile location) road <= 1) (Left (InvalidOwnerLocation owner))

-- Validate before committing a terrain change: an occupied cache cannot be
-- stranded by silently turning its tile into cliff/source/nonwalkable terrain.
setTerrainTile :: Content -> Inventory -> Tile -> Terrain -> SpatialState -> Either SpaceError SpatialState
setTerrainTile content inventory tile terrain state = do
  checkTile (spatialMap state) tile
  let candidate = state {spatialMap = (spatialMap state) {mapTerrain = M.insert tile terrain (mapTerrain (spatialMap state))}}
  validateSpatial content inventory candidate
  pure candidate

validateSpatial :: Content -> Inventory -> SpatialState -> Either SpaceError ()
validateSpatial content inventory state = do
  validateMap (spatialMap state)
  forM_ (M.toList (spatialDepotRuins state)) $ \(tile, colony@(EntityId n)) -> do
    checkTile (spatialMap state) tile
    unless (n > 0 && n < invNextId inventory) (Left (UnallocatedSpatialId colony))
  forM_ (M.toList (spatialSources state)) $ \(ident, region) -> do
    unless (ident == sourceRegionId region) (Left (InvalidSource ident "map key mismatch"))
    validateSourceRegion content inventory (spatialMap state) region
  let regions = M.elems (spatialSources state)
  forM_ [(a, b) | a <- regions, b <- regions, sourceRegionId a < sourceRegionId b] $ \(a, b) ->
    unless (S.null (S.intersection (rectTiles (sourceRegionBounds a)) (rectTiles (sourceRegionBounds b)))) (Left (InvalidSource (sourceRegionId b) "overlapping source regions"))
  forM_ (M.toList (spatialPlacements state)) $ \(ident, placement) -> do
    unless (ident == placementId placement) (Left (InvalidSpatialState "placement key mismatch"))
    validatePlacement content inventory state placement
    case placementShape placement of
      RoadShape tile | placementStage placement == Built -> unless (S.member tile (spatialRoads state)) (Left (InvalidSpatialState "built road absent from road layer"))
      _ -> pure ()
  forM_ (S.toList (spatialRoads state)) $ \tile -> do
    checkWalkable (spatialMap state) tile
    when (S.member tile (sourceTiles state)) (Left (SourceConflict tile))
  forM_ (S.toList (S.union (spatialPipes state) (spatialWires state))) (checkTile (spatialMap state))
  let owners = map cacheOwner (M.elems (spatialCaches state))
  unless (length owners == S.size (S.fromList owners)) (Left (InvalidSpatialState "cache owner used at multiple tiles"))
  forM_ (M.toList (spatialCaches state)) $ \(tile, cache) -> do
    validateCacheStorage inventory tile cache
    unless (not (S.null (cacheContexts cache))) (Left (InvalidCacheContext "cache has no authorized context"))
    forM_ (S.toList (cacheContexts cache)) $ \context -> do
      unless (cacheColony context == cacheOwnerColony cache) (Left (ForeignCache tile (cacheOwnerColony cache)))
      cacheEligible content state context tile
    unless
      (M.lookup (cacheOwner cache) (spatialOwnerLocations state) == Just (OwnerLocation tile (cacheRoadPort state tile)))
      (Left (InvalidOwnerLocation (cacheOwner cache)))
  let spatialCacheOwners = S.fromList owners
      physicalCacheOwners = S.fromList [owner | owner@(Owner GroundCache _) <- M.keys (invStorage inventory)]
  unless (spatialCacheOwners == physicalCacheOwners) (Left (InvalidSpatialState "unmapped physical GroundCache storage"))
  forM_ (M.toList (spatialOwnerLocations state)) $ \(owner, location) -> do
    unless (M.member owner (invStorage inventory)) (Left (InvalidOwnerLocation owner))
    validateOwnerLocation state owner location
