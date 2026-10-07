{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module RedDune.Game where

import Colony.Construction qualified as C
import Colony.Content (Content, buildingFootprint, lookupBuilding)
import Colony.JSON qualified as J
import Colony.M1State
import Colony.Needs
import Colony.Presentation (arr, encodeJSON, num, obj, ownerJSON, presentation, previewPlanJSON, receiptJSON, str)
import Colony.S01Fixture
import Colony.Scheduler (pureStep)
import Colony.Session (validUUIDv4)
import Colony.Space qualified as Space
import Colony.Transport (incomingDeliveryQuantity)
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.DeepSeq (NFData, force)
import Control.Monad (foldM, unless)
import Data.List (find)
import Data.Map.Strict qualified as M
import Data.Sequence qualified as Q
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Policies
import RedDune.Protocol

-- Player-authored scenery occupies real map tiles and survives checkpoints.
-- It changes no production, nutrition, travel cost or campaign evidence.
data PlaceKind = PlaceSquare | PlaceBench | PlaceGarden | PlaceLantern
  deriving (Eq, Ord, Show, Read, Enum, Bounded, Generic, NFData)

data GameState = GameState
  { gameWorld :: !World,
    gameDescriptor :: !S01Descriptor,
    gamePack :: !ContentPack,
    gameStagedPack :: !(Maybe ContentPack),
    gameCampaign :: !CampaignState,
    gamePolicies :: !Policies,
    gameRevision :: !Word64,
    gameBuildQueue :: ![Space.PlacementShape],
    gameNotices :: ![String],
    gamePlaces :: !(M.Map Space.Tile (PlaceKind, Space.Rotation)),
    gameDiningPlaces :: !(M.Map Space.Tile Space.Rotation)
  }
  deriving (Eq, Show, Read, Generic, NFData)

startGame :: String -> ContentPack -> Either String GameState
startGame = startGameWith (s01FixtureWithRuleset "red-dune-live-1")

startGameWith :: (Content -> Either Failure (S01Descriptor, World)) -> String -> ContentPack -> Either String GameState
startGameWith fixture scenarioIdValue pack = do
  validatePack pack
  scenario <- maybe (Left "Unknown scenario; choose settlement or recovery") Right (M.lookup scenarioIdValue (packScenarios pack))
  (d, original) <- mapFailure (fixture (packEconomy pack))
  -- Scenario grants are authored only here. They never count as campaign evidence.
  let inv = worldInventory original
      scaled = M.map (\lot -> if lotResource lot == Ration then lot {lotQty = checkedQty (qtyValue (lotQty lot) * scenarioRationPercent scenario `div` 100)} else lot) (invLots inv)
      grant = sum [qtyValue (lotQty lot) | lot <- M.elems scaled, lotResource lot == Ration]
      pantryGrant = min grant 60000
      -- Recovery concentrates the limited opening food in the staffed pantry;
      -- excess initial warehouse lots are zero-elided rather than minted later.
      scaledRecovery = if scenarioStartsBroken scenario then M.map (\lot -> if lotResource lot == Ration then lot {lotQty = checkedQty (if lotOwner lot == s01Pantry d then pantryGrant else 0)} else lot) scaled else scaled
      inventory = inv {invLots = M.filter ((> 0) . qtyValue . lotQty) scaledRecovery, invLedger = M.insert (Ration, InitialGrant) (sum [qtyValue (lotQty lot) | lot <- M.elems scaledRecovery, lotResource lot == Ration]) (invLedger inv)}
      participant = Participant OperatorRole (Epoch (worldAuthority original) 1)
      world = original {worldInventory = inventory, worldParticipants = M.insert 2 participant (worldParticipants original), worldM1 = fmap (\s -> s {m1Scenario = "red-dune-live-1"}) (worldM1 original)}
      ready = if scenarioStartsBroken scenario then breakKitchen d world else world
      game = GameState ready d pack Nothing (initialCampaign scenario ready) emptyPolicies 1 [] [] M.empty M.empty
  validateGame game
  pure game
  where
    checkedQty = either (error . show) id . mkQty

mapFailure :: (Show e) => Either e a -> Either String a
mapFailure = either (Left . show) Right

validateGame :: GameState -> Either String ()
validateGame game = do
  let w = gameWorld game; c = gameCampaign game; p = gamePolicies game
  validatePack (gamePack game)
  maybe (Right ()) validatePack (gameStagedPack game)
  unless (worldContent w == packEconomy (gamePack game)) (Left "World differs from pinned economic pack")
  unless (worldRuleset w == "red-dune-live-1") (Left "Live save has unsupported world profile")
  mapFailure (validateWorld w)
  (expectedDescriptor, _) <- mapFailure (s01FixtureWithRuleset "red-dune-live-1" (packEconomy (gamePack game)))
  unless (gameDescriptor game == expectedDescriptor) (Left "Saved descriptor differs from the pinned authored scenario")
  unless (M.lookup (scenarioId (campaignScenario c)) (packScenarios (gamePack game)) == Just (campaignScenario c)) (Left "Saved campaign scenario differs from pinned pack")
  unless (all (`M.member` worldSites w) (productionSites p) && length (productionSites p) == M.size (M.fromList [(ident, ()) | ident <- productionSites p])) (Left "Production policy references missing or repeated sites")
  unless (campaignProduced c <= ledger Ration RecipeOutput w && campaignFreshConsumed c <= ledger Ration LivingConsumed w && campaignWaterExtracted c <= ledger Water Extraction w) (Left "Campaign evidence exceeds physical ledger totals")
  unless (gameRevision game > 0 && campaignStart c <= simTick w) (Left "Invalid live revision or campaign start")
  unless (all (>= 0) [campaignProduced c, campaignFreshConsumed c, campaignWaterExtracted c, campaignStableTicks c] && campaignFreshConsumed c <= campaignProduced c) (Left "Invalid campaign witness totals")
  unless (campaignStableTicks c <= elapsedTicks w c) (Left "Stable evidence exceeds elapsed time")
  unless (length (deliveryPolicies p) <= 256 && length (gameBuildQueue game) <= 64) (Left "Policy/construction queue budget exceeded")
  unless (length (map policyId (deliveryPolicies p)) == M.size (M.fromList [(policyId route, ()) | route <- deliveryPolicies p])) (Left "Duplicate policy identity")
  mapM_ (validatePolicy w) (deliveryPolicies p)
  unless (M.size (gamePlaces game) <= 2048) (Left "Place budget exceeded")
  mapM_ (validatePlace game) (M.toAscList (gamePlaces game))
  unless (M.size (gameDiningPlaces game) <= 1) (Left "The current colony can staff one communal dining place")
  mapM_ (validateDining game) (M.toAscList (gameDiningPlaces game))
  let diningOwners = S.fromList [owner | status <- diningStatuses game, Just owner <- [diningOwner status]]
  unless (all (`S.member` diningOwners) (M.elems (needsDiningPreferences (worldNeeds w)))) (Left "Dining assignment lacks its player-placed pantry")
  unless (all ((<= simTick w) . mealTick) (M.elems (needsLastMeals (worldNeeds w)))) (Left "Meal evidence is from a future tick")
  where
    validatePolicy w route = do
      unless (policyTarget route >= 0 && policyTarget route <= 400000 && policyBatch route > 0 && policyBatch route <= 400000 && policyPriority route >= 0 && policyPriority route <= 3) (Left "Policy quantity/priority out of bounds")
      unless (all (`M.member` invStorage (worldInventory w)) (policyDestination route : policySources route)) (Left "Policy references unknown physical owner")

validatePlace :: GameState -> (Space.Tile, (PlaceKind, Space.Rotation)) -> Either String ()
validatePlace game (tile, (kind, _)) = do
  state <- maybe (Left "Place requires a physical map") Right (worldM1 world)
  mapFailure (Space.checkTile (Space.spatialMap (m1Space state)) tile)
  let placements = M.elems (Space.spatialPlacements (m1Space state))
      overlaps placement = case Space.placementShape placement of
        Space.BuildingShape {} -> case Space.placementGeometry (worldContent world) placement of Right (tiles, _) -> S.member tile tiles; Left _ -> True
        Space.RoadShape road -> kind /= PlaceSquare && road == tile
      queuedOverlap shape = case shape of
        Space.BuildingShape prototype origin rotation ->
          case lookupBuilding (worldContent world) prototype >>= \building -> mapFailure (Space.footprintGeometry (buildingFootprint building) origin rotation) of
            Right (tiles, _) -> S.member tile tiles
            Left _ -> True
        Space.RoadShape road -> kind /= PlaceSquare && road == tile
  unless (not (any overlaps placements)) (Left "Place overlaps a building or planned road")
  unless (not (any queuedOverlap (gameBuildQueue game))) (Left "Place overlaps a queued building or road")
  unless (kind == PlaceSquare || not (S.member tile (Space.spatialRoads (m1Space state)))) (Left "Keep the transport road clear")
  where
    world = gameWorld game

data DiningStatus = DiningStatus
  { diningTile :: !Space.Tile,
    diningRotation :: !Space.Rotation,
    diningOwner :: !(Maybe Owner),
    diningBuilt :: !Bool,
    diningStock :: !Integer,
    diningIncoming :: !Integer,
    diningResidents :: ![EntityId],
    diningMeals :: ![(EntityId, MealRecord)]
  }
  deriving (Eq, Show)

selectedDiningResidents :: S01Descriptor -> [EntityId]
selectedDiningResidents descriptor = concatMap (take 2) (M.elems (s01ShiftResidents descriptor))

diningStatuses :: GameState -> [DiningStatus]
diningStatuses game = [status tile rotation | (tile, rotation) <- M.toAscList (gameDiningPlaces game)]
  where
    world = gameWorld game
    placements = maybe [] (M.elems . Space.spatialPlacements . m1Space) (worldM1 world)
    status tile rotation =
      let placement = find ((== Space.BuildingShape "pantry" tile rotation) . Space.placementShape) placements
          built = maybe False ((== Space.Built) . Space.placementStage) placement
          owner = if built then Owner Pantry . Space.placementId <$> placement else Nothing
          quantity = maybe 0 (\source -> physical world source Ration) owner
          incoming = maybe 0 (\source -> incomingDeliveryQuantity (worldTransport world) source Ration) owner
          meals = [(ident, meal) | (ident, meal) <- M.toAscList (needsLastMeals (worldNeeds world)), Just (mealOwner meal) == owner]
       in DiningStatus tile rotation owner built quantity incoming (selectedDiningResidents (gameDescriptor game)) meals

validateDining :: GameState -> (Space.Tile, Space.Rotation) -> Either String ()
validateDining game (tile, rotation) = do
  state <- maybe (Left "Dining requires a physical map") Right (worldM1 (gameWorld game))
  let shape = Space.BuildingShape "pantry" tile rotation
      present = any ((== shape) . Space.placementShape) (M.elems (Space.spatialPlacements (m1Space state)))
      queued = shape `elem` gameBuildQueue game
  unless (present || queued) (Left "Dining place lacks its construction plan")

-- The player chooses the real footprint and orientation. Roads and the pantry
-- remain normal, paid construction jobs; preview admission reserves nothing in
-- the authoritative world. No food, finished road, or building is granted here.
planDining :: Space.Tile -> Space.Rotation -> GameState -> Either String GameState
planDining tile rotation game = do
  unless (M.null (gameDiningPlaces game)) (Left "This colony already has a dining place")
  unless (null (gameBuildQueue game)) (Left "Wait for the current construction queue")
  unless (gameRevision game < maxBound) (Left "Live revision exhausted")
  roads <- diningRoadPath tile rotation game
  let descriptor = gameDescriptor game
      shape = Space.BuildingShape "pantry" tile rotation
      queue = map Space.RoadShape roads ++ [shape]
  unless (length queue <= 64) (Left "Dining road must fit the 64-stage construction queue")
  (_, admission) <- issue 2 [PlaceConstructionPlan (s01Colony descriptor) planned 2 Nothing | planned <- queue] (gameWorld game)
  unless (all receiptApplied (outputReceipts admission)) (Left ("Dining placement is blocked: " ++ show (map receiptOutcome (outputReceipts admission))))
  let world = gameWorld game
  workforce <- maybe (Left "Dining requires the colony workforce") (Right . m1Workforce) (worldM1 world)
  let assigned = S.fromList (concat (M.elems (W.workforceRosters workforce)))
      drivers = [command | command@(AssignWorkers target@(W.DriveVehicle _) shift names) <- s01RosterCommands descriptor, null (M.findWithDefault [] (target, shift) (W.workforceRosters workforce)), all (`S.notMember` assigned) names]
  (staffed, driverReceipts) <- issue 2 drivers world
  unless (all receiptApplied (outputReceipts driverReceipts)) (Left "Dining transport workers are unavailable")
  let next =
        game
          { gameWorld = staffed,
            gameDiningPlaces = M.singleton tile rotation,
            gameBuildQueue = queue,
            gamePolicies = (gamePolicies game) {policiesEnabled = True, assistConstruction = True, assistMaintenance = True},
            gameRevision = gameRevision game + 1
          }
  validateGame next
  pure next

diningDeliveryPolicies :: GameState -> [DeliveryPolicy]
diningDeliveryPolicies game =
  [ DeliveryPolicy ("dining-food-" ++ show ident) [Owner MachineOutput (s01Kitchen (gameDescriptor game))] owner Ration 6000 3000 0 True
  | status <- diningStatuses game,
    Just owner@(Owner Pantry ident) <- [diningOwner status]
  ]

-- The twelfth spare shift resident serves the meal after building work ends.
-- Existing maintenance keeps the eleventh spare resident. During another
-- construction the server releases their roster, allowing the ordinary pair of
-- builders to work while dining visitors retain normal pantry fallback.
configureDining :: Bool -> GameState -> Either String GameState
configureDining _ game | M.null (gameDiningPlaces game) = Right game
configureDining releaseForBuilding game = do
  state <- maybe (Left "Dining requires workforce state") Right (worldM1 world)
  let statuses = diningStatuses game
      builtOwners = [owner | status <- statuses, Just owner <- [diningOwner status]]
      preferences = M.fromList [(ident, owner) | owner <- builtOwners, ident <- selectedDiningResidents (gameDescriptor game)]
      wf = m1Workforce state
      assigned = S.fromList (concat (M.elems (W.workforceRosters wf)))
      commands =
        [ AssignWorkers target shift names
        | Owner Pantry ident <- builtOwners,
          let target = W.OperateFacility ident,
          (shift, people) <- M.toAscList (s01ShiftResidents (gameDescriptor game)),
          let old = M.findWithDefault [] (target, shift) (W.workforceRosters wf)
              candidate = take 1 (drop 12 people)
              names = if releaseForBuilding then [] else candidate,
          names /= old,
          releaseForBuilding || (not (null names) && all (`S.notMember` assigned) names)
        ]
      prepared = world {worldNeeds = (worldNeeds world) {needsDiningPreferences = preferences}}
  (staffed, _) <- issue 2 commands prepared
  let policy = gamePolicies game
      merged = M.elems (M.union (M.fromList [(policyId route, route) | route <- deliveryPolicies policy]) (M.fromList [(policyId route, route) | route <- diningDeliveryPolicies game]))
  pure game {gameWorld = staffed, gamePolicies = policy {deliveryPolicies = merged}}
  where
    world = gameWorld game

diningConstructionActive :: GameState -> Bool
diningConstructionActive game = maybe False (any (not . C.constructionTerminal) . M.elems . C.constructionJobs . m1Construction) (worldM1 (gameWorld game))

receiptApplied :: CommandReceipt -> Bool
receiptApplied receipt = case receiptOutcome receipt of Applied _ -> True; _ -> False

-- Search from the chosen pantry connector to the kitchen's connected road
-- component. The returned order grows outward from the existing network, so
-- carts can physically reach each subsequent construction input.
diningRoadPath :: Space.Tile -> Space.Rotation -> GameState -> Either String [Space.Tile]
diningRoadPath tile rotation game = do
  state <- maybe (Left "Map is absent") Right (worldM1 world)
  building <- lookupBuilding (worldContent world) "pantry"
  (footprint, port) <- mapFailure (Space.footprintGeometry (buildingFootprint building) tile rotation)
  unless (all (`M.notMember` gamePlaces game) (S.toList footprint)) (Left "Dining footprint overlaps placed scenery")
  let space = m1Space state
  occupied <- mapFailure (Space.reservedTiles (worldContent world) space)
  location <- maybe (Left "Kitchen lacks a physical road connector") Right (M.lookup (Owner MachineOutput (s01Kitchen (gameDescriptor game))) (Space.spatialOwnerLocations space))
  anchor <- maybe (Left "Kitchen lacks a physical road connector") Right (Space.ownerRoadConnector location)
  let existing = Space.spatialRoads space
      network = roadComponent existing anchor
      furniture = S.fromList [position | (position, (kind, _)) <- M.toList (gamePlaces game), kind /= PlaceSquare]
      blocked = S.unions [footprint, M.keysSet occupied `S.difference` existing, Space.sourceTiles space, M.keysSet (Space.spatialCaches space), furniture]
      allowed position = S.notMember position blocked && case Space.checkWalkable (Space.spatialMap space) position of Right () -> True; Left _ -> False
      origin = Space.roadConnector port
      search queue parents = case Q.viewl queue of
        Q.EmptyL -> Left "No road route reaches this dining place"
        current Q.:< rest
          | S.member current network -> Right (filter (`S.notMember` existing) (trace parents current))
          | otherwise ->
              let unseen = [next | next <- diningNeighbours current, allowed next, M.notMember next parents]
                  linked = foldr (\next -> M.insert next (Just current)) parents unseen
               in search (rest Q.>< Q.fromList unseen) linked
      trace parents position = position : maybe [] (trace parents) (M.findWithDefault Nothing position parents)
  unless (not (S.null network) && allowed origin) (Left "Dining connector cannot reach the kitchen road")
  search (Q.singleton origin) (M.singleton origin Nothing)
  where
    world = gameWorld game

diningNeighbours :: Space.Tile -> [Space.Tile]
diningNeighbours (Space.Tile x y) = [Space.Tile (x - 1) y, Space.Tile x (y - 1), Space.Tile x (y + 1), Space.Tile (x + 1) y]

roadComponent :: S.Set Space.Tile -> Space.Tile -> S.Set Space.Tile
roadComponent roads origin = visit S.empty (S.singleton origin)
  where
    visit seen pending = case S.minView pending of
      Nothing -> seen
      Just (position, rest)
        | S.member position seen || S.notMember position roads -> visit seen rest
        | otherwise -> visit (S.insert position seen) (S.union rest (S.fromList (diningNeighbours position) `S.difference` seen))

-- New authority/branch on host activation prevents an old outstanding HTTP
-- command from becoming a fresh command after restoring a checkpoint.
reidentifyGame :: String -> GameState -> Either String GameState
reidentifyGame authority game = reidentifyGameToBranch authority (branchId (gameWorld game) + 1) game

reidentifyGameToBranch :: String -> Word64 -> GameState -> Either String GameState
reidentifyGameToBranch authority branch game = do
  unless (gameRevision game < maxBound) (Left "Live revision exhausted")
  unless (validUUIDv4 authority) (Left "Activation needs a fresh UUIDv4 authority")
  let world = gameWorld game
      authorities = worldAuthority world : [a | ((_, Epoch a _), _) <- M.toList (worldHighWater world)]
  unless (authority `notElem` authorities && branch > 0 && branch /= branchId world) (Left "Authority collision or branch exhaustion")
  let participants = M.map (\p -> p {participantEpoch = Epoch authority 1}) (worldParticipants world)
      next =
        world
          { worldAuthority = authority,
            branchId = branch,
            worldParticipants = participants,
            worldHighWater = M.union (M.fromList [((controller, Epoch authority 1), 0) | controller <- M.keys participants]) (worldHighWater world),
            worldMode = Paused
          }
      result = game {gameWorld = next, gameRevision = gameRevision game + 1}
  validateGame result
  pure result

boundary :: Bool -> [OrderedCommand] -> [ManagementEvent] -> World -> Either String (World, ColonyOutput)
boundary advance commands management world = do
  let header = BoundaryHeader (worldId world) (branchId world) (boundarySeq world) advance (worldAuthority world) (worldRuleset world)
      (next, out) = pureStep (Boundary header commands management) world
  unless (null (outputDiagnostics out)) (Left ("Kernel boundary rejected: " ++ show (outputDiagnostics out)))
  pure (next, out)

issue :: Word64 -> [Command] -> World -> Either String (World, ColonyOutput)
issue controller bodies world = do
  participant <- maybe (Left "Missing controller") Right (M.lookup controller (worldParticipants world))
  let epoch = participantEpoch participant; highest = M.findWithDefault 0 (controller, epoch) (worldHighWater world)
  unless (toInteger highest + toInteger (length bodies) <= toInteger (maxBound :: Word64)) (Left "Command sequence exhausted")
  boundary False [OrderedCommand ordinal (CommandId (worldId world) controller epoch (highest + ordinal + 1)) body | (ordinal, body) <- zip [0 ..] bodies] [] world

previewGame :: J.JSON -> GameState -> Either String J.JSON
previewGame body game = do
  let w = gameWorld game
  command <- decodeUICommand w body
  (predicted, output) <- issue 1 [command] w
  pure
    ( obj
        [ ("status", str "intentPreview"),
          ("certainty", str "PreviewOnlyNotCommitted"),
          ("envelope", previewEnvelope w body),
          ("previewPlan", previewPlanJSON predicted command output),
          ("predictedReceipts", arr (map receiptJSON (outputReceipts output)))
        ]
    )

applyAction :: J.JSON -> GameState -> Either String (GameState, J.JSON)
applyAction value game = do
  fields <- J.object value
  op <- getString "op" fields
  case op of
    "state" -> pure (game, obj [("status", str "observed")])
    "preview" -> do body <- J.field "command" fields; result <- previewGame body game; pure (game, result)
    "pause" -> managed PauseWorld
    "resume" -> do unless (campaignEnding (gameCampaign game) == Ongoing) (Left "Campaign ended; restart or restore to play"); managed ResumeWorld
    "command" -> do
      command <- commandFromRequest (gameWorld game) fields
      expected <- getWord "boundary" fields
      let w = gameWorld game
          retried = any (\r -> receiptCommand r == commandId command && receiptBody r == commandBody command) (worldReceipts w)
      unless (BoundarySeq expected == boundarySeq w || retried) (Left "Stale intent: boundary changed; preview again")
      (next, out) <- boundary False [command] [] w
      finish game {gameWorld = next} (receiptResult out)
    "configure" -> do
      preset <- getString "preset" fields
      case preset of
        "off" -> finish game {gamePolicies = emptyPolicies} (ok "Automation stopped")
        "survival" -> do
          let d = gameDescriptor game
          (w, out) <- issue 1 (s01RosterCommands d ++ [SetSiteEnabled (s01Farm d) True, SetSiteEnabled (s01Kitchen d) True]) (gameWorld game)
          unless (all applied (outputReceipts out)) (Left "Cannot configure staffing while workers belong to other targets; release their assignments first")
          finish game {gameWorld = w, gamePolicies = survivalPolicies d} (ok "Survival policies and three-shift crews configured")
        _ -> Left "Unknown preset"
    "expand" -> do
      unless (null (gameBuildQueue game)) (Left "Expansion is already queued")
      prototype <- getString "prototype" fields
      unless (prototype == "warehouse") (Left "Guided expansion supports warehouse; use placePlan for free placement")
      let queue = map (\x -> Space.RoadShape (Space.Tile x 64)) [55, 54 .. 51] ++ [Space.BuildingShape "warehouse" (Space.Tile 50 60) Space.R0]
      finish game {gameBuildQueue = queue} (ok "Reserve warehouse route queued; materials and crew must physically finish each stage")
    "policy" -> do
      key <- getString "id" fields
      enabled <- J.field "enabled" fields >>= J.boolean
      target <- getQuantity "target" fields
      batch <- getQuantity "batch" fields
      let p = gamePolicies game
      unless (any ((== key) . policyId) (deliveryPolicies p)) (Left "Unknown policy ID")
      let updated = p {deliveryPolicies = map (\r -> if policyId r == key then r {policyEnabled = enabled, policyTarget = target, policyBatch = batch} else r) (deliveryPolicies p)}
      finish game {gamePolicies = updated} (ok "Policy updated")
    "stagePack" -> do
      expected <- getWord "expectedRevision" fields
      let latest = maybe (gamePack game) id (gameStagedPack game)
      unless (expected == packRevision latest) (Left "Stale pack revision; current staged pack retained")
      packValue <- J.field "pack" fields
      candidate <- decodePack (encodeJSON packValue)
      unless (packRevision candidate > packRevision latest) (Left "Pack revision must increase")
      finish game {gameStagedPack = Just candidate} (ok "Pack staged atomically; this session remains pinned")
    _ -> Left ("Unknown game operation: " ++ op)
  where
    ok message = obj [("status", str "accepted"), ("message", str message)]
    managed event = do (w, out) <- boundary False [] [event] (gameWorld game); finish game {gameWorld = w} (receiptResult out)
    finish candidate result = do
      unless (gameRevision game < maxBound) (Left "Live revision exhausted")
      let next = candidate {gameRevision = gameRevision game + 1}
      validateGame next
      pure (next, result)
    applied receipt = case receiptOutcome receipt of Applied _ -> True; _ -> False

receiptResult :: ColonyOutput -> J.JSON
receiptResult out = obj [("status", str "boundaryCommitted"), ("receipts", arr (map receiptJSON (outputReceipts out))), ("diagnostics", arr (map (str . show) (outputDiagnostics out)))]

-- Policies run once per simulated minute (20 ordinary ticks), without advancing
-- time during command admission. Every reservation/roster/repair uses the kernel.
runPolicies :: GameState -> Either String GameState
runPolicies game
  | not (policiesEnabled (gamePolicies game)) = Right game
  | otherwise = do
      let d = gameDescriptor game; p = gamePolicies game
      queued <- case gameBuildQueue game of
        shape : rest | assistConstruction p && not (activeConstruction (gameWorld game)) -> do
          (w, out) <- issue 2 [PlaceConstructionPlan (s01Colony d) shape 2 Nothing] (gameWorld game)
          if all success (outputReceipts out)
            then pure game {gameWorld = w, gameBuildQueue = rest}
            else pure game {gameWorld = w, gameBuildQueue = [], gameNotices = take 8 ("Expansion blocked: inspect placement/route" : gameNotices game)}
        _ -> pure game
      dining <- configureDining (diningConstructionActive queued) queued
      let deliveries = deliveryPolicies (gamePolicies dining) ++ (if assistConstruction p then constructionPolicies d (gameWorld dining) ++ reservePolicies d (gameWorld dining) else []) ++ (if assistMaintenance p then maintenanceDeliveryPolicies d (gameWorld dining) else [])
      supplied <- foldM (\g policy -> maybe (Right g) (issueOne g) (deliveryCommand (gameWorld g) policy)) dining deliveries
      repaired <- foldM issueOne supplied (if assistMaintenance p then maintenanceCommands (gameWorld supplied) else [])
      crewed <- foldM issueOne repaired (if assistConstruction p || assistMaintenance p then serviceRosterCommands d (gameWorld repaired) else [])
      dined <- configureDining (diningConstructionActive crewed) crewed
      foldM (\g ident -> maybe (Right g) (issueOne g) (productionCommand (gameWorld g) ident)) dined (productionSites p)
  where
    issueOne g command = do (w, _) <- issue 2 [command] (gameWorld g); pure g {gameWorld = w}
    success receipt = case receiptOutcome receipt of Applied _ -> True; _ -> False
    activeConstruction w = maybe False (any (not . C.constructionTerminal) . M.elems . C.constructionJobs . m1Construction) (worldM1 w)

advanceGame :: Int -> GameState -> Either String GameState
advanceGame count initial = do
  unless (count >= 0 && count <= 1200) (Left "Tick batch must be 0..1200")
  go count initial
  where
    go 0 !game = Right game
    go remaining !game
      | worldMode (gameWorld game) /= Active || campaignEnding (gameCampaign game) /= Ongoing = Right game
      | otherwise = do
          unless (gameRevision game < maxBound) (Left "Live revision exhausted")
          let SimTick tick = simTick (gameWorld game)
          prepared <- if tick `mod` 20 == 0 then runPolicies game else Right game
          let before = gameWorld prepared
          (stepped, _) <- boundary True [] [] before
          let progress = advanceCampaign (gameDescriptor game) (gamePolicies game) before stepped (gameCampaign game)
              (campaign, disrupted) = disruptIfDue (gameDescriptor game) progress stepped
              finalWorld = if campaignEnding campaign == Ongoing then disrupted else disrupted {worldMode = Paused}
              next = force prepared {gameWorld = finalWorld, gameCampaign = campaign, gameRevision = gameRevision game + 1}
          go (remaining - 1) next

observeGame :: GameState -> J.JSON
observeGame game =
  obj
    [ ("view", liveView),
      ("revision", num (gameRevision game)),
      ("campaign", campaignJSON (gameWorld game) (gameCampaign game)),
      ( "policies",
        obj
          [ ("enabled", J.JBool (policiesEnabled p)),
            ("construction", J.JBool (assistConstruction p)),
            ("maintenance", J.JBool (assistMaintenance p)),
            ("productionSites", arr [num n | EntityId n <- productionSites p]),
            ("deliveries", arr (map route (deliveryPolicies p)))
          ]
      ),
      ( "pack",
        obj
          [ ("title", str (packTitle (gamePack game))),
            ("identity", str (packIdentity (gamePack game))),
            ("revision", num (packRevision (gamePack game))),
            ("stagedRevision", maybe J.JNull (num . packRevision) (gameStagedPack game)),
            ("stagedIdentity", maybe J.JNull (str . packIdentity) (gameStagedPack game)),
            ("stagedTitle", maybe J.JNull (str . packTitle) (gameStagedPack game))
          ]
      ),
      ("buildable", arr (map str C.liveBuildablePrototypes)),
      ("buildQueue", arr (map (str . show) (gameBuildQueue game))),
      ("notices", arr (map str (gameNotices game)))
    ]
  where
    p = gamePolicies game
    liveView = case presentation (gameWorld game) of
      J.JObject fields -> J.JObject (M.insert "scope" (arr (map str ["Red Dune live campaign: one physical colony, forty named residents, three shifts", "Policies submit ordinary production, transport, construction and maintenance commands", "The full catalog is visible; the buildable subset is explicit. Research, contracts, immigration and weather storms remain outside this campaign", "Loopback Haskell authority with durable live saves; no browser-side simulation"])) fields)
      value -> value
    route r =
      obj
        [ ("status", str (fst (policyStatus (gameWorld game) r))),
          ("reason", str (snd (policyStatus (gameWorld game) r))),
          ("id", str (policyId r)),
          ("enabled", J.JBool (policyEnabled r)),
          ("sources", arr (map ownerJSON (policySources r))),
          ("destination", ownerJSON (policyDestination r)),
          ("resource", str (resourceKey (policyResource r))),
          ("target", num (policyTarget r)),
          ("batch", num (policyBatch r)),
          ("priority", num (policyPriority r)),
          ("incoming", num (incomingDeliveryQuantity (worldTransport (gameWorld game)) (policyDestination r) (policyResource r))),
          ("available", num (physical (gameWorld game) (policyDestination r) (policyResource r)))
        ]

restartGame :: String -> String -> GameState -> Either String GameState
restartGame scenario authority game = startGame scenario (maybe (gamePack game) id (gameStagedPack game)) >>= reidentifyGame authority
