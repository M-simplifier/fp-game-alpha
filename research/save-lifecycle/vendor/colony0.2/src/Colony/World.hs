{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Colony.World where
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Types
import Colony.Units(Resource(..))
import Colony.RNG
import Colony.Power
import Colony.Needs
import Colony.Transport
import Colony.Maintenance
import qualified Data.Set as S
import Control.DeepSeq (NFData)
import Control.Monad (unless)
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import GHC.Generics (Generic)

data CoreMode = Active | Paused | Abandoned | Faulted Failure deriving (Eq,Show,Read,Generic,NFData)
data Role = OwnerRole | OperatorRole | ViewerRole deriving (Eq,Show,Read,Generic,NFData)
data Participant = Participant {participantRole :: !Role,participantEpoch :: !Epoch} deriving (Eq,Show,Read,Generic,NFData)
data Site = Site
  {siteId :: !EntityId,siteRecipe :: !String,siteInput :: !Owner,siteOutput :: !Owner
  ,siteNatural :: !(M.Map String EntityId),siteWorkers :: !Integer,siteEnabled :: !Bool}
  deriving (Eq,Show,Read,Generic,NFData)
data Command = OrderProduction EntityId | CancelProduction EntityId | SetSiteEnabled EntityId Bool | RequestDelivery Owner Owner Resource Integer Integer | CancelDelivery EntityId | RequestMaintenance EntityId Owner Owner | CancelFacilityMaintenance EntityId
  deriving (Eq,Show,Read,Generic,NFData)
data OrderedCommand = OrderedCommand {commandOrdinal :: !Word64,commandId :: !CommandId,commandBody :: !Command}
  deriving (Eq,Show,Read,Generic,NFData)
data ManagementEvent = PauseWorld | ResumeWorld deriving (Eq,Show,Read,Generic,NFData)
data BoundaryHeader = BoundaryHeader
  {headerWorld :: !Word64,headerBranch :: !Word64,expectedBoundarySeq :: !BoundarySeq
  ,advanceSim :: !Bool,headerAuthority :: !String,headerRuleset :: !String}
  deriving (Eq,Show,Read,Generic,NFData)
data NativeInput = Boundary BoundaryHeader [OrderedCommand] [ManagementEvent]
  deriving (Eq,Show,Read,Generic,NFData)
data Outcome = Applied (Maybe EntityId) | CommandFailed Failure | AlreadyProcessed
  deriving (Eq,Show,Read,Generic,NFData)
data CommandReceipt = CommandReceipt
  {receiptCommand :: !CommandId,receiptBoundary :: !BoundarySeq,receiptOutcome :: !Outcome,receiptTx :: !TxId,receiptBody :: !Command}
  deriving (Eq,Show,Read,Generic,NFData)
data DomainEvent = JobPlanned EventId EntityId | JobStarted EventId EntityId | JobCompleted EventId EntityId | JobCancelled EventId EntityId | JobExpired EventId EntityId
  deriving (Eq,Show,Read,Generic,NFData)
data Diagnostic = FatalBoundaryRejected String | FaultDiagnostic Phase Failure [CommandId]
  deriving (Eq,Show,Read,Generic,NFData)
data ColonyOutput = ColonyOutput {outputEvents :: ![DomainEvent],outputReceipts :: ![CommandReceipt],outputDiagnostics :: ![Diagnostic]}
  deriving (Eq,Show,Read,Generic,NFData)
instance Semigroup ColonyOutput where
  ColonyOutput e r d <> ColonyOutput e' r' d'=ColonyOutput(e++e')(r++r')(d++d')
instance Monoid ColonyOutput where mempty=ColonyOutput [] [] []
data World = World
  {worldId :: !Word64,branchId :: !Word64,worldAuthority :: !String,worldRuleset :: !String
  ,simTick :: !SimTick,boundarySeq :: !BoundarySeq,worldRevision :: !Word64,worldMode :: !CoreMode
  ,worldContent :: !Content,worldInventory :: !Inventory,worldJobs :: !(M.Map EntityId Job),worldSites :: !(M.Map EntityId Site)
  ,worldJobSites :: !(M.Map EntityId EntityId),worldParticipants :: !(M.Map Word64 Participant)
  ,worldHighWater :: !(M.Map (Word64,Epoch) Word64),worldReceipts :: ![CommandReceipt]
  ,worldRng :: !RngStreams,worldRecentEvents :: ![DomainEvent]
  ,worldPowerGrids :: !(M.Map EntityId PowerGrid),worldSiteGrids :: !(M.Map EntityId EntityId)
  ,worldPoweredSites :: !(S.Set EntityId),worldWeather :: !Weather,worldNeeds :: !NeedsState,worldTransport :: !TransportState,worldMaintenance :: !MaintenanceState
  ,worldMaintenanceCrews :: !(M.Map EntityId Integer),worldOperatingFacilities :: !(S.Set EntityId),worldMaintenanceAttempts :: !Word64}
  deriving (Eq,Show,Read,Generic,NFData)

