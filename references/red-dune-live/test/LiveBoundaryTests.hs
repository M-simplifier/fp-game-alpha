-- Independent boundary regressions. Campaign micro-fixtures exercise predicates
-- in isolation; these synthetic states are not playable-run evidence.
module Main where

import Colony.Codec (sha256)
import Colony.Codec.Value (encodeValue)
import Colony.Content (Building (..), Content (..))
import Colony.JSON qualified as J
import Colony.Maintenance
import Colony.Needs
import Colony.Presentation (encodeJSON, obj, str)
import Colony.S01Fixture
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import Data.Word (Word64)
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.GameSave
import RedDune.Policies
import RedDune.Protocol qualified as P

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError label))

must :: (Show e) => Either e a -> IO a
must = either (ioError . userError . show) pure

isLeft :: Either a b -> Bool
isLeft Left {} = True
isLeft _ = False

number :: String -> Either String Word64
number value = P.getWord "value" (M.singleton "value" (str value))

action :: [(String, J.JSON)] -> GameState -> Either String (GameState, J.JSON)
action fields = applyAction (obj fields)

setField :: String -> J.JSON -> J.JSON -> J.JSON
setField key value (J.JObject fields) = J.JObject (M.insert key value fields)
setField _ _ other = other

nextTick :: World -> World
nextTick w = let SimTick t = simTick w in w {simTick = SimTick (t + 1)}

