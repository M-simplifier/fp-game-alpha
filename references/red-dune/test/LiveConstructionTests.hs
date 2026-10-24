module LiveConstructionTests (main, liveConstructionTests) where

import Colony.Codec ()
import Colony.Codec.Value (decodeValue, encodeValue)
import Colony.Construction qualified as C
import Colony.Content
import Colony.ContentCodec (contentIdentity, knownV1ContentId)
import Colony.Inventory
import Colony.Jobs
import Colony.KnownCatalog (knownCatalogV1)
import Colony.M1Commands (reconcileM1Infrastructure)
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.Power
import Colony.S01Fixture
import Colony.Scheduler (pureStep)
import Colony.Space qualified as S
import Colony.Transport (transportPorts)
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Monad (foldM, forM_, unless, void)
import Data.Map.Strict qualified as M
import Data.Set qualified as Set

assert :: String -> Bool -> IO ()
assert label ok = unless ok (ioError (userError ("LIVE CONSTRUCTION: " ++ label)))

must :: (Show e) => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

isLeft :: Either a b -> Bool
isLeft Left {} = True
isLeft _ = False

m1 :: World -> M1State
m1 = maybe (error "test fixture lacks M1") id . worldM1

-- Explicit isolated acceptance fixture: jobs are two ticks long, retaining
-- complete real costs, worker counts, footprints and maintenance semantics.
content :: Content
content =
  knownCatalogV1
    { contentBuildings = M.map (\b -> b {buildingBuildWorkTicks = 2}) (contentBuildings knownCatalogV1),
      contentRecipes = M.map (\r -> r {recipeWorkTicks = 2}) (contentRecipes knownCatalogV1)
    }

step :: Bool -> [Command] -> [ManagementEvent] -> World -> IO (World, ColonyOutput)
step advance commands management world = do
  let epoch = participantEpoch (worldParticipants world M.! 1)
      highest = M.findWithDefault 0 (1, epoch) (worldHighWater world)
      ordered = [OrderedCommand ordinal (CommandId 1 1 epoch (highest + ordinal + 1)) command | (ordinal, command) <- zip [0 ..] commands]
      header = BoundaryHeader 1 1 (boundarySeq world) advance (worldAuthority world) (worldRuleset world)
      result = pureStep (Boundary header ordered management) world
  assert ("no fault " ++ show (snd result)) (null (outputDiagnostics (snd result)))
  must "committed world" (validateWorld (fst result))
  pure result

accept :: Bool -> [Command] -> [ManagementEvent] -> World -> IO World
accept advance commands management world = do
  (next, out) <- step advance commands management world
  assert ("commands applied " ++ show (outputReceipts out)) (all (\r -> case receiptOutcome r of Applied _ -> True; _ -> False) (outputReceipts out))
  pure next

fixture :: String -> IO (S01Descriptor, World, S.PlacementShape)
fixture name = do
  (descriptor, original) <- must "S01" (s01Fixture knownCatalogV1)
  building <- must "building" (lookupBuilding content name)
  let origin = case name of "pump" -> S.Tile 64 60; "mine" -> S.Tile 12 20; "quarry" -> S.Tile 20 100; _ -> S.Tile 30 40
      shape = S.BuildingShape name origin S.R0
  (_, geometry) <- must "port" (S.footprintGeometry (buildingFootprint building) origin S.R0)
  let S.Tile px py = S.roadConnector geometry
      state = m1 original
      roadTiles = case name of
        "pump" -> [S.Tile px y | y <- [py .. 64]] ++ [S.Tile x 64 | x <- [56 .. px]]
        "quarry" -> [S.Tile x py | x <- [18 .. px]] ++ [S.Tile 18 y | y <- [49 .. py]] ++ [S.Tile x 49 | x <- [18 .. 56]]
        _ -> [S.Tile px y | y <- [py .. 49]] ++ [S.Tile x 49 | x <- [px .. 56]]
      roads = Set.fromList roadTiles
      spatial = (m1Space state) {S.spatialRoads = Set.union roads (S.spatialRoads (m1Space state))}
      homeless = head (M.keys (needsResidents (worldNeeds original)))
      needs = if name == "housing" then (worldNeeds original) {needsResidents = M.adjust (\r -> r {residentBed = False}) homeless (needsResidents (worldNeeds original))} else worldNeeds original
      beds = if name == "housing" then M.delete homeless (m1Beds state) else m1Beds state
      altered = original {worldContent = content, worldRuleset = C.liveConstructionRuleset, worldNeeds = needs, worldM1 = Just state {m1Space = spatial, m1Beds = beds}}
  connected <- must "connect fixture roads" (reconcileM1Infrastructure altered)
  must "fixture valid" (validateWorld connected)
  pure (descriptor, connected, shape)