initialWorld :: Content -> World
initialWorld c=World 1 1 "development-authority-1" "red-dune-reference-0" (SimTick 0) (BoundarySeq 0) 0 Active c
  (emptyInventory c) M.empty M.empty M.empty (M.singleton 1(Participant OwnerRole(Epoch "development-authority-1" 1))) M.empty [] (initialRng 1) [] M.empty M.empty S.empty Clear (NeedsState M.empty M.empty) emptyTransport emptyMaintenance M.empty S.empty 0

validateWorld :: World -> Either Failure ()
validateWorld w=do
  validateInventory(worldInventory w)
  validateStorageProfile(worldInventory w)
  validateGlobalIds w
  validateTransport(worldTransport w)(worldInventory w)
  validateMaintenance(worldMaintenance w)(worldInventory w)
  validateMaintenanceContent w
  validateSites w
  either(Left . InvariantViolation)Right(validateRngStreams(worldRng w))
  mapM_ validatePowerGrid(M.elems(worldPowerGrids w))
  validateNeeds(worldNeeds w)(worldInventory w)
  mapM_ (\(site,grid)->unless(M.member site(worldSites w)&&M.member grid(worldPowerGrids w))(Left(InvariantViolation "dangling site power grid"))) (M.toList(worldSiteGrids w))
  validateJobs(worldJobs w)(worldInventory w)
  let transport=worldTransport w
      jobIds=S.unions[M.keysSet(worldJobs w),M.keysSet(transportRequests transport),M.keysSet(transportShipments transport),M.keysSet(transportRecoveries transport),M.keysSet(maintenanceJobs(worldMaintenance w))];inv=worldInventory w
  unless(all(`S.member`jobIds)(map quantityJob(M.elems(invQuantity inv))++map capacityJob(M.elems(invCapacity inv))++map naturalJob(M.elems(invNatural inv))))(Left(InvariantViolation "reservation references missing job"))
  unless(length(worldRecentEvents w)<=256)(Left(InvariantViolation "unbounded event history"))
  unless(length(worldReceipts w)<=16384)(Left(InvariantViolation "unbounded receipts"))
  mapM_ (\(jid,sid)->unless(M.member jid(worldJobs w)&&M.member sid(worldSites w))(Left(InvariantViolation "dangling job site"))) (M.toList(worldJobSites w))

-- Entity identity is global across subsystems. Storage keys are references to
-- sites/jobs where explicitly allowed, otherwise they define standalone storage entities.
validateGlobalIds :: World -> Either Failure ()
validateGlobalIds w=do
  let inv=worldInventory w
      grids=M.elems(worldPowerGrids w)
      transport=worldTransport w
      transportIds=M.keys(transportVehicles transport)++M.keys(transportRequests transport)++M.keys(transportShipments transport)++M.keys(transportRecoveries transport)
      primary=M.keys(maintenanceJobs(worldMaintenance w))++transportIds++inventoryAssetIds inv++M.keys(worldJobs w)++M.keys(worldSites w)++M.keys(worldPowerGrids w)++M.keys(needsResidents(worldNeeds w))++concatMap(\g->map solarId(gridSolar g)++map generatorId(gridGenerators g)++map batteryId(gridBatteries g))grids
      ownerIds=[ident|Owner _ ident<-M.keys(invStorage inv)]
      colonyIds=S.toList(S.fromList(map storageColony(M.elems(invStorage inv))++map residentColony(M.elems(needsResidents(worldNeeds w)))))
      allIds=primary++ownerIds++colonyIds
      check b reason=unless b(Left(InvariantViolation reason))
      generators=concatMap(map generatorId.gridGenerators)grids
  check(length primary==S.size(S.fromList primary)) "duplicate global entity ID"
  check(all(\(EntityId ident)->ident<invNextId inv)allIds) "global allocator would reuse entity ID"
  check(all(\ident->ident `notElem` primary&&ident `notElem` ownerIds)colonyIds) "global colony ID collision"
  mapM_(\(Owner kind ident)->whenKnown primary ident $ do
    let allowed=case kind of
          MachineInput->M.member ident(maintenanceJobs(worldMaintenance w))||M.member ident(worldJobs w)||M.member ident(worldSites w)||ident `elem` generators
          MachineOutput->M.member ident(worldSites w)
          ConstructionEscrow->M.member ident(worldJobs w)||M.member ident(transportRecoveries transport)
          Vehicle->M.member ident(transportVehicles transport)
          RecoveryHold->M.member ident(worldJobs w)
          _->False
    check allowed "storage owner aliases unrelated global entity") (M.keys(invStorage inv))
  where whenKnown ids ident action=if ident `elem` ids then action else Right()

