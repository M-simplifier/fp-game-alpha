{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module RedDune.Game where

import Colony.Construction qualified as C
import Colony.JSON qualified as J
import Colony.M1State
import Colony.Presentation (arr, encodeJSON, num, obj, ownerJSON, presentation, previewPlanJSON, receiptJSON, str)
import Colony.S01Fixture
import Colony.Scheduler (pureStep)
import Colony.Session (validUUIDv4)
import Colony.Space qualified as Space
import Colony.Transport (incomingDeliveryQuantity)
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq (NFData, force)
import Control.Monad (foldM, unless)
import Data.Map.Strict qualified as M
import Data.Word (Word64)
import GHC.Generics (Generic)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Policies
import RedDune.Protocol

data GameState = GameState
  { gameWorld :: !World,
    gameDescriptor :: !S01Descriptor,
    gamePack :: !ContentPack,
    gameStagedPack :: !(Maybe ContentPack),
    gameCampaign :: !CampaignState,
    gamePolicies :: !Policies,
    gameRevision :: !Word64,
    gameBuildQueue :: ![Space.PlacementShape],
    gameNotices :: ![String]
  }
  deriving (Eq, Show, Read, Generic, NFData)

startGame :: String -> ContentPack -> Either String GameState
startGame scenarioIdValue pack = do
  validatePack pack
  scenario <- maybe (Left "Unknown scenario; choose settlement or recovery") Right (M.lookup scenarioIdValue (packScenarios pack))
  (d, original) <- mapFailure (s01FixtureWithRuleset "red-dune-live-1" (packEconomy pack))
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
      game = GameState ready d pack Nothing (initialCampaign scenario ready) emptyPolicies 1 [] []
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
  where
    validatePolicy w route = do
      unless (policyTarget route >= 0 && policyTarget route <= 400000 && policyBatch route > 0 && policyBatch route <= 400000 && policyPriority route >= 0 && policyPriority route <= 3) (Left "Policy quantity/priority out of bounds")
      unless (all (`M.member` invStorage (worldInventory w)) (policyDestination route : policySources route)) (Left "Policy references unknown physical owner")

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
      let deliveries = deliveryPolicies p ++ (if assistConstruction p then constructionPolicies d (gameWorld queued) ++ reservePolicies d (gameWorld queued) else []) ++ (if assistMaintenance p then maintenanceDeliveryPolicies d (gameWorld queued) else [])
      supplied <- foldM (\g policy -> maybe (Right g) (issueOne g) (deliveryCommand (gameWorld g) policy)) queued deliveries
      repaired <- foldM issueOne supplied (if assistMaintenance p then maintenanceCommands (gameWorld supplied) else [])
      crewed <- foldM issueOne repaired (if assistConstruction p || assistMaintenance p then serviceRosterCommands d (gameWorld repaired) else [])
      foldM (\g ident -> maybe (Right g) (issueOne g) (productionCommand (gameWorld g) ident)) crewed (productionSites p)
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