place :: S01Descriptor -> S.PlacementShape -> World -> IO (EntityId, World)
place descriptor shape world = do
  (planned, out) <- step False [PlaceConstructionPlan (s01Colony descriptor) shape 2 Nothing] [] world
  case [ident | receipt <- outputReceipts out, Applied (Just ident) <- [receiptOutcome receipt]] of
    [ident] -> pure (ident, planned)
    _ -> ioError (userError ("construction not admitted: " ++ show out))

fund :: EntityId -> World -> IO World
fund ident world = do
  let job = C.constructionJobs (m1Construction (m1 world)) M.! ident
      tx = TxId 1 1 (boundarySeq world) P0 500
  (_, inventory) <-
    must
      "explicit test material grant"
      ( runInventory
          ( forM_ (M.toList (C.constructionCost (C.constructionSnapshot job))) $ \(r, q) ->
              void (mintLot tx InitialGrant Nothing r q (C.constructionInput job) (simTick world) Nothing "isolated construction test grant")
          )
          (worldInventory world)
      )
  let next = world {worldInventory = inventory}
  must "funded fixture" (validateWorld next)
  pure next

build :: String -> IO (S01Descriptor, EntityId, World)
build name = fixture name >>= \(descriptor, initial, shape) -> buildFrom name descriptor initial shape

buildFrom :: String -> S01Descriptor -> World -> S.PlacementShape -> IO (S01Descriptor, EntityId, World)
buildFrom name descriptor initial shape = do
  (ident, planned) <- place descriptor shape initial
  resumed <- accept False [] [ResumeWorld] planned
  missing <- accept True [] [] resumed
  assert (name ++ " does not complete without cost") (C.constructionProgress (getJob ident missing) == 0)
  funded <- fund ident missing
  waiting <- accept True [] [] funded
  assert (name ++ " cannot use anonymous workers") (C.constructionPhase (getJob ident waiting) /= C.ConstructionRunning)
  let builders = take 2 (drop 11 (s01ShiftResidents descriptor M.! 0))
  staffed <- accept False [AssignWorkers (W.ConstructSite ident) 0 builders] [] waiting
  working <- accept True [] [] staffed
  assert (name ++ " exact escrow") (physicalAt (Owner ConstructionEscrow (C.constructionJobId (getJob ident working))) (worldInventory working) == C.constructionCost (C.constructionSnapshot (getJob ident working)))
  let claims = W.workforceClaims (m1Workforce (m1 working))
  assert (name ++ " claims actual two builders") (length (filter (== W.ConstructSite ident) (M.elems claims)) == 2)
  finished <- accept True [] [] working
  assert (name ++ " completed once") (C.constructionPhase (getJob ident finished) == C.ConstructionCompleted && C.constructionTerminalCount (getJob ident finished) == 1)
  assert (name ++ " builders retired") (W.ConstructSite ident `notElem` M.elems (W.workforceClaims (m1Workforce (m1 finished))))
  forM_ (M.toList (C.constructionCost (C.constructionSnapshot (getJob ident finished)))) $ \(r, q) ->
    assert (name ++ " exact material ledger " ++ show r) (M.findWithDefault 0 (r, ConstructionConsumed) (invLedger (worldInventory finished)) == q)
  pure (descriptor, ident, finished)

getJob :: EntityId -> World -> C.ConstructionJob
getJob ident world = C.constructionJobs (m1Construction (m1 world)) M.! ident

physicalAt :: Owner -> Inventory -> M.Map Resource Integer
physicalAt owner inventory = M.fromListWith (+) [(lotResource lot, qtyValue (lotQty lot)) | lot <- M.elems (invLots inventory), lotOwner lot == owner]

