{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- Normative S01 grants, separate from the legacy four-colony subsystem fixture.
-- The frozen layout is authored once; play never calls a packing/random routine.
module Colony.S01Fixture where

import Colony.Construction qualified as C
import Colony.Content
import Colony.Inventory
import Colony.M1Infrastructure
import Colony.M1Rules
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.Power
import Colony.Space qualified as Space
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.DeepSeq (NFData)
import Control.Monad (foldM, forM, forM_, replicateM, void)
import Control.Monad.State.Strict (get)
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import GHC.Generics (Generic)

data S01Descriptor = S01Descriptor
  { s01Colony :: !EntityId,
    s01Depot :: !EntityId,
    s01Warehouses :: ![Owner],
    s01Pantry :: !Owner,
    s01Pump :: !EntityId,
    s01Farm :: !EntityId,
    s01Kitchen :: !EntityId,
    s01Carts :: ![EntityId],
    s01ShiftResidents :: !(M.Map Integer [EntityId]),
    s01Builders :: ![EntityId],
    s01Aquifer :: !EntityId,
    s01Housing :: ![EntityId]
  }
  deriving (Eq, Show, Read, Generic, NFData)

s01Tick :: SimTick
s01Tick = SimTick 7200

s01Layouts :: [(String, Space.Tile)]
s01Layouts =
  [ ("depot", Space.Tile 56 40),
    ("warehouse", Space.Tile 61 40),
    ("warehouse", Space.Tile 66 40),
    ("warehouse", Space.Tile 71 40),
    ("housing", Space.Tile 76 40),
    ("housing", Space.Tile 80 40),
    ("housing", Space.Tile 84 40),
    ("housing", Space.Tile 88 40),
    ("pantry", Space.Tile 92 40),
    ("solar", Space.Tile 96 40),
    ("battery", Space.Tile 101 40),
    ("farm", Space.Tile 105 40),
    ("kitchen", Space.Tile 112 40),
    ("hand_pump", Space.Tile 60 60)
  ]

s01NaturalLayouts :: [(String, Resource, Integer, Space.Tile)]
s01NaturalLayouts =
  [ ("aquifer", Water, 20000000, Space.Tile 60 52),
    ("ore_deposit", Ore, 10000000, Space.Tile 12 12),
    ("stone_deposit", Stone, 10000000, Space.Tile 20 92),
    ("sand_deposit", Sand, 10000000, Space.Tile 92 100)
  ]

s01Grants :: M.Map Resource Integer
s01Grants =
  M.fromList
    [ (Water, 480000),
      (Ration, 240000),
      (Metal, 600000),
      (Stone, 800000),
      (Glass, 100000),
      (Parts, 200),
      (Circuit, 40),
      (Tools, 20),
      (Fuel, 120000),
      (Biomass, 40000),
      (Medicine, 40)
    ]

s01RoadTiles :: Content -> Either Failure (S.Set Space.Tile)
s01RoadTiles content = do
  ports <- mapM placementPort [layout | layout@(name, _) <- s01Layouts, name /= "hand_pump"]
  let north = S.fromList ([Space.Tile x 49 | x <- [56 .. 113]] ++ [Space.Tile x y | Space.Tile x start <- ports, y <- [start .. 49]])
      pump = S.fromList ([Space.Tile 56 y | y <- [49 .. 64]] ++ [Space.Tile x 64 | x <- [56 .. 60]] ++ [Space.Tile 60 y | y <- [62 .. 64]])
  pure (S.union north pump)
  where
    placementPort (name, tile) = do
      building <- either (Left . InvalidReference) Right (lookupBuilding content name)
      (_, geometry) <- either (Left . Space.spaceFailure) Right (Space.footprintGeometry (buildingFootprint building) tile Space.R0)
      pure (Space.roadConnector geometry)

s01Fixture :: Content -> Either Failure (S01Descriptor, World)
s01Fixture = s01FixtureWithRuleset "red-dune-reference-6"

s01FixtureWithRuleset :: String -> Content -> Either Failure (S01Descriptor, World)
s01FixtureWithRuleset rules content = do
  roads <- s01RoadTiles content
  ((descriptor, space, construction, sites, needs, grids, siteGrids, transport), inventory) <- runInventory (build roads) (emptyInventory content)
  facilities <-
    mapM
      ( \placement -> case Space.placementShape placement of
          Space.BuildingShape name _ _ -> newFacility content (Space.placementId placement) name
          _ -> Left (InvalidReference "initial building layout contains road plan")
      )
      (M.elems (Space.spatialPlacements space))
  let meaningful = [facility | facility <- facilities, facilityId facility `elem` M.keys sites ++ concatMap (\g -> map solarId (gridSolar g) ++ map batteryId (gridBatteries g)) (M.elems grids)]
      state =
        M1State
          space
          (W.initialWorkforce s01Tick needs)
          construction
          (M.singleton (s01Colony descriptor) (s01Depot descriptor))
          (M.fromList [(residentId resident, BedAssignment housing slot) | (resident, (housing, slot)) <- zip (M.elems (needsResidents needs)) [(home, n) | home <- s01Housing descriptor, n <- [0 .. 9]]])
          500
          "S01-short-v1"
          m1RuleVersion
          m1RuleHash
          M.empty
      world =
        (initialWorld content)
          { worldRuleset = rules,
            worldMode = Paused,
            simTick = s01Tick,
            worldInventory = inventory,
            worldSites = sites,
            worldNeeds = needs,
            worldPowerGrids = grids,
            worldSiteGrids = siteGrids,
            worldTransport = transport,
            worldMaintenance = MaintenanceState (M.fromList [(facilityId facility, facility) | facility <- meaningful]) M.empty,
            worldM1 = Just state
          }
  validateWorld world
  pure (descriptor, world)
  where
    tx = TxId 1 1 (BoundarySeq 0) P0 0
    spatial = either (throwTx . Space.spaceFailure) pure
    build roads = do
      colony <- freshId
      sources <- forM s01NaturalLayouts $ \(kind, resource, quantity, origin) -> do
        ident <- addDeposit kind resource quantity
        pure (ident, Space.SourceRegion ident kind resource (Space.Rect origin 8 8))
      let initial =
            (Space.emptySpatial (Space.MapSpec "s01-d0-rowpack-v1" 1 (Space.Rect (Space.Tile 0 0) 128 128) (Space.Tile 192 224) M.empty))
              { Space.spatialSources = M.fromList sources
              }
          aquifer = fst (head sources)
      space <- foldM (seedBuilding colony aquifer) initial s01Layouts
      let placements = M.elems (Space.spatialPlacements space)
          named name = [Space.placementId p | p <- placements, case Space.placementShape p of Space.BuildingShape n _ _ -> name == n; _ -> False]
      depot <- single "depot" (named "depot")
      pantryId <- single "pantry" (named "pantry")
      pump <- single "hand_pump" (named "hand_pump")
      farm <- single "farm" (named "farm")
      kitchen <- single "kitchen" (named "kitchen")
      solar <- single "solar" (named "solar")
      battery <- single "battery" (named "battery")
      let warehouses = map (Owner Warehouse) (named "warehouse"); pantry = Owner Pantry pantryId
      forM_ warehouses $ \owner -> addStorage owner (Storage 2000000 Nothing colony)
      addStorage pantry (Storage 400000 Nothing colony)
      forM_ [pump, farm, kitchen] $ \ident -> do
        addStorage (Owner MachineInput ident) (Storage 400000 Nothing colony)
        addStorage (Owner MachineOutput ident) (Storage 400000 Nothing colony)
      let recipes = [(pump, "hand_water", True), (farm, "grow", False), (kitchen, "cook", False)]
      sites <- forM recipes $ \(ident, recipeName, enabled) -> do
        recipe <- either (throwTx . InvalidReference) pure (lookupRecipe content recipeName)
        building <- either (throwTx . InvalidReference) pure (lookupBuilding content (recipeBuilding recipe))
        pure
          ( ident,
            Site
              ident
              recipeName
              (Owner MachineInput ident)
              (Owner MachineOutput ident)
              (if ident == pump then M.singleton "aquifer" aquifer else M.empty)
              (buildingWorkers building)
              enabled
          )
      current <- get
      located <-
        foldM
          ( \s (owner, _) -> do
              let Owner _ ident = owner
              placement <- maybe (throwTx MissingOwner) pure (M.lookup ident (Space.spatialPlacements s))
              (_, geometry) <- spatial (Space.placementGeometry content placement)
              location <- maybe (throwTx MissingOwner) (\p -> pure (Space.OwnerLocation (Space.boundaryPort p) (Just (Space.roadConnector p)))) geometry
              spatial (Space.registerOwnerLocation current owner location s)
          )
          space
          (M.toAscList (invStorage current))
      let anchors = [Space.boundaryPort p | placement <- placements, Right (_, Just p) <- [Space.placementGeometry content placement]]
          mapped = located {Space.spatialRoads = roads, Space.spatialWires = S.union roads (S.fromList anchors)}
          costs = M.fromList [(Space.placementId placement, buildingCost building) | placement <- placements, Space.BuildingShape name _ _ <- [Space.placementShape placement], Just building <- [M.lookup name (contentBuildings content)]]
          construction = C.emptyConstruction {C.constructionAccountedCosts = costs}
      (_, connected) <- either throwTx pure (syncInfrastructure content current (BoundarySeq 0) construction mapped emptyTransport)
      grid <- freshId
      let power = PowerGrid grid [Solar solar 100] [] [Battery battery 360000000 0 100] (M.singleton InitialEnergy 360000000)
      carts <-
        foldM
          ( \(ids, tr) _ -> do
              home <- case warehouses of owner : _ -> pure owner; _ -> throwTx MissingOwner
              node <- port home tr
              (ident, next) <- addTransportVehicle CarrierCart colony home home node s01Tick tr
              pure (ids ++ [ident], next)
          )
          ([], connected)
          [1 .. 3 :: Int]
      people <- replicateM 40 (freshId >>= \ident -> pure (newResident ident colony))
      let shifts = M.fromListWith (++) [(residentShift resident, [residentId resident]) | resident <- reverse people]
          builders = take 2 (drop 11 (M.findWithDefault [] 1 shifts))
      require (length builders == 2) (InvariantViolation "S01 daytime construction crew missing")
      grant pantry Water 120000
      grant pantry Ration 60000
      forM_ (sortOn (resourceKey . fst) (M.toList s01Grants)) $ \(resource, quantity) -> do
        let rest = quantity - if resource == Water then 120000 else if resource == Ration then 60000 else 0
        placeGrant warehouses resource rest
      let needs = NeedsState (M.fromList [(residentId resident, resident) | resident <- people]) (M.singleton colony [pantry])
          descriptor = S01Descriptor colony depot warehouses pantry pump farm kitchen (fst carts) shifts builders aquifer (named "housing")
      pure (descriptor, mapped, construction, M.fromList sites, needs, M.singleton grid power, M.fromList [(farm, grid), (kitchen, grid)], snd carts)
    single _ [ident] = pure ident
    single name _ = throwTx (InvalidReference ("S01 layout needs one " ++ name))
    seedBuilding colony aquifer space (name, tile) = do
      ident <- freshId
      inventory <- get
      (_, planned) <- spatial (Space.reserveBuildingPlan content inventory ident colony name tile Space.R0 (if name == "hand_pump" then Just aquifer else Nothing) space)
      started <- spatial (Space.startPlacement content inventory ident planned)
      spatial (Space.completePlacement content inventory ident started)
    grant owner resource quantity = do
      inventory <- get
      let expiry = fmap (\life -> let SimTick start = s01Tick in SimTick (start + life)) (M.findWithDefault Nothing resource (invShelf inventory))
      void (mintLot tx InitialGrant Nothing resource quantity owner s01Tick expiry "S01 normative portable grant")
    placeGrant _ _ 0 = pure ()
    placeGrant [] _ _ = throwTx NoCapacity
    placeGrant (owner : rest) resource amount = do
      inventory <- get
      let count = min amount (freeWeight inventory owner `div` weightOf inventory resource 1)
      if count > 0 then grant owner resource count else pure ()
      placeGrant rest resource (amount - count)

-- Suggested explicit player commands. No automatic grants, hidden production or
-- mutation occurs when this list is inspected; each command goes through Arena.
s01RosterCommands :: S01Descriptor -> [Command]
s01RosterCommands descriptor =
  concat
    [ [ AssignWorkers (W.OperateFacility (s01Farm descriptor)) shift (take 4 residents),
        AssignWorkers (W.OperateFacility (s01Kitchen descriptor)) shift (take 2 (drop 4 residents)),
        AssignWorkers (W.OperateFacility (s01Pump descriptor)) shift (take 2 (drop 6 residents)),
        AssignWorkers (W.OperateFacility pantry) shift (take 1 (drop 8 residents))
      ]
        ++ [AssignWorkers (W.DriveVehicle vehicle) shift (take 1 (drop (9 + n) residents)) | (n, vehicle) <- zip [0 ..] (take 2 (s01Carts descriptor))]
    | (shift, residents) <- M.toAscList (s01ShiftResidents descriptor)
    ]
  where
    Owner _ pantry = s01Pantry descriptor
