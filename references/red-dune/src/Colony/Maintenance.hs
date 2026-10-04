{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
-- | Pure maintenance state. Facility IDs reference existing stationary buildings;
-- they are not separately allocated entities. Each maintenance job is a fresh
-- global entity and owns exactly one MachineInput WIP storage alias.
module Colony.Maintenance where

import Colony.Content
import Colony.Inventory
import Colony.Power (Weather(..))
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict (get, gets)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import GHC.Generics (Generic)

data Facility = Facility
  { facilityId :: !EntityId, facilityBuilding :: !String
  , facilityAge :: !Integer, facilityCondition :: !Integer, facilityPeriod :: !Integer }
  deriving (Eq,Show,Read,Generic,NFData)
data FacilityStatus = Operational | MaintenanceWarning | MaintenanceDue | FacilityBroken
  deriving (Eq,Show,Read,Generic,NFData)
data MaintenanceKind = PreventiveMaintenance | BrokenRepair
  deriving (Eq,Show,Read,Generic,NFData)
data MaintenancePhase = MaintenancePlanned | MaintenanceRunning | MaintenanceCompleted | MaintenanceCancelled
  deriving (Eq,Show,Read,Generic,NFData)
data MaintenanceJob = MaintenanceJob
  { maintenanceJobId :: !EntityId, maintenanceTarget :: !EntityId
  , maintenanceSource :: !Owner, maintenanceReturn :: !Owner
  , maintenanceKind :: !MaintenanceKind, maintenancePhase :: !MaintenancePhase
  , maintenanceBlocked :: !(Maybe Failure), maintenanceParts :: !Integer
  , maintenanceProgress :: !Integer, maintenanceRequired :: !Integer, maintenanceTerminalCount :: !Integer }
  deriving (Eq,Show,Read,Generic,NFData)
data MaintenanceState = MaintenanceState
  { maintenanceFacilities :: !(M.Map EntityId Facility), maintenanceJobs :: !(M.Map EntityId MaintenanceJob) }
  deriving (Eq,Show,Read,Generic,NFData)

-- D-MAINT-LEDGER in IMPLEMENTATION-DECISIONS.md classifies completed Parts
-- as RecipeInput with Maintenance or Repair subreason, preserving the closed
-- top-level reason vocabulary and keeping construction consumption distinct.
maintenanceCompletionReason :: Reason
maintenanceCompletionReason = RecipeInput

emptyMaintenance :: MaintenanceState
emptyMaintenance = MaintenanceState M.empty M.empty

newFacility :: Content -> EntityId -> String -> Either Failure Facility
newFacility content ident name = do
  building <- either (Left . InvalidReference) Right (lookupBuilding content name)
  let facility = Facility ident name 0 1000 (buildingMaintenancePeriod building)
  validateFacility facility
  pure facility

validateFacility :: Facility -> Either Failure ()
validateFacility facility = do
  let check b message = unless b (Left (InvariantViolation message))
  let EntityId numericId = facilityId facility
  check (numericId > 0) "facility ID is zero"
  check (not (null (facilityBuilding facility))) "empty facility building"
  check (facilityAge facility >= 0 && facilityAge facility <= quantityMax) "facility age bounds"
  check (facilityPeriod facility >= 0 && facilityPeriod facility <= quantityMax) "facility period bounds"
  check (facilityCondition facility >= 0 && facilityCondition facility <= 1000) "facility condition bounds"
  check (facilityPeriod facility /= 0 || facilityAge facility == 0) "maintenance-exempt facility accumulated age"

maintenanceStatus :: Facility -> FacilityStatus
maintenanceStatus facility
  | facilityCondition facility == 0 = FacilityBroken
  | period == 0 = Operational
  | age * 2 >= period * 3 = FacilityBroken
  | age >= period = MaintenanceDue
  | age * 5 >= period * 4 = MaintenanceWarning
  | otherwise = Operational
  where age = facilityAge facility; period = facilityPeriod facility

-- Work-credit modifier. Power applies the same percentage to generation or
-- battery transfer limits, never to demand, stored energy capacity, or fuel.
maintenancePct :: Facility -> Integer
maintenancePct facility = case maintenanceStatus facility of
  FacilityBroken -> 0
  MaintenanceDue -> 70
  _ -> 100

maintenanceTerminal :: MaintenanceJob -> Bool
maintenanceTerminal job = maintenancePhase job `elem` [MaintenanceCompleted,MaintenanceCancelled]

maintenanceWipOwner :: MaintenanceJob -> Owner
maintenanceWipOwner job = Owner MachineInput (maintenanceJobId job)

facilityStopped :: MaintenanceState -> EntityId -> Bool
facilityStopped state ident =
  maybe False ((==FacilityBroken) . maintenanceStatus) (M.lookup ident (maintenanceFacilities state)) ||
  any (\job -> maintenanceTarget job == ident && maintenancePhase job == MaintenanceRunning) (M.elems (maintenanceJobs state))

-- Caller supplies the entities that actually operated in this simulation tick.
-- False means a command-only/paused boundary and must be completely inert.
-- Hourly sandstorm damage also affects stopped eligible outdoor facilities.
advanceFacilities :: Bool -> SimTick -> Weather -> S.Set EntityId -> MaintenanceState -> Either Failure MaintenanceState
advanceFacilities False _ _ _ state = Right state
advanceFacilities True (SimTick tick) weather operated state = do
  facilities <- mapM advance (maintenanceFacilities state)
  pure state {maintenanceFacilities=facilities}
  where
    advance facility = do
      validateFacility facility
      let runs = S.member (facilityId facility) operated && not (facilityStopped state (facilityId facility)) && facilityPeriod facility > 0
          age = facilityAge facility + if runs then 1 else 0
          storm = weather == Sandstorm && tick > 0 && tick `mod` 1200 == 0 && facilityBuilding facility `elem` ["solar","pump","brine_pump","mine","quarry","generator"]
          next = facility {facilityAge=age,facilityCondition=max 0 (facilityCondition facility - if storm then 20 else 0)}
      unless (age <= quantityMax) (Left CounterOverflow)
      validateFacility next
      pure next

lookupMaintenance :: EntityId -> MaintenanceState -> InventoryTx MaintenanceJob
lookupMaintenance ident state = maybe (throwTx TargetGone) pure (M.lookup ident (maintenanceJobs state))

checkMaintenance :: MaintenanceState -> InventoryTx ()
checkMaintenance state = get >>= either throwTx pure . validateMaintenance state

putMaintenance :: MaintenanceJob -> MaintenanceState -> MaintenanceState
putMaintenance job state = state {maintenanceJobs=M.insert (maintenanceJobId job) job (maintenanceJobs state)}

-- Quantity is reserved while planned, but remains physically at the source.
-- No source or sink is posted until work finishes or is cancelled after start.
planMaintenance :: Content -> SimTick -> EntityId -> Owner -> Owner -> MaintenanceState -> InventoryTx (EntityId,MaintenanceState)
planMaintenance content tick target source destination state = do
  checkMaintenance state
  facility <- maybe (throwTx TargetGone) pure (M.lookup target (maintenanceFacilities state))
  building <- either (throwTx . InvalidReference) pure (lookupBuilding content (facilityBuilding facility))
  require (buildingMaintenancePeriod building == facilityPeriod facility) (InvariantViolation "facility content period mismatch")
  require (facilityPeriod facility > 0) (InvalidReference "MaintenanceNotRequired")
  require (all (\job -> maintenanceTarget job /= target || maintenanceTerminal job) (M.elems (maintenanceJobs state))) (InvalidReference "facility already has active maintenance")
  inventory <- get
  sourceStorage <- maybe (throwTx MissingOwner) pure (M.lookup source (invStorage inventory))
  returnStorage <- maybe (throwTx MissingOwner) pure (M.lookup destination (invStorage inventory))
  require (storageColony sourceStorage == storageColony returnStorage) (InvalidReference "maintenance endpoints cross colony")
  require (maybe True (==Parts) (storageResource returnStorage)) ResourceMismatch
  let broken = maintenanceStatus facility == FacilityBroken
      multiplier = if broken then 2 else 1
      parts = buildingMaintenanceParts building * multiplier
      required = buildingMaintenanceWorkTicks building * 100 * multiplier
  require (parts > 0 && parts <= quantityMax && required > 0 && required <= quantityMax) InvalidQuantity
  require (M.findWithDefault Nothing Parts (invShelf inventory) == Nothing) (InvariantViolation "parts must not expire")
  ident <- freshId
  let job = MaintenanceJob ident target source destination (if broken then BrokenRepair else PreventiveMaintenance) MaintenancePlanned Nothing parts 0 required 0
      wip = maintenanceWipOwner job
      -- Room for repair promotion if the facility breaks while awaiting a crew.
      capacity = weightOf inventory Parts (buildingMaintenanceParts building * 2)
  require (capacity > 0 && capacity <= quantityMax) InvalidQuantity
  addStorage wip (Storage capacity (Just Parts) (storageColony sourceStorage))
  reserveQuantity tick ident source Parts parts
  let next = putMaintenance job state
  checkMaintenance next
  pure (ident,next)

-- Crew counts are explicit static fixture input until resident assignment exists.
-- Crew absence preserves the planned phase and reservations, with NoWorker.
startMaintenance :: EntityId -> Integer -> MaintenanceState -> InventoryTx MaintenanceState
startMaintenance ident crew state = do
  checkMaintenance state
  require (crew >= 0 && crew <= quantityMax) InvalidQuantity
  job <- lookupMaintenance ident state
  require (not (maintenanceTerminal job)) AlreadyTerminal
  require (maintenancePhase job == MaintenancePlanned) (InvalidReference "maintenance already running")
  if crew == 0 then pure (putMaintenance job {maintenanceBlocked=Just (InvalidReference "NoWorker")} state) else do
    facility <- maybe (throwTx TargetGone) pure (M.lookup (maintenanceTarget job) (maintenanceFacilities state))
    let promote = maintenanceKind job == PreventiveMaintenance && maintenanceStatus facility == FacilityBroken
    promoted <- if promote then do
      let parts = maintenanceParts job * 2; required = maintenanceRequired job * 2
      require (parts <= quantityMax && required <= quantityMax) InvalidQuantity
      -- Parts cannot expire. SimTick 0 is equivalent for this resource, and
      -- preserves the public start API without fabricating a current clock.
      reserveQuantity (SimTick 0) ident (maintenanceSource job) Parts (maintenanceParts job)
      pure job {maintenanceKind=BrokenRepair,maintenanceParts=parts,maintenanceRequired=required}
      else pure job
    moveReserved ident (maintenanceSource promoted) (maintenanceWipOwner promoted)
    let next = putMaintenance promoted {maintenancePhase=MaintenanceRunning,maintenanceBlocked=Nothing} state
    checkMaintenance next
    pure next

-- Exactly one maintenance crew is required; extra supplied crew never multiplies
-- work. Caller provides one bounded, integer credit after workforce modifiers.
-- Broken status of the TARGET does not zero the repair crew's credit.
workMaintenance :: TxId -> EntityId -> Integer -> Integer -> MaintenanceState -> InventoryTx MaintenanceState
workMaintenance tx ident crew credit state = do
  checkMaintenance state
  require (crew >= 0 && crew <= quantityMax && credit >= 0 && credit <= 130) InvalidQuantity
  job <- lookupMaintenance ident state
  require (not (maintenanceTerminal job)) AlreadyTerminal
  require (maintenancePhase job == MaintenanceRunning) (InvalidReference "maintenance is not running")
  if crew == 0 then pure (putMaintenance job {maintenanceBlocked=Just (InvalidReference "NoWorker")} state) else do
    let progress = min (maintenanceRequired job) (maintenanceProgress job + credit)
        credited = job {maintenanceProgress=progress,maintenanceBlocked=Nothing}
    if progress < maintenanceRequired job then pure (putMaintenance credited state) else do
      let detail = case maintenanceKind job of PreventiveMaintenance -> Maintenance; BrokenRepair -> Repair
      -- Exact WIP was checked above; Parts never expire, so the selector clock
      -- is irrelevant and no temporal state is fabricated by this pure API.
      consumeFreeDetailed tx maintenanceCompletionReason (Just detail) (Just ident) (SimTick 0) (maintenanceWipOwner job) Parts (maintenanceParts job)
      releaseJob ident
      let completed = credited {maintenancePhase=MaintenanceCompleted,maintenanceTerminalCount=1}
          repaired facility = facility {facilityAge=0,facilityCondition=1000}
          next = (putMaintenance completed state) {maintenanceFacilities=M.adjust repaired (maintenanceTarget job) (maintenanceFacilities state)}
      checkMaintenance next
      pure next

-- Preferred return endpoint then same-colony warehouses, in global ID order.
-- Spatial GroundCache placement is not modelled here; lack of room fails atomically.
maintenanceReturnOwners :: MaintenanceJob -> Inventory -> [Owner]
maintenanceReturnOwners job inventory = maintenanceReturn job :
  [owner | (owner@(Owner Warehouse _),storage) <- M.toAscList (invStorage inventory)
         , owner /= maintenanceReturn job, Just (storageColony storage) == colony]
  where colony = storageColony <$> M.lookup (maintenanceReturn job) (invStorage inventory)

cancelMaintenance :: TxId -> EntityId -> MaintenanceState -> InventoryTx MaintenanceState
cancelMaintenance tx ident state = do
  checkMaintenance state
  job <- lookupMaintenance ident state
  require (not (maintenanceTerminal job)) AlreadyTerminal
  releaseJob ident
  when (maintenancePhase job == MaintenanceRunning) $ do
    inventory <- get
    let lots = [lot | lot <- M.elems (invLots inventory),lotOwner lot == maintenanceWipOwner job]
        actual = sum (map (qtyValue . lotQty) lots)
        loss = actual * maintenanceProgress job `div` maintenanceRequired job
    -- Floor once per resource input, not once per split lot. Loss and returns
    -- always come from the actual WIP; no recipe quantity is ever re-minted.
    lose loss lots
    survivors <- gets (filter ((==maintenanceWipOwner job) . lotOwner) . M.elems . invLots)
    forM_ survivors $ \lot -> returnLot job (lotId lot) (qtyValue (lotQty lot))
  let next = putMaintenance job {maintenancePhase=MaintenanceCancelled,maintenanceBlocked=Nothing,maintenanceTerminalCount=1} state
  checkMaintenance next
  pure next
  where
    lose _ [] = pure ()
    lose amount (lot:lots) = do
      let n = min amount (qtyValue (lotQty lot))
      when (n > 0) $ do
        _ <- removeFromLot (lotId lot) n
        record tx CancelledProcessLoss (Just ident) Parts n (Just (lotOwner lot)) Nothing
      lose (amount-n) lots
    returnLot _ _ 0 = pure ()
    returnLot job lotIdToReturn remaining = do
      inventory <- get
      let eligible owner = case M.lookup owner (invStorage inventory) of
            Just storage | maybe True (==Parts) (storageResource storage) -> max 0 (freeWeight inventory owner `div` M.findWithDefault 1 Parts (invLoad inventory))
            _ -> 0
          destinations = [(owner,min remaining (eligible owner)) | owner <- maintenanceReturnOwners job inventory,eligible owner > 0]
      case destinations of
        [] -> throwTx ReturnCapacityFull
        (owner,n):_ -> do
          transferSelected owner [(lotIdToReturn,n)]
          returnLot job lotIdToReturn (remaining-n)

validateMaintenance :: MaintenanceState -> Inventory -> Either Failure ()
validateMaintenance state inventory = do
  let check b message = unless b (Left (InvariantViolation message))
      jobs = maintenanceJobs state
      facilities = maintenanceFacilities state
      activeTargets = [maintenanceTarget job | job <- M.elems jobs,not (maintenanceTerminal job)]
  check (length activeTargets == S.size (S.fromList activeTargets)) "duplicate active facility maintenance"
  check (S.null (M.keysSet jobs `S.intersection` M.keysSet facilities)) "maintenance job aliases facility"
  forM_ (M.toList facilities) $ \(ident,facility) -> do
    check (ident == facilityId facility) "facility key mismatch"
    let EntityId numericId = ident
    check (numericId < invNextId inventory) "facility ID outside global allocator"
    validateFacility facility
  forM_ (M.toList jobs) $ \(ident,job) -> do
    check (ident == maintenanceJobId job) "maintenance job key mismatch"
    let EntityId numericId = ident
    check (numericId > 0 && numericId < invNextId inventory) "maintenance job ID outside global allocator"
    facility <- maybe (Left (InvariantViolation "maintenance target missing")) Right (M.lookup (maintenanceTarget job) facilities)
    check (facilityPeriod facility > 0) "maintenance on exempt facility"
    check (maintenanceParts job > 0 && maintenanceParts job <= quantityMax && maintenanceRequired job > 0 && maintenanceRequired job <= quantityMax) "maintenance quantity/work bounds"
    check (maintenanceProgress job >= 0 && maintenanceProgress job <= maintenanceRequired job) "maintenance progress bounds"
    check (maintenanceTerminalCount job == if maintenanceTerminal job then 1 else 0) "maintenance terminal uniqueness"
    check (maintenancePhase job /= MaintenanceCompleted || maintenanceProgress job == maintenanceRequired job) "completed maintenance lacks full credit"
    check (maintenancePhase job /= MaintenancePlanned || maintenanceProgress job == 0) "planned maintenance has credit"
    source <- maybe (Left (InvariantViolation "maintenance source missing")) Right (M.lookup (maintenanceSource job) (invStorage inventory))
    destination <- maybe (Left (InvariantViolation "maintenance return missing")) Right (M.lookup (maintenanceReturn job) (invStorage inventory))
    wip <- maybe (Left (InvariantViolation "maintenance WIP missing")) Right (M.lookup (maintenanceWipOwner job) (invStorage inventory))
    check (storageColony source == storageColony destination && storageColony source == storageColony wip && storageResource wip == Just Parts) "maintenance endpoint mismatch"
    let quantities = [reservation | reservation <- M.elems (invQuantity inventory),quantityJob reservation == ident]
        physical = M.fromListWith (+) [(lotResource lot,qtyValue (lotQty lot)) | lot <- M.elems (invLots inventory),lotOwner lot == maintenanceWipOwner job]
        expected = M.singleton Parts (maintenanceParts job)
    check (all ((/=ident) . capacityJob) (M.elems (invCapacity inventory)) && all ((/=ident) . naturalJob) (M.elems (invNatural inventory))) "maintenance retained unexpected reservation"
    forM_ quantities $ \reservation -> do
      lot <- maybe (Left (InvariantViolation "maintenance reservation lot missing")) Right (M.lookup (quantityLot reservation) (invLots inventory))
      check (lotResource lot == Parts && lotOwner lot == maintenanceSource job && lotExpires lot == Nothing) "maintenance reservation differs from parts source"
    let wipLots = [lot | lot <- M.elems (invLots inventory),lotOwner lot == maintenanceWipOwner job]
    check (all ((==Nothing) . lotExpires) wipLots) "maintenance parts cannot expire"
    case maintenancePhase job of
      MaintenancePlanned -> do
        check (M.null physical) "planned maintenance already has WIP"
        check (sum (map (qtyValue . quantityAmount) quantities) == maintenanceParts job) "planned maintenance reservation differs from parts snapshot"
      MaintenanceRunning -> do
        check (physical == expected) "maintenance WIP differs from parts snapshot"
        check (null quantities) "running maintenance retains quantity reservation"
      _ -> do
        check (M.null physical) "terminal maintenance retains physical WIP"
        check (null quantities) "terminal maintenance retains quantity reservation"