liveConstructionTests :: IO ()
liveConstructionTests = do
  digest <- must "digest" (contentIdentity content)
  forM_ C.liveBuildablePrototypes $ \name -> do
    snap <- must ("live snapshot " ++ name) (C.snapshotForRuleset C.liveConstructionRuleset content (S.BuildingShape name (S.Tile 30 40) S.R0))
    assert "live snapshot current digest" (C.constructionContentId snap == digest && C.constructionRuleVersion snap == 2)
    assert "unknown predecessor snapshot rejected" (isLeft (C.validateConstructionSnapshot content (S.BuildingShape name (S.Tile 30 40) S.R0) snap {C.constructionContentId = knownV1ContentId}))
  assert "archive API rejects expanded building" (isLeft (C.snapshotFor knownCatalogV1 (S.BuildingShape "farm" (S.Tile 30 40) S.R0)))
  assert "unimplemented generator rejected" (isLeft (C.snapshotForRuleset C.liveConstructionRuleset content (S.BuildingShape "generator" (S.Tile 30 40) S.R0)))
  forM_ ["farm", "kitchen", "warehouse", "pantry", "tank", "solar", "battery", "housing", "refinery", "pump", "mine", "quarry"] $ \name -> do
    (descriptor, ident, finished) <- build name
    let inventory = worldInventory finished; colony = s01Colony descriptor
    case name of
      "warehouse" -> assert "warehouse capacity/physical port" (M.lookup (Owner Warehouse ident) (invStorage inventory) == Just (Storage 2000000 Nothing colony) && M.member (Owner Warehouse ident) (transportPorts (worldTransport finished)))
      "pantry" -> assert "pantry joins actual needs service" (Owner Pantry ident `elem` M.findWithDefault [] colony (needsPantries (worldNeeds finished)))
      "tank" -> assert "tank is real typed water capacity" (M.lookup (Owner Tank ident) (invStorage inventory) == Just (Storage 1000000 (Just Water) colony))
      "solar" -> do
        assert "solar is an actual device" (ident `elem` concatMap (map solarId . gridSolar) (M.elems (worldPowerGrids finished)))
        assert "solar maintenance physical colony" (maintenanceTargetColony finished ident == Just colony)
        must "solar local maintenance source accepted" (validateMaintenanceOwners finished ident (head (s01Warehouses descriptor)) (head (s01Warehouses descriptor)))
      "battery" -> assert "new battery has no free energy" (any (\b -> batteryId b == ident && batteryStoredJ b == 0) (concatMap gridBatteries (M.elems (worldPowerGrids finished))))
      "housing" -> do
        assert "housing creates an actual built footprint" (maybe False ((== S.Built) . S.placementStage) (M.lookup ident (S.spatialPlacements (m1Space (m1 finished)))))
        assert "new housing actually beds unhoused resident" (any ((== ident) . bedBuilding) (M.elems (m1Beds (m1 finished))))
      _ -> do
        site <- must "production facet" (maybe (Left TargetGone) Right (M.lookup ident (worldSites finished)))
        assert "production endpoints" (siteInput site == Owner MachineInput ident && siteOutput site == Owner MachineOutput ident)
        assert "maintenance installed" (M.member ident (maintenanceFacilities (worldMaintenance finished)))
        recipe <- must "recipe" (lookupRecipe content (siteRecipe site))
        building <- must "recipe building" (lookupBuilding content (recipeBuilding recipe))
        assert "powered processing bound to physical grid" (buildingPower building == 0 || M.member ident (worldSiteGrids finished))
        productionWorks descriptor site recipe finished
  sourceTests
  cancellationTests
  isolatedPowerTests
  stagingDecodeTests
  putStrLn "LIVE_CONSTRUCTION PASS: pinned snapshots, optional sources, exact escrow/ledger, named workers, twelve functional completions, powered recipes, storage/service, solar maintenance, zero-energy battery, cancellation rollback, isolated NoPower, canonical staging/resume"

productionWorks :: S01Descriptor -> Site -> Recipe -> World -> IO ()
productionWorks descriptor site recipe world = do
  let tx = TxId 1 1 (boundarySeq world) P0 501
      crew = take (fromInteger (siteWorkers site)) (s01ShiftResidents descriptor M.! 0)
  (_, inventory) <-
    must
      "test process inputs"
      ( runInventory
          ( forM_ (M.toList (recipeInputs recipe)) $ \(r, q) ->
              void (mintLot tx InitialGrant Nothing r q (siteInput site) (simTick world) (fmap (\life -> let SimTick tick = simTick world in SimTick (tick + life)) (M.findWithDefault Nothing r (invShelf (worldInventory world)))) "isolated process test")
          )
          (worldInventory world)
      )
  ready <- accept False [AssignWorkers (W.OperateFacility (siteId site)) 0 crew, OrderProduction (siteId site)] [] world {worldInventory = inventory}
  done <- foldM (\current _ -> accept True [] [] current) ready [1 .. 2 :: Int]
  assert ("new " ++ siteRecipe site ++ " completes functional production") (any (\job -> jobPhase job == Completed && M.lookup (jobId job) (worldJobSites done) == Just (siteId site)) (M.elems (worldJobs done)))
  assert "actual output quantities" (physicalAt (siteOutput site) (worldInventory done) == recipeOutputs recipe)

