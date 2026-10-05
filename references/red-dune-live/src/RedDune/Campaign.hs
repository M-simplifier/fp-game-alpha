{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module RedDune.Campaign where

import Colony.Construction qualified as C
import Colony.JSON qualified as J
import Colony.Jobs
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.Presentation (arr, num, obj, str)
import Colony.S01Fixture
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq (NFData)
import Data.Map.Strict qualified as M
import GHC.Generics (Generic)
import RedDune.ContentPack
import RedDune.Policies (Policies (..), physical)

data Ending = Ongoing | SettlementSecured | ColonyLost String deriving (Eq, Show, Read, Generic, NFData)

data CampaignState = CampaignState
  { campaignScenario :: !Scenario,
    campaignStart :: !SimTick,
    campaignInitialSites :: ![EntityId],
    campaignProduced :: !Integer,
    campaignFreshTransit :: !Bool,
    campaignFreshPantry :: !Bool,
    campaignFreshConsumed :: !Integer,
    campaignWaterExtracted :: !Integer,
    campaignExpanded :: !Bool,
    campaignDisrupted :: !Bool,
    campaignRecovered :: !Bool,
    campaignPriorRepairs :: ![EntityId],
    campaignStableTicks :: !Integer,
    campaignEnding :: !Ending,
    campaignImported :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

initialCampaign :: Scenario -> World -> CampaignState
initialCampaign scenario world = CampaignState scenario (simTick world) (M.keys (worldSites world)) 0 False False 0 0 False (scenarioStartsBroken scenario) False [] 0 Ongoing False

elapsedTicks :: World -> CampaignState -> Integer
elapsedTicks world campaign = let SimTick now = simTick world; SimTick start = campaignStart campaign in toInteger now - toInteger start

ledger :: Resource -> Reason -> World -> Integer
ledger resource reason = M.findWithDefault 0 (resource, reason) . invLedger . worldInventory

freshLots :: CampaignState -> World -> [Lot]
freshLots campaign world = [lot | lot <- M.elems (invLots (worldInventory world)), lotResource lot == Ration, lotBorn lot > campaignStart campaign, lotProvenance lot == "recipe:cook"]

freshTotal :: CampaignState -> World -> Integer
freshTotal campaign = sum . map (qtyValue . lotQty) . freshLots campaign

-- Authoritative campaign event, not a player command or test shortcut. It occurs
-- exactly once from elapsed committed time, is saved, and never grants resources.
disruptIfDue :: S01Descriptor -> CampaignState -> World -> (CampaignState, World)
disruptIfDue d c w
  | campaignDisrupted c || campaignImported c || scenarioDisruptionHour (campaignScenario c) == 0 = (c, w)
  | elapsedTicks w c < 1200 * scenarioDisruptionHour (campaignScenario c) = (c, w)
  | otherwise = (c {campaignDisrupted = True, campaignStableTicks = 0, campaignPriorRepairs = [maintenanceJobId j | j <- M.elems (maintenanceJobs (worldMaintenance w)), maintenancePhase j == MaintenanceCompleted]}, breakKitchen d w)

breakKitchen :: S01Descriptor -> World -> World
breakKitchen d w = w {worldMaintenance = (worldMaintenance w) {maintenanceFacilities = M.adjust (\f -> f {facilityCondition = 0, facilityAge = 2 * facilityPeriod f}) (s01Kitchen d) (maintenanceFacilities (worldMaintenance w))}}

advanceCampaign :: S01Descriptor -> Policies -> World -> World -> CampaignState -> CampaignState
advanceCampaign d policies before after c
  | campaignEnding c /= Ongoing || simTick before == simTick after = c
  | campaignImported c = c
  | otherwise = next {campaignEnding = ending}
  where
    produced = sum [qtyValue (lotQty lot) | lot <- freshLots c after, lotBorn lot == simTick after]
    living = max 0 (ledger Ration LivingConsumed after - ledger Ration LivingConsumed before)
    otherLoss = any (\reason -> ledger Ration reason after /= ledger Ration reason before) [SpoilageInput, CancelledProcessLoss, RecipeInput, ConstructionConsumed, TradePaid]
    depletion = max 0 (freshTotal c before + produced - freshTotal c after)
    consumed = if otherLoss then 0 else min living depletion
    lots = freshLots c after
    transit = campaignFreshTransit c || any (\lot -> case lotOwner lot of Owner Vehicle _ -> True; _ -> False) lots
    pantry = campaignFreshPantry c || consumed > 0 || any ((== s01Pantry d) . lotOwner) lots
    expanded =
      campaignExpanded c || case worldM1 after of
        Nothing -> False
        Just state ->
          any
            ( \job ->
                C.constructionPhase job == C.ConstructionCompleted && case C.constructionShape job of
                  -- Stored materials prove new capacity is physically reachable and used.
                  _ ->
                    let ident = C.constructionSiteId job
                        storageUsed = any (\lot -> case lotOwner lot of Owner Warehouse n -> n == ident; Owner Pantry n -> n == ident; Owner Tank n -> n == ident; _ -> False) (M.elems (invLots (worldInventory after)))
                        siteUsed = any (\j -> jobPhase j == Completed && M.lookup (jobId j) (worldJobSites after) == Just ident) (M.elems (worldJobs after))
                     in storageUsed || siteUsed
            )
            (M.elems (C.constructionJobs (m1Construction state)))
    recovered = campaignRecovered c || (campaignDisrupted c && any (\job -> maintenanceTarget job == s01Kitchen d && maintenanceKind job == BrokenRepair && maintenancePhase job == MaintenanceCompleted && maintenanceJobId job `notElem` campaignPriorRepairs c) (M.elems (maintenanceJobs (worldMaintenance after))))
    freshConsumed = campaignFreshConsumed c + consumed
    ready = campaignWaterExtracted c > 0 && campaignProduced c > 0 && transit && pantry && freshConsumed >= scenarioFreshFood (campaignScenario c) && expanded && recovered && policiesEnabled policies
    people = M.elems (needsResidents (worldNeeds after))
    healthy = all (\p -> residentStatus p == Living && residentHealth p >= 950 && residentHourWaterDue p == residentHourWaterServed p && residentHourFoodDue p == residentHourFoodServed p) people
    reserve = physical after (s01Pantry d) Water >= 20000 && physical after (s01Pantry d) Ration >= 10000
    SimTick now = simTick after
    servedThisTick =
      now `mod` 20 /= 0
        || all
          ( \(resource, daily, remainder) ->
              ledger resource LivingConsumed after - ledger resource LivingConsumed before >= sum [(remainder person + daily * 20) `div` 28800 | person <- M.elems (needsResidents (worldNeeds before)), residentStatus person `elem` [Living, Incapacitated]]
          )
          [(Water, 6000, residentWaterRemainder), (Ration, 3000, residentFoodRemainder)]
    stable = if ready && healthy && reserve && servedThisTick then campaignStableTicks c + 1 else 0
    next =
      c
        { campaignProduced = campaignProduced c + produced,
          campaignFreshTransit = transit,
          campaignFreshPantry = pantry,
          campaignFreshConsumed = freshConsumed,
          campaignWaterExtracted = campaignWaterExtracted c + max 0 (ledger Water Extraction after - ledger Water Extraction before),
          campaignExpanded = expanded,
          campaignRecovered = recovered,
          campaignStableTicks = stable
        }
    ending
      | null people || any ((/= Living) . residentStatus) people = ColonyLost "A settler became incapacitated. Restore an earlier checkpoint or restart and protect pantry supply before expanding."
      | ready && stable >= scenarioStableHours (campaignScenario c) * 1200 && elapsedTicks after c >= scenarioHours (campaignScenario c) * 1200 = SettlementSecured
      | otherwise = Ongoing

campaignJSON :: World -> CampaignState -> J.JSON
campaignJSON w c =
  obj
    [ ("scenario", str (scenarioId s)),
      ("title", str (scenarioTitle s)),
      ("brief", str (scenarioBrief s)),
      ("elapsedTicks", num (elapsedTicks w c)),
      ("elapsedHours", num (elapsedTicks w c `div` 1200)),
      ("requiredHours", num (scenarioHours s)),
      ("ending", str (show (campaignEnding c))),
      ("imported", J.JBool (campaignImported c)),
      ( "objectives",
        arr
          [ objective "water" "Establish a staffed supply chain" (campaignWaterExtracted c > 0 && campaignProduced c > 0) (show (campaignWaterExtracted c) ++ " ml extracted; " ++ show (campaignProduced c) ++ " g fresh food made"),
            objective "fresh-food" "Carry new food to the pantry and eat it" (campaignFreshTransit c && campaignFreshPantry c && campaignFreshConsumed c >= scenarioFreshFood s) (show (campaignFreshConsumed c) ++ " / " ++ show (scenarioFreshFood s) ++ " g freshly cooked ration consumed"),
            objective "capacity" "Build and use new physical capacity" (campaignExpanded c) "A finished warehouse/pantry/tank must receive stock, or a new production site must finish a real batch",
            objective "recovery" "Repair the disrupted kitchen" (campaignRecovered c) (if campaignDisrupted c then "Breakdown occurred; parts must arrive and a repair crew must finish" else "Kitchen disruption is announced for hour " ++ show (scenarioDisruptionHour s)),
            objective "stability" "Keep a full safety buffer across shifts" (campaignStableTicks c >= scenarioStableHours s * 1200) (show (campaignStableTicks c `div` 1200) ++ " / " ++ show (scenarioStableHours s) ++ " consecutive hours with healthy residents and at least two hours of pantry reserves"),
            objective "settlement" "Complete the authored survival horizon" (campaignEnding c == SettlementSecured) (show (elapsedTicks w c `div` 1200) ++ " / " ++ show (scenarioHours s) ++ " elapsed hours")
          ]
      )
    ]
  where
    s = campaignScenario c; objective key title done progress = obj [("id", str key), ("title", str title), ("complete", J.JBool done), ("progress", str progress)]