validateSites :: World -> Either Failure ()
validateSites w=mapM_ validate(M.toList(worldSites w)) where
  inventory=worldInventory w
  check b reason=unless b(Left(InvariantViolation reason))
  validate(ident,site)=do
    check(ident==siteId site) "site key mismatch"
    recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(siteRecipe site))
    check(M.member(siteInput site)(invStorage inventory)&&M.member(siteOutput site)(invStorage inventory)) "site endpoint missing"
    check(siteWorkers site>=0) "negative site workers"
    mapM_(\kind->do
      source<-maybe(Left(InvalidReference "site natural source missing"))Right(M.lookup kind(siteNatural site))
      deposit<-maybe(Left(InvalidReference "site natural deposit missing"))Right(M.lookup source(invDeposits inventory))
      definition<-maybe(Left(InvalidReference "natural content missing"))Right(M.lookup kind(contentNaturalSources(worldContent w)))
      check(depositKind deposit==kind&&depositResource deposit==naturalSourceResource definition) "site natural source kind/resource mismatch") (M.keys(recipeNaturalSources recipe))

-- Inventory's small-model capacity parameter remains configurable; playable
-- World profiles may not silently exceed the normative owner-class limits.
validateStorageProfile :: Inventory -> Either Failure ()
validateStorageProfile inv=mapM_ check(M.toList(invStorage inv)) where
  check(Owner kind _,storage)=do
    let limit=case kind of Warehouse->2000000;MachineInput->400000;MachineOutput->400000;Pantry->400000;Tank->1000000;GroundCache->2000000;_->9000000000000
    unless(storageCapacity storage<=limit)(Left(InvariantViolation "storage exceeds owner-class capacity"))
    whenTank kind storage
  whenTank Tank storage=unless(storageResource storage `elem` [Just Water,Just Brine])(Left(InvariantViolation "tank requires a single fluid type"))
  whenTank _ _=Right()

validateMaintenanceContent :: World -> Either Failure ()
validateMaintenanceContent w=do
  let state=worldMaintenance w;grids=M.elems(worldPowerGrids w)
      known=S.fromList(M.keys(worldSites w)++concatMap(\g->map solarId(gridSolar g)++map generatorId(gridGenerators g)++map batteryId(gridBatteries g))grids)
      check b message=unless b(Left(InvariantViolation message))
  mapM_(\facility->do
    check(S.member(facilityId facility)known) "maintenance target not a site/power device"
    building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)(facilityBuilding facility))
    check(facilityPeriod facility==buildingMaintenancePeriod building) "maintenance period differs from content") (M.elems(maintenanceFacilities state))
  mapM_(\(ident,crew)->check(M.member ident(maintenanceFacilities state)&&crew>=0&&crew<=1) "maintenance crew assignment invalid") (M.toList(worldMaintenanceCrews w))
  mapM_(\job->do
    facility<-maybe(Left(InvariantViolation "maintenance target missing"))Right(M.lookup(maintenanceTarget job)(maintenanceFacilities state))
    building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)(facilityBuilding facility))
    let factor=if maintenanceKind job==BrokenRepair then 2 else 1
    check(maintenanceParts job==buildingMaintenanceParts building*factor&&maintenanceRequired job==60000*factor) "maintenance cost/work snapshot differs from content") (M.elems(maintenanceJobs state))
  check(worldMaintenanceAttempts w<=256) "maintenance allocation fuel exceeded"