sourceTests :: IO ()
sourceTests = do
  (descriptor, world, shape) <- fixture "farm"
  let inventory = worldInventory world; space = m1Space (m1 world); colony = s01Colony descriptor; source = s01Aquifer descriptor
  assert "non-extractor cannot bind arbitrary source" (isLeft (runInventory (C.placeConstructionForRuleset C.liveConstructionRuleset content (simTick world) colony shape 2 (Just source) space) inventory))
  assert "extractor without adjacent source rejected" (isLeft (runInventory (C.placeConstructionForRuleset C.liveConstructionRuleset content (simTick world) colony (S.BuildingShape "pump" (S.Tile 30 40) S.R0) 2 Nothing space) inventory))
  let quarrySource = EntityId 10000
      sand = Deposit quarrySource "sand_deposit" Sand (either (error . show) id (mkQty 50000))
  recipe <- must "quarry bound sand recipe" (C.completedRecipe content inventory {invDeposits = M.insert quarrySource sand (invDeposits inventory)} "quarry" (Just quarrySource))
  assert "quarry binds source-compatible recipe" (fmap recipeId recipe == Just "quarry_sand")

cancellationTests :: IO ()
cancellationTests = do
  (descriptor, initial, shape) <- fixture "warehouse"
  (ident, planned) <- place descriptor shape initial
  funded <- fund ident planned
  let builders = take 2 (drop 11 (s01ShiftResidents descriptor M.! 0))
  staffed <- accept False [AssignWorkers (W.ConstructSite ident) 0 builders] [ResumeWorld] funded
  working <- accept True [] [] staffed
  let job = getJob ident working
  (stale, out) <- step False [CancelConstructionPlan ident (C.constructionRevision job - 1)] [] working
  assert "stale cancel is atomic" (worldInventory stale == worldInventory working && worldM1 stale == worldM1 working && all (\r -> case receiptOutcome r of CommandFailed _ -> True; _ -> False) (outputReceipts out))
  cancelled <- accept False [CancelConstructionPlan ident (C.constructionRevision job)] [] stale
  assert "cancel terminal and no warehouse fabricated" (C.constructionPhase (getJob ident cancelled) == C.ConstructionCancelled && not (M.member (Owner Warehouse ident) (invStorage (worldInventory cancelled))))
  assert "cancel restores survivors physically" (all (\r -> M.findWithDefault 0 (r, ConstructionLoss) (invLedger (worldInventory cancelled)) == 25000) [Metal, Stone])

isolatedPowerTests :: IO ()
isolatedPowerTests = do
  (descriptor, original) <- must "isolated initial fixture" (s01Fixture knownCatalogV1)
  let initial = original {worldContent = content, worldRuleset = C.liveConstructionRuleset}
      shape = S.BuildingShape "kitchen" (S.Tile 30 40) S.R0
  must "isolated initial validation" (validateWorld initial)
  (_, ident, built) <- buildFrom "isolated kitchen" descriptor initial shape
  let grid = worldPowerGrids built M.! (worldSiteGrids built M.! ident)
  assert "isolated installation never borrows distant power" (null (gridSolar grid) && null (gridBatteries grid) && M.null (gridEnergyLedger grid))
  site <- must "isolated site" (maybe (Left TargetGone) Right (M.lookup ident (worldSites built)))
  recipe <- must "isolated recipe" (lookupRecipe content (siteRecipe site))
  let tx = TxId 1 1 (boundarySeq built) P0 502
  (_, inventory) <-
    must
      "isolated physical inputs"
      ( runInventory
          ( forM_ (M.toList (recipeInputs recipe)) $ \(r, q) ->
              void (mintLot tx InitialGrant Nothing r q (siteInput site) (simTick built) Nothing "isolated no-power fixture")
          )
          (worldInventory built)
      )
  ordered <- accept False [AssignWorkers (W.OperateFacility ident) 0 (take 2 (s01ShiftResidents descriptor M.! 0)), OrderProduction ident] [] built {worldInventory = inventory}
  blocked <- foldM (\current _ -> accept True [] [] current) ordered [1 .. 3 :: Int]
  assert "isolated processing blocks honestly on NoPower" (any (\job -> M.lookup (jobId job) (worldJobSites blocked) == Just ident && jobProgress job == 0 && jobBlocked job == Just (InvalidReference "NoPower")) (M.elems (worldJobs blocked)))

stagingDecodeTests :: IO ()
stagingDecodeTests = do
  (descriptor, initial, shape) <- fixture "warehouse"
  (ident, planned) <- place descriptor shape initial
  supplied <- fund ident planned
  let builders = take 2 (drop 11 (s01ShiftResidents descriptor M.! 0))
  ready <- accept False [AssignWorkers (W.ConstructSite ident) 0 builders] [ResumeWorld] supplied
  running <- accept True [] [] ready
  bytes <- must "live staging encode" (encodeValue running)
  decoded <- must "live staging decode" (decodeValue bytes)
  assert "new content and active construction roundtrip exactly" (decoded == running)
  must "staged world validates" (validateWorld decoded)
  expected <- accept True [] [] running
  actual <- accept True [] [] decoded
  assert "restored active construction resumes identically" (actual == expected)

main :: IO ()
main = liveConstructionTests
