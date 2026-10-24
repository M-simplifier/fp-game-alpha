{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module RedDune.Policies where

import Colony.Construction qualified as C
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.S01Fixture
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.DeepSeq (NFData)
import Data.Map.Strict qualified as M
import GHC.Generics (Generic)

data DeliveryPolicy = DeliveryPolicy
  { policyId :: !String,
    policySources :: ![Owner],
    policyDestination :: !Owner,
    policyResource :: !Resource,
    policyTarget :: !Integer,
    policyBatch :: !Integer,
    policyPriority :: !Integer,
    policyEnabled :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

data Policies = Policies
  { policiesEnabled :: !Bool,
    productionSites :: ![EntityId],
    deliveryPolicies :: ![DeliveryPolicy],
    assistConstruction :: !Bool,
    assistMaintenance :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

emptyPolicies :: Policies
emptyPolicies = Policies False [] [] False False

survivalPolicies :: S01Descriptor -> Policies
survivalPolicies d =
  Policies
    True
    [s01Pump d, s01Farm d, s01Kitchen d]
    [ route "pantry-water" (pump : stores) (s01Pantry d) Water 120000 40000 0,
      route "pantry-food" (kitchen : stores) (s01Pantry d) Ration 60000 18000 0,
      route "farm-water" (pump : stores) farm Water 120000 60000 1,
      route "kitchen-crops" [Owner MachineOutput (s01Farm d)] kitchenInput Crops 40000 20000 1,
      route "kitchen-water" (pump : stores) kitchenInput Water 20000 10000 1,
      route "kitchen-fuel" stores kitchenInput Fuel 6000 2000 1,
      route "farm-biomass" [Owner MachineOutput (s01Farm d)] (head stores) Biomass 200000 10000 3,
      route "kitchen-waste" [kitchen] (head stores) Waste 200000 12000 3
    ]
    True
    True
  where
    stores = s01Warehouses d
    pump = Owner MachineOutput (s01Pump d)
    kitchen = Owner MachineOutput (s01Kitchen d)
    farm = Owner MachineInput (s01Farm d)
    kitchenInput = Owner MachineInput (s01Kitchen d)
    route key sources destination resource target batch priority = DeliveryPolicy key sources destination resource target batch priority True

physical :: World -> Owner -> Resource -> Integer
physical world owner resource = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots (worldInventory world)), lotOwner lot == owner, lotResource lot == resource, usable (simTick world) lot]

available :: World -> Owner -> Resource -> Integer
available world owner resource = poolAvailable (simTick world) [owner] resource (worldInventory world)

-- Each policy emits at most one actual delivery. Outstanding unreceived stock is
-- counted once; reservations remove stock from candidate sources. Commands are
-- evaluated sequentially by Game, so competing policies see previous reservations.
deliveryCommand :: World -> DeliveryPolicy -> Maybe Command
deliveryCommand world p
  | not (policyEnabled p) || missing < min (policyBatch p) (policyTarget p) || missing <= 0 = Nothing
  | otherwise = case [(source, min limit (available world source (policyResource p))) | source <- policySources p, source /= policyDestination p, available world source (policyResource p) > 0] of
      (source, n) : _ | n > 0 -> Just (RequestDelivery source (policyDestination p) (policyResource p) n (policyPriority p))
      _ -> Nothing
  where
    inv = worldInventory world
    resource = policyResource p
    missing = policyTarget p - physical world (policyDestination p) resource - incomingDeliveryQuantity (worldTransport world) (policyDestination p) resource
    limit = min missing (min (policyBatch p) (freeWeight inv (policyDestination p) `div` max 1 (weightOf inv resource 1)))

productionCommand :: World -> EntityId -> Maybe Command
productionCommand world ident = do
  site <- M.lookup ident (worldSites world)
  recipe <- M.lookup (siteRecipe site) (contentRecipes (worldContent world))
  let live = any (\job -> not (terminal job) && M.lookup (jobId job) (worldJobSites world) == Just ident) (M.elems (worldJobs world))
      enough = all (\(r, q) -> available world (siteInput site) r >= q) (M.toList (recipeInputs recipe))
      outputWeight = sum [weightOf (worldInventory world) r q | (r, q) <- M.toList (recipeOutputs recipe)]
      room = freeWeight (worldInventory world) (siteOutput site) >= outputWeight
      limited = all (\(r, q) -> physical world (siteOutput site) r < 3 * q) (M.toList (recipeOutputs recipe))
  if siteEnabled site && not live && enough && room && limited && not (facilityStopped (worldMaintenance world) ident)
    then Just (OrderProduction ident)
    else Nothing

constructionPolicies :: S01Descriptor -> World -> [DeliveryPolicy]
constructionPolicies descriptor world = case worldM1 world of
  Nothing -> []
  Just state ->
    [ DeliveryPolicy ("construction-" ++ show (C.constructionSiteId job) ++ "-" ++ resourceKey resource) (s01Warehouses descriptor) (C.constructionInput job) resource cost cost 2 True
    | job <- M.elems (C.constructionJobs (m1Construction state)),
      not (C.constructionTerminal job),
      C.constructionPhase job /= C.ConstructionRunning,
      (resource, cost) <- M.toList (C.constructionCost (C.constructionSnapshot job))
    ]

-- New warehouses become useful reserve capacity only after ordinary carts have
-- physically delivered water. These are player-enabled construction policies.
reservePolicies :: S01Descriptor -> World -> [DeliveryPolicy]
reservePolicies d world =
  [ DeliveryPolicy ("reserve-" ++ show ident) [Owner MachineOutput (s01Pump d)] owner Water 60000 30000 3 True
  | owner@(Owner Warehouse ident) <- M.keys (invStorage (worldInventory world)),
    owner `notElem` s01Warehouses d
  ]

maintenanceDeliveryPolicies :: S01Descriptor -> World -> [DeliveryPolicy]
maintenanceDeliveryPolicies d world =
  [ DeliveryPolicy ("parts-" ++ show (facilityId facility)) (s01Warehouses d) (siteInput site) Parts amount amount 0 True
  | facility <- M.elems (maintenanceFacilities (worldMaintenance world)),
    maintenanceStatus facility /= Operational,
    Just site <- [M.lookup (facilityId facility) (worldSites world)],
    Just building <- [M.lookup (facilityBuilding facility) (contentBuildings (worldContent world))],
    let amount = buildingMaintenanceParts building * (if maintenanceStatus facility == FacilityBroken then 2 else 1),
    amount > 0
  ]

maintenanceCommands :: World -> [Command]
maintenanceCommands world =
  [ RequestMaintenance (facilityId facility) (siteInput site) (siteInput site)
  | facility <- M.elems (maintenanceFacilities state),
    maintenanceStatus facility /= Operational,
    Just site <- [M.lookup (facilityId facility) (worldSites world)],
    Just building <- [M.lookup (facilityBuilding facility) (contentBuildings (worldContent world))],
    let amount = buildingMaintenanceParts building * (if maintenanceStatus facility == FacilityBroken then 2 else 1),
    amount > 0,
    available world (siteInput site) Parts >= amount,
    not (any (\job -> maintenanceTarget job == facilityId facility && not (maintenanceTerminal job)) (M.elems (maintenanceJobs state)))
  ]
  where
    state = worldMaintenance world

-- Reserve residents 11+ in every shift service one construction or maintenance
-- task at a time. Reassignment is an explicit sequence of ordinary roster commands.
serviceRosterCommands :: S01Descriptor -> World -> [Command]
serviceRosterCommands d world = case worldM1 world of
  Nothing -> []
  Just state ->
    let wf = m1Workforce state
        repairs = [W.MaintainJob (maintenanceJobId job) | job <- M.elems (maintenanceJobs (worldMaintenance world)), not (maintenanceTerminal job)]
        builds = [W.ConstructSite (C.constructionSiteId job) | job <- M.elems (C.constructionJobs (m1Construction state)), not (C.constructionTerminal job)]
        chosen = take 1 (repairs ++ builds)
        service target = case target of W.MaintainJob {} -> True; W.ConstructSite {} -> True; _ -> False
        removals = [AssignWorkers target shift [] | ((target, shift), names) <- M.toList (W.workforceRosters wf), service target, target `notElem` chosen, not (null names)]
        additions =
          [ AssignWorkers target shift names
          | target <- chosen,
            (shift, people) <- M.toList (s01ShiftResidents d),
            let names = take (case target of W.MaintainJob {} -> 1; _ -> 2) (drop 11 people),
            M.lookup (target, shift) (W.workforceRosters wf) /= Just names
          ]
     in removals ++ additions

policyStatus :: World -> DeliveryPolicy -> (String, String)
policyStatus world p
  | not (policyEnabled p) = ("disabled", "Disabled by player")
  | incoming > 0 = ("deliveryInFlight", "Reserved stock is travelling by cart; no duplicate reservation is made")
  | missing < min (policyBatch p) (policyTarget p) || missing <= 0 = ("bufferSatisfied", "Stock remains inside the configured replenishment band")
  | freeWeight inv (policyDestination p) <= 0 = ("destinationFull", "Destination capacity is fully occupied or reserved")
  | all (\owner -> available world owner (policyResource p) <= 0) (policySources p) = ("sourceEmpty", "No unreserved usable stock at the configured physical sources")
  | otherwise = ("ready", "Ready to reserve the next physical delivery on the policy cadence")
  where
    inv = worldInventory world
    incoming = incomingDeliveryQuantity (worldTransport world) (policyDestination p) (policyResource p)
    missing = policyTarget p - physical world (policyDestination p) (policyResource p) - incoming