main :: IO ()
main = do
  forM_ [0, 1, 9007199254740991, 9007199254740992, 9007199254740993, toInteger (maxBound :: Word64)] $ \n ->
    check ("exact Word64 admission: " ++ show n) (number (show n) == Right (fromInteger n))
  forM_ ["18446744073709551616", "18446744073709551617", "99999999999999999999", "-1", "+1", "01", "1e2", "1.0", " 1", "1 ", ""] $ \raw ->
    check ("reject noncanonical/overflow Word64: " ++ show raw) (isLeft (number raw))
  check "JSON exact integral literal above 2^53" (J.parseJSON "9007199254740993" == Right (J.JInteger 9007199254740993))
  initial <- must (startGame "settlement" defaultPack)
  bytes <- must (encodeGame initial)
  loaded <- must (decodeGame bytes)
  check "complete checkpoint exact round trip" (loaded == initial)
  let badDescriptor = initial {gameDescriptor = (gameDescriptor initial) {s01Warehouses = []}}
      badScenario = initial {gameCampaign = (gameCampaign initial) {campaignScenario = (campaignScenario (gameCampaign initial)) {scenarioHours = 67}}}
      badProduction = initial {gamePolicies = emptyPolicies {productionSites = [EntityId 900000]}}
      badEvidence = initial {gameCampaign = (gameCampaign initial) {campaignProduced = 1}}
  forM_ [("descriptor", badDescriptor), ("scenario", badScenario), ("production reference", badProduction), ("physical evidence bound", badEvidence)] $ \(label, malformed) -> do
    check ("encoder rejects malformed " ++ label) (isLeft (encodeGame malformed))
    payload <- must (encodeValue malformed)
    check ("decoder rejects checksum-valid malformed " ++ label) (isLeft (decodeGame (magic <> sha256 payload <> payload)))
  check "checksum rejects payload damage" (isLeft (decodeGame (BS.init bytes <> BS.singleton 255)))
  check "checkpoint rejects trailing bytes" (isLeft (decodeGame (bytes <> BS.singleton 0)))
  check "checkpoint rejects truncated payload" (isLeft (decodeGame (BS.take 64 bytes)))
  source <- readFile "data/campaign-pack-v1.json"
  originalPackJSON <- must (J.parseJSON source)
  let highRevision = 9007199254740993
      candidateJSON = setField "revision" (J.JInteger highRevision) originalPackJSON
      stage expected value = action [("op", str "stagePack"), ("expectedRevision", str expected), ("pack", value)]
  candidate <- must (decodePack (encodeJSON candidateJSON))
  check "pack high revision remains exact" (toInteger (packRevision candidate) == highRevision)
  (staged, _) <- must (stage "1" candidateJSON initial)
  check "stage leaves live world pinned" (gameWorld staged == gameWorld initial && gamePack staged == gamePack initial)
  check "complete candidate retained" (gameStagedPack staged == Just candidate)
  observed <- must (J.object (observeGame staged))
  observedPack <- must (J.field "pack" observed >>= J.object)
  check
    "view distinguishes pinned and staged identity"
    ( M.lookup "identity" observedPack == Just (str (packIdentity defaultPack))
        && M.lookup "stagedIdentity" observedPack == Just (str (packIdentity candidate))
        && M.lookup "stagedTitle" observedPack == Just (str (packTitle candidate))
    )
  stagedBytes <- must (encodeGame staged)
  stagedLoaded <- must (decodeGame stagedBytes)
  check "staged candidate persists exactly" (stagedLoaded == staged)
  check "stale stage rejects" (isLeft (stage "1" (setField "revision" (J.JInteger (highRevision + 1)) candidateJSON) staged))
  check "invalid stage rejects" (isLeft (stage (show highRevision) (setField "title" (str "") candidateJSON) staged))
  check "malformed stage rejects" (isLeft (stage (show highRevision) J.JNull staged))
  restarted <- must (restartGame "recovery" "a1234567-1234-4234-a234-123456789abc" staged)
  check "restart uses exact staged pack" (gamePack restarted == candidate && gameStagedPack restarted == Nothing)
  restartedView <- must (J.object (observeGame restarted))
  adoptedPack <- must (J.field "pack" restartedView >>= J.object)
  check "adopted view clears staged identity" (M.lookup "identity" adoptedPack == Just (str (packIdentity candidate)) && M.lookup "stagedIdentity" adoptedPack == Just J.JNull)
  check "new authority paused" (worldMode (gameWorld restarted) == Paused)
  check "same authority rejected" (isLeft (reidentifyGame (worldAuthority (gameWorld restarted)) restarted))
  (running, _) <- must (action [("op", str "resume")] initial)
  check "tick rejects exhausted revision" (isLeft (advanceGame 1 running {gameRevision = maxBound}))
  check "activation rejects exhausted revision" (isLeft (reidentifyGame "b1234567-1234-4234-a234-123456789abc" initial {gameRevision = maxBound}))
  forM_ [10, 25, 50, 100] $ \percent -> do
    let pack = defaultPack {packScenarios = M.adjust (\s -> s {scenarioRationPercent = percent}) "recovery" (packScenarios defaultPack)}
    must (validatePack pack)
    recovery <- must (startGame "recovery" pack)
    must (validateGame recovery)
    let inv = worldInventory (gameWorld recovery)
        actual = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inv), lotResource lot == Ration]
    check ("recovery physical/ledger equality " ++ show percent) (actual == M.findWithDefault 0 (Ration, InitialGrant) (invLedger inv))
  let economy = packEconomy defaultPack
      oversizedPeriod = defaultPack {packEconomy = economy {contentBuildings = M.adjust (\building -> building {buildingMaintenancePeriod = quantityMax}) "kitchen" (contentBuildings economy)}}
  check "pack rejects future disruption age overflow" (isLeft (validatePack oversizedPeriod))
  campaignWitnessTests initial
  putStrLn "PASS: exact numbers, save integrity, pack staging/pinning, activation, exhaustion, recovery accounting and campaign witnesses"

