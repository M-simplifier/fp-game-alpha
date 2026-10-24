module Logistics.MaintenanceTests (maintenanceTests) where

import Colony.Content (Content)
import Colony.Inventory
import Colony.Maintenance
import Colony.Transport (tryInventory)
import Colony.Types
import Colony.Units (Resource (..), qtyValue)
import Control.Monad (unless, void)
import Data.Map.Strict qualified as M

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

maintenanceTests :: Content -> IO ()
maintenanceTests content = do
  let colony = EntityId 1
      target = EntityId 2
      source = Owner Warehouse (EntityId 3)
      preferred = Owner MachineOutput (EntityId 4)
      fallback = Owner Warehouse (EntityId 5)
      tx = TxId 1 1 (BoundarySeq 1) P7 0
  facility <- must (newFacility content target "pump")
  ((ident, running), inventory) <-
    must $
      runInventory
        ( do
            addStorage source (Storage 1000 Nothing colony)
            addStorage preferred (Storage 250 (Just Parts) colony)
            addStorage fallback (Storage 250 (Just Parts) colony)
            void (mintLot tx InitialGrant Nothing Parts 1 source (SimTick 0) Nothing "first part")
            void (mintLot tx InitialGrant Nothing Parts 3 source (SimTick 1) Nothing "later parts")
            (ident, planned) <- planMaintenance content (SimTick 1) target source preferred (emptyMaintenance {maintenanceFacilities = M.singleton target facility})
            running <- startMaintenance ident 1 planned
            void (mintLot tx InitialGrant Nothing Stone 1000 source (SimTick 1) Nothing "source now full")
            pure (ident, running)
        )
        (emptyInventory content)
  let half = running {maintenanceJobs = M.adjust (\job -> job {maintenanceProgress = 30000}) ident (maintenanceJobs running)}
      blockedInventory = inventory {invStorage = M.adjust (\storage -> storage {storageCapacity = 0}) fallback (invStorage inventory)}
  (refusal, preserved) <- must (runInventory (tryInventory (cancelMaintenance tx ident half)) blockedInventory)
  unless (refusal == Left ReturnCapacityFull && preserved == blockedInventory) $
    fail "late cancellation capacity refusal leaked loss, returned stock, allocator IDs or ledger"
  (cancelled, returned) <- must (runInventory (cancelMaintenance tx ident half) inventory)
  let stock owner = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots returned), lotOwner lot == owner, lotResource lot == Parts]
      survivors = [lot | lot <- M.elems (invLots returned), lotResource lot == Parts]
  unless (stock preferred == 1 && stock fallback == 1 && stock (Owner MachineInput ident) == 0) $
    fail "physical cancellation did not split real survivors across deterministic destinations"
  unless (M.lookup (Parts, CancelledProcessLoss) (invLedger returned) == Just 2 && all (\lot -> lotBorn lot == SimTick 1 && lotProvenance lot == "later parts") survivors) $
    fail "cancellation rounded per lot or re-minted survivor metadata"
  unless (maybe False ((== MaintenanceCancelled) . maintenancePhase) (M.lookup ident (maintenanceJobs cancelled))) $
    fail "successful cancellation did not commit terminal state"
  must (validateMaintenance cancelled returned)
  putStrLn "Maintenance: aggregate loss, split physical returns and metadata; late return-capacity failure is atomic"