campaignWitnessTests :: GameState -> IO ()
campaignWitnessTests game = do
  let w = gameWorld game
      d = gameDescriptor game
      c = gameCampaign game
      policies = survivalPolicies d
      scenario = (campaignScenario c) {scenarioHours = 24, scenarioStableHours = 6, scenarioDisruptionHour = 1}
      SimTick start = campaignStart c
      before = w {simTick = SimTick (start + 24 * 1200)}
      after = nextTick before
      nearlyWon =
        c
          { campaignScenario = scenario,
            campaignProduced = 10000,
            campaignFreshTransit = True,
            campaignFreshPantry = True,
            campaignFreshConsumed = 10000,
            campaignExpanded = True,
            campaignDisrupted = True,
            campaignRecovered = True,
            campaignStableTicks = 6 * 1200 - 1
          }
      missingWater = advanceCampaign d policies before after nearlyWon
      withWater = advanceCampaign d policies before after nearlyWon {campaignWaterExtracted = 1}
  check "victory requires extraction" (campaignEnding missingWater == Ongoing)
  check "positive extraction completes other synthetic witnesses" (campaignEnding withWater == SettlementSecured)
  -- Needs clears hour counters at the hour boundary. A first shortage at that
  -- exact quantum must still reset stability from actual consumption evidence.
  let beforeHour = before {simTick = SimTick (start + 24 * 1200 - 1)}
      afterHour = nextTick beforeHour
      ready = nearlyWon {campaignWaterExtracted = 1}
      shortage = advanceCampaign d policies beforeHour afterHour ready
      residents = M.elems (needsResidents (worldNeeds beforeHour))
      waterDue = sum [(residentWaterRemainder person + 6000 * 20) `div` 28800 | person <- residents]
      foodDue = sum [(residentFoodRemainder person + 3000 * 20) `div` 28800 | person <- residents]
      servedInventory = (worldInventory afterHour) {invLedger = M.insertWith (+) (Water, LivingConsumed) waterDue (M.insertWith (+) (Ration, LivingConsumed) foodDue (invLedger (worldInventory afterHour)))}
      fullyServed = advanceCampaign d policies beforeHour (afterHour {worldInventory = servedInventory}) ready
  check "hour-reset shortage cannot count stable or win" (campaignStableTicks shortage == 0 && campaignEnding shortage == Ongoing)
  check "exactly served hour-reset quantum may complete stability" (campaignEnding fullyServed == SettlementSecured)
  let repairId = EntityId 900000
      historic = MaintenanceJob repairId (s01Kitchen d) (s01Pantry d) (s01Pantry d) BrokenRepair MaintenanceCompleted Nothing 1 1 1 1
      history = (worldMaintenance before) {maintenanceJobs = M.singleton repairId historic}
      prior = before {worldMaintenance = history}
      (disrupted, broken) = disruptIfDue d (c {campaignScenario = scenario}) prior
      noNewRepair = advanceCampaign d policies broken (nextTick broken) disrupted
  check "disruption fences completed repairs" (repairId `elem` campaignPriorRepairs disrupted)
  check "historical repair does not count" (not (campaignRecovered noNewRepair))
  let freshRepairId = EntityId 900001
      freshRepair = historic {maintenanceJobId = freshRepairId}
      repaired = (nextTick broken) {worldMaintenance = (worldMaintenance broken) {maintenanceJobs = M.insert freshRepairId freshRepair (maintenanceJobs (worldMaintenance broken))}}
  check "post-disruption repair counts" (campaignRecovered (advanceCampaign d policies broken repaired disrupted))
  let inv = worldInventory w
      mixed = (nextTick w) {worldInventory = inv {invLedger = M.insertWith (+) (Ration, LivingConsumed) 10000 (M.insertWith (+) (Ration, RecipeOutput) 10000 (invLedger inv))}}
      unrelated = advanceCampaign d policies w mixed c
  check "unrelated recipe is not cook production" (campaignProduced unrelated == 0)
  check "unrelated recipe cannot fabricate fresh consumption" (campaignFreshConsumed unrelated == 0)
  q <- must (mkQty 10000)
  let fresh = Lot (EntityId 900002) Ration q (Owner MachineOutput (s01Kitchen d)) (simTick (nextTick w)) Nothing "recipe:cook"
      cooked = (nextTick w) {worldInventory = inv {invLots = M.insert (lotId fresh) fresh (invLots inv)}}
      witnessed = advanceCampaign d policies w cooked c
  check "physical cook output counted once" (campaignProduced witnessed == 10000 && campaignFreshConsumed witnessed == 0)
  let eaten = (nextTick cooked) {worldInventory = inv {invLedger = M.insertWith (+) (Ration, LivingConsumed) 10000 (invLedger inv)}}
  check "fresh depletion plus living ledger proves consumption" (campaignFreshConsumed (advanceCampaign d policies cooked eaten witnessed) == 10000)
  check "fresh food eaten entirely in one quantum proves pantry service" (campaignFreshPantry (advanceCampaign d policies cooked eaten witnessed))
  let spoiled = eaten {worldInventory = (worldInventory eaten) {invLedger = M.insertWith (+) (Ration, SpoilageInput) 10000 (invLedger (worldInventory eaten))}}
  check "ambiguous spoilage gives no false fresh credit" (campaignFreshConsumed (advanceCampaign d policies cooked spoiled witnessed) == 0)
  check "legacy sandbox cannot gain campaign evidence" (advanceCampaign d policies w cooked c {campaignImported = True} == c {campaignImported = True})
