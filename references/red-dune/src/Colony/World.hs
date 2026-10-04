{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Colony.World where
import Colony.Content
import Colony.ContentCodec(knownRecipeCatalogs)
import Colony.Inventory
import Colony.Jobs
import Colony.Types
import Colony.Units(Resource(..),allResources,qtyValue)
import Colony.RNG
import Colony.Power
import Colony.Needs
import Colony.Transport
import Colony.Maintenance
import Colony.M1State
import Colony.Pickup(validatePickups)
import Colony.Ruleset(isM1Ruleset)
import Colony.M1Infrastructure(spatialPorts,spatialRoadCaches,nodeOf)
import Colony.Topology(roadNodes)
import qualified Colony.Space as Space
import qualified Colony.Workforce as Workforce
import qualified Colony.Construction as Construction
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
  | PlaceConstructionPlan EntityId Space.PlacementShape Integer (Maybe EntityId)
  | CancelConstructionPlan EntityId Word64
  | AssignWorkers Workforce.WorkTarget Integer [EntityId]
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
  | ConstructionPlanned EventId EntityId | ConstructionStarted EventId EntityId
  | ConstructionCompleted EventId EntityId | ConstructionCancelled EventId EntityId
  | WorkersAssigned EventId Workforce.WorkTarget
  | GroundCacheRetired EventId Owner Space.Tile
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
  ,worldMaintenanceCrews :: !(M.Map EntityId Integer),worldOperatingFacilities :: !(S.Set EntityId),worldMaintenanceAttempts :: !Word64,worldM1 :: !(Maybe M1State)}
  deriving (Eq,Show,Read,Generic,NFData)

-- Legacy reference fixture constructor, retained for byte-identical0.2 tests.
-- New interactive initialization selects currentV1Ruleset in UIFixture.
initialWorld :: Content -> World
initialWorld c=World 1 1 "development-authority-1" "red-dune-reference-0" (SimTick 0) (BoundarySeq 0) 0 Active c
  (emptyInventory c) M.empty M.empty M.empty (M.singleton 1(Participant OwnerRole(Epoch "development-authority-1" 1))) M.empty [] (initialRng 1) [] M.empty M.empty S.empty Clear (NeedsState M.empty M.empty) emptyTransport emptyMaintenance M.empty S.empty 0 Nothing

validateWorld :: World -> Either Failure ()
validateWorld w=do
  unless(isM1Ruleset(worldRuleset w)==maybe False(const True)(worldM1 w))(Left(InvariantViolation "schema/profile M1 state mismatch"))
  unless(all(commandAllowedInRuleset(worldRuleset w).receiptBody)(worldReceipts w)&&all(eventAllowedInRuleset(worldRuleset w))(worldRecentEvents w))(Left(InvariantViolation "profile contains unsupported command/event vocabulary"))
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
  case worldM1 w of
    Nothing->pure()
    Just state->do
      catalog<-workTargetCatalog w
      validateM1State(worldContent w)(worldInventory w)(worldNeeds w)(simTick w)catalog state
      validateM1WorldLinks w state
  mapM_ (\(site,grid)->unless(M.member site(worldSites w)&&M.member grid(worldPowerGrids w))(Left(InvariantViolation "dangling site power grid"))) (M.toList(worldSiteGrids w))
  validateJobs(worldJobs w)(worldInventory w)
  catalogs<-either(Left . InvariantViolation)Right(knownRecipeCatalogs(worldRuleset w)(worldContent w))
  mapM_(validateJobSnapshotCatalog catalogs)(M.elems(worldJobs w))
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
      placementIds=maybe [] (M.keys . Space.spatialPlacements . m1Space)(worldM1 w)
      constructionIds=maybe [] (map Construction.constructionJobId . M.elems . Construction.constructionJobs . m1Construction)(worldM1 w)
      facilityIds=M.keys(worldSites w)++concatMap(\g->map solarId(gridSolar g)++map generatorId(gridGenerators g)++map batteryId(gridBatteries g))grids
      constructionSites=maybe [] (M.keys . Construction.constructionJobs . m1Construction)(worldM1 w)
      spatialOnly=filter(`notElem`facilityIds)(S.toList(S.fromList(placementIds++constructionSites)))
      retiredCacheIds=case worldM1 w of Nothing->[];Just _->[ident|Owner GroundCache ident<-M.keys(transportRemovedPorts transport)]
      primary=retiredCacheIds++spatialOnly++constructionIds++M.keys(maintenanceJobs(worldMaintenance w))++transportIds++inventoryAssetIds inv++M.keys(worldJobs w)++M.keys(worldSites w)++M.keys(worldPowerGrids w)++M.keys(needsResidents(worldNeeds w))++concatMap(\g->map solarId(gridSolar g)++map generatorId(gridGenerators g)++map batteryId(gridBatteries g))grids
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
          MachineInput->M.member ident(maintenanceJobs(worldMaintenance w))||M.member ident(worldJobs w)||M.member ident(worldSites w)||ident `elem` generators||ident `elem` placementIds
          MachineOutput->M.member ident(worldSites w)
          ConstructionEscrow->M.member ident(worldJobs w)||M.member ident(transportRecoveries transport)||ident `elem` constructionIds
          Vehicle->M.member ident(transportVehicles transport)
          RecoveryHold->M.member ident(worldJobs w)
          Warehouse->spatialOwnerKind ident ["warehouse","depot"]
          Pantry->spatialOwnerKind ident ["pantry"]
          Tank->spatialOwnerKind ident ["tank"]
          _->False
        spatialOwnerKind i names=case worldM1 w >>= M.lookup i . Space.spatialPlacements . m1Space of
          Just placement->case Space.placementShape placement of Space.BuildingShape name _ _->name `elem` names;_->False
          Nothing->False
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

-- Current M1 profiles have physical owner/colony locations for production sites
-- and generators. Other power-device ownership must be supplied by a future
-- placement profile; it is not guessed from a possibly cross-colony power grid.
maintenanceTargetColony :: World -> EntityId -> Maybe EntityId
maintenanceTargetColony w ident=case M.lookup ident(worldSites w)of
  Just site->storageColony <$> M.lookup(siteInput site)(invStorage(worldInventory w))
  Nothing->case [generatorFuel generator|grid<-M.elems(worldPowerGrids w),generator<-gridGenerators grid,generatorId generator==ident]of
    owner:_->storageColony <$> M.lookup owner(invStorage(worldInventory w))
    []->Nothing

validateMaintenanceOwners :: World -> EntityId -> Owner -> Owner -> Either Failure ()
validateMaintenanceOwners w ident source destination=do
  unless(M.member ident(maintenanceFacilities(worldMaintenance w)))(Left TargetGone)
  targetColony<-maybe(Left(InvalidReference "MaintenanceTargetLocationUnavailable"))Right(maintenanceTargetColony w ident)
  sourceStorage<-maybe(Left MissingOwner)Right(M.lookup source(invStorage(worldInventory w)))
  destinationStorage<-maybe(Left MissingOwner)Right(M.lookup destination(invStorage(worldInventory w)))
  unless(storageColony sourceStorage==targetColony&&storageColony destinationStorage==targetColony)(Left(InvalidReference "MaintenancePartsNeedLocalDelivery"))

-- Dynamic roster target catalog. Counts are normative staffing requirements,
-- never anonymous worker supplies. All actual eligibility lives in Workforce.
workTargetCatalog :: World -> Either Failure Workforce.TargetCatalog
workTargetCatalog w=case worldM1 w of
  Nothing->pure M.empty
  Just state->do
    sites<-mapM siteTarget(M.elems(worldSites w))
    services<-mapM serviceTarget
      [p|p<-M.elems(Space.spatialPlacements(m1Space state)),Space.placementStage p==Space.Built
        ,case Space.placementShape p of Space.BuildingShape "pantry" _ _->True;_->False]
    maintenance<-mapM maintenanceTargetEntry
      [job|job<-M.elems(maintenanceJobs(worldMaintenance w)),not(maintenanceTerminal job)]
    let construction=[(Workforce.ConstructSite(Construction.constructionSiteId job),
          Workforce.TargetRequirement(Construction.constructionColony job)(Construction.constructionCrewRequired(Construction.constructionSnapshot job))Workforce.BuilderRole(Just Workforce.BuildSkill)False)
          |job<-M.elems(Construction.constructionJobs(m1Construction state)),not(Construction.constructionTerminal job)]
        drivers=[(Workforce.DriveVehicle(vehicleId vehicle),Workforce.TargetRequirement(vehicleColony vehicle)1 Workforce.DriverRole(Just Workforce.TransportSkill)(case vehiclePosition vehicle of Traversing{}->True;_->False))|vehicle<-M.elems(transportVehicles(worldTransport w))]
    pure(M.fromList(concat sites++services++construction++maintenance++drivers))
  where
    ownerColony owner=maybe(Left MissingOwner)(Right . storageColony)(M.lookup owner(invStorage(worldInventory w)))
    siteTarget site=do
      recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(siteRecipe site))
      building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)(recipeBuilding recipe))
      colony<-ownerColony(siteInput site)
      let skill=if M.null(recipeNaturalSources recipe)then Workforce.ProcessSkill else Workforce.GatherSkill
      pure[(Workforce.OperateFacility(siteId site),Workforce.TargetRequirement colony(buildingWorkers building)Workforce.OperatorRole(Just skill)False)|buildingWorkers building>0]
    serviceTarget placement=do
      building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)"pantry")
      pure(Workforce.OperateFacility(Space.placementId placement),Workforce.TargetRequirement(Space.placementColony placement)(buildingWorkers building)Workforce.ServiceRole Nothing False)
    maintenanceTargetEntry job=do
      colony<-ownerColony(maintenanceSource job)
      pure(Workforce.MaintainJob(maintenanceJobId job),Workforce.TargetRequirement colony 1 Workforce.MaintainerRole(Just Workforce.MaintainSkill)False)

validateM1WorldLinks :: World -> M1State -> Either Failure()
validateM1WorldLinks w state=do
  let space=m1Space state
      check b=unless b . Left . InvariantViolation
      getPlacement ident=maybe(Left(InvariantViolation "operational entity lacks physical placement"))Right(M.lookup ident(Space.spatialPlacements space))
  nodes<-S.fromList <$> mapM nodeOf(S.toAscList(Space.spatialRoads space))
  validatePickups(worldInventory w)(worldTransport w)(simTick w)(m1Pickups state)
  check(worldWeather w==Clear)"S01 M1 profile is Clear-only; full storm labour/health/transport rules are pending"
  check(M.null(transportRecoveries(worldTransport w)))"M1 named rescue crew is unimplemented; fixed-crew recovery is legacy-only"
  check(all(null . gridGenerators)(M.elems(worldPowerGrids w)))"M1 generator staffing is unimplemented; S01 uses solar/battery"
  validateM1PowerBindings w space
  check(nodes==roadNodes(transportTopology(worldTransport w)))"road graph differs from spatial road layer"
  ports<-spatialPorts space
  check(ports==transportPorts(worldTransport w))"transport ports differ from physical endpoints"
  caches<-spatialRoadCaches space
  check(caches==transportGroundCaches(worldTransport w))"transport cache differs from unique spatial tile owner"
  check(M.size(m1ColonyDepots state)<=1)"M1 S01 slice supports one colony; founding is not implemented"
  let workforce=m1Workforce state
      SimTick now=simTick w
      context=Workforce.TickContext(simTick w)(toInteger(now `mod`28800 `div`9600))
  catalog<-workTargetCatalog w
  reconciled<-either(Left . Workforce.workforceFailure)Right(Workforce.reconcileClaims context catalog(worldNeeds w)workforce)
  check(reconciled==workforce)"committed workforce contains stale/ineligible claims"
  mapM_(\target->check(case target of
    Workforce.OperateFacility ident->not(M.member ident(worldSites w))||any(\job->jobPhase job==Running&&M.lookup(jobId job)(worldJobSites w)==Just ident)(M.elems(worldJobs w))
    Workforce.ConstructSite ident->maybe False((==Construction.ConstructionRunning).Construction.constructionPhase)(M.lookup ident(Construction.constructionJobs(m1Construction state)))
    Workforce.MaintainJob ident->maybe False((==MaintenanceRunning).maintenancePhase)(M.lookup ident(maintenanceJobs(worldMaintenance w)))
    Workforce.DriveVehicle ident->maybe False(vehicleHasLiveDuty state)(M.lookup ident(transportVehicles(worldTransport w))))"worker claim lacks actual live duty") (M.elems(Workforce.workforceClaims workforce))
  mapM_(\job->mapM_(\resource->do
    let owner=Construction.constructionInput job
        incoming=incomingDeliveryQuantity(worldTransport w)owner resource
        physical=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory w)),lotOwner lot==owner,lotResource lot==resource]
        cost=M.findWithDefault 0 resource(Construction.constructionCost(Construction.constructionSnapshot job))
    check(physical+incoming<=cost)"construction physical/incoming material exceeds known cost"
    check(Construction.constructionPhase job/=Construction.ConstructionRunning||incoming==0)"running construction has incoming unescrowed material")allResources)
    [job|job<-M.elems(Construction.constructionJobs(m1Construction state)),not(Construction.constructionTerminal job)]
  mapM_(\site->do
    check(siteInput site==Owner MachineInput(siteId site)&&siteOutput site==Owner MachineOutput(siteId site))"M1 site endpoint aliases another physical entity"
    placement<-getPlacement(siteId site)
    recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(siteRecipe site))
    building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)(recipeBuilding recipe))
    check(Space.placementStage placement==Space.Built)"production runs at an unfinished site"
    check(siteWorkers site==buildingWorkers building)"M1 site nominal staffing differs from content"
    check(case Space.placementShape placement of Space.BuildingShape name _ _->name==recipeBuilding recipe;_->False)"site recipe/physical prototype mismatch"
    let expected=case Space.placementSource placement of
          Nothing->M.empty
          Just source->M.fromList[(kind,source)|kind<-M.keys(recipeNaturalSources recipe)]
    check(siteNatural site==expected)"site implicit/extra source binding") (M.elems(worldSites w))
  mapM_(\vehicle->do
    check(M.member(vehicleColony vehicle)(m1ColonyDepots state))"vehicle belongs to unknown M1 colony"
    home<-maybe(Left(InvariantViolation "vehicle physical home absent"))Right(M.lookup(vehicleHome vehicle)(invStorage(worldInventory w)))
    fuel<-maybe(Left(InvariantViolation "vehicle physical fuel source absent"))Right(M.lookup(vehicleFuelSource vehicle)(invStorage(worldInventory w)))
    check(case vehicleHome vehicle of Owner Warehouse _->True;_->False)"M1 vehicle parking must be a permanent warehouse/depot endpoint"
    cargo<-maybe(Left(InvariantViolation "vehicle cargo storage absent"))Right(M.lookup(vehicleOwner vehicle)(invStorage(worldInventory w)))
    check(storageColony home==vehicleColony vehicle&&storageColony fuel==vehicleColony vehicle&&storageColony cargo==vehicleColony vehicle)"vehicle home/fuel/cargo colony mismatch"
    check(storageResource cargo==Nothing)"vehicle cargo storage cannot exclude cargo/fuel resources"
    check(storageResource fuel `elem` [Nothing,Just Fuel])"vehicle fuel source excludes Fuel"
    let homePort=M.lookup(vehicleHome vehicle)(transportPorts(worldTransport w))
    check(homePort/=Nothing&&homePort==M.lookup(vehicleFuelSource vehicle)(transportPorts(worldTransport w)))"vehicle fuel must be at physical home port") (M.elems(transportVehicles(worldTransport w)))
  check(M.keysSet(worldJobSites w)==M.keysSet(worldJobs w))"every recipe job requires exactly one physical site link"
  mapM_(\(ident,job)->do
    siteIdValue<-maybe(Left TargetGone)Right(M.lookup ident(worldJobSites w))
    site<-maybe(Left TargetGone)Right(M.lookup siteIdValue(worldSites w))
    check(jobRecipe job==siteRecipe site&&jobInput job==siteInput site&&jobOutput job==siteOutput site&&jobNaturalSources job==siteNatural site)"recipe job/source/endpoints differ from its physical facility") (M.toList(worldJobs w))
  validateM1TransportLinks w
  expectedLocations<-M.fromList . concat <$> mapM(ownerLocation space getPlacement)(M.keys(invStorage(worldInventory w)))
  check(expectedLocations==Space.spatialOwnerLocations space)"inventory endpoint locations differ from physical placement/cache/job geometry"
  mapM_(\facility->do
    placement<-getPlacement(facilityId facility)
    check(Space.placementStage placement==Space.Built)"maintenance targets unfinished placement"
    check(case Space.placementShape placement of Space.BuildingShape name _ _->name==facilityBuilding facility;_->False)"maintenance/physical prototype mismatch") (M.elems(maintenanceFacilities(worldMaintenance w)))

  where
    ownerLocation space getPlacement owner@(Owner kind ident)=
      let fixed names=do
            placement<-getPlacement ident
            case Space.placementShape placement of
              Space.BuildingShape name _ _|name `elem` names&&Space.placementStage placement==Space.Built->do
                (_,geometry)<-either(Left . Space.spaceFailure)Right(Space.placementGeometry(worldContent w)placement)
                p<-maybe(Left(InvariantViolation "stationary storage has no physical port"))Right geometry
                pure[(owner,Space.OwnerLocation(Space.boundaryPort p)(Just(Space.roadConnector p)))]
              _->Left(InvariantViolation "stationary storage/prototype mismatch")
          construction=[job|job<-M.elems(Construction.constructionJobs(m1Construction state)),not(Construction.constructionTerminal job),owner `elem` [Construction.constructionInput job,Construction.constructionEscrow job]]
          transientKnown=M.member ident(worldJobs w)||M.member ident(maintenanceJobs(worldMaintenance w))
      in case construction of
        job:_->do
          placement<-getPlacement(Construction.constructionSiteId job)
          location<-either(Left . Space.spaceFailure)Right(Construction.materialLocation(worldContent w)space placement)
          pure[(owner,location)]
        []->case kind of
          Warehouse->fixed["warehouse","depot"]
          Pantry->fixed["pantry"]
          Tank->fixed["tank"]
          MachineInput|M.member ident(worldSites w)->do
            site<-maybe(Left TargetGone)Right(M.lookup ident(worldSites w))
            recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(siteRecipe site))
            fixed[recipeBuilding recipe]
          MachineOutput|M.member ident(worldSites w)->do
            site<-maybe(Left TargetGone)Right(M.lookup ident(worldSites w))
            recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(siteRecipe site))
            fixed[recipeBuilding recipe]
          MachineInput|ident `elem` concatMap(map generatorId . gridGenerators)(M.elems(worldPowerGrids w))->fixed["generator"]
          MachineInput|transientKnown->pure[]
          ConstructionEscrow|M.member ident(transportRecoveries(worldTransport w))->pure[]
          RecoveryHold|M.member ident(worldJobs w)->pure[]
          Vehicle|M.member ident(transportVehicles(worldTransport w))->pure[]
          GroundCache->case[(tile,cacheRecord)|(tile,cacheRecord)<-M.toList(Space.spatialCaches space),Space.cacheOwner cacheRecord==owner]of
            [(tile,_)]->pure[(owner,Space.OwnerLocation tile(Space.cacheRoadPort space tile))]
            _->Left(InvariantViolation "GroundCache location absent or duplicated")
          _->Left(InvariantViolation "unsupported/dangling M1 physical storage owner")

-- Every operational power device is the facet of exactly one physical Built
-- prototype, and every site/device has the mandatory maintenance lifecycle.
-- Fixed S01 circuits must correspond to real connected wire anchors; dynamic
-- wire edits and generator staffing are not manufactured by accepting a save.
validateM1PowerBindings :: World -> Space.SpatialState -> Either Failure()
validateM1PowerBindings world space=do
  let check b=unless b . Left . InvariantViolation
      grids=worldPowerGrids world
      devices=[(solarId device,"solar",ident)|(ident,grid)<-M.toList grids,device<-gridSolar grid]
        ++[(batteryId device,"battery",ident)|(ident,grid)<-M.toList grids,device<-gridBatteries grid]
      expected=S.fromList[(Space.placementId placement,name)|placement<-M.elems(Space.spatialPlacements space),Space.placementStage placement==Space.Built,Space.BuildingShape name _ _<-[Space.placementShape placement],name `elem` ["solar","battery"]]
      requiredMaintenance=S.fromList(M.keys(worldSites world)++[ident|(ident,_,_)<-devices])
  check(all(\(ident,grid)->ident==gridId grid)(M.toList grids))"power grid key/identity mismatch"
  check(S.fromList[(ident,name)|(ident,name,_)<-devices]==expected)"power devices differ from physical Built prototypes"
  check(M.keysSet(maintenanceFacilities(worldMaintenance world))==requiredMaintenance)"site/power device missing mandatory maintenance record"
  mapM_(\(ident,name,_)->case M.lookup ident(maintenanceFacilities(worldMaintenance world))of
    Just facility->check(facilityBuilding facility==name)"power device maintenance prototype mismatch"
    Nothing->Left(InvariantViolation "power device missing maintenance"))devices
  powered<-fmap S.fromList $ mapM(\site->do
    recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent world)(siteRecipe site))
    building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent world)(recipeBuilding recipe))
    pure(siteId site,buildingPower building>0))(M.elems(worldSites world))
  check(S.fromList[ident|(ident,True)<-S.toList powered] `S.isSubsetOf` M.keysSet(worldSiteGrids world))"powered sites lack exact fixed circuit binding"
  circuits<-mapM(\(ident,_)->do
    anchors<-mapM anchor([device|(device,_,gid)<-devices,gid==ident]++[site|(site,gid)<-M.toList(worldSiteGrids world),gid==ident])
    case anchors of
      []->Left(InvariantViolation "empty fixed power circuit")
      first:rest->do
        let component=wireComponent S.empty(S.singleton first)
        check(all(`S.member`component)(first:rest))"power circuit endpoints are not wire-connected"
        pure component)(M.toList grids)
  check(and[S.null(a `S.intersection`b)|(i,a)<-zip[0::Integer ..]circuits,(j,b)<-zip[0::Integer ..]circuits,i<j])"one wire component split into multiple fixed power grids"
  where
    anchor ident=do
      placement<-maybe(Left(InvariantViolation "power endpoint lacks placement"))Right(M.lookup ident(Space.spatialPlacements space))
      (_,geometry)<-either(Left . Space.spaceFailure)Right(Space.placementGeometry(worldContent world)placement)
      maybe(Left(InvariantViolation "power endpoint lacks boundary anchor"))(Right . Space.boundaryPort)geometry
    wireComponent visited pending
      |S.null pending=visited
      |otherwise=let(tile@(Space.Tile x y),rest)=S.deleteFindMin pending in
        if not(S.member tile(Space.spatialWires space))||S.member tile visited then wireComponent visited rest
        else wireComponent(S.insert tile visited)(S.union rest(S.fromList[Space.Tile(x-1)y,Space.Tile(x+1)y,Space.Tile x(y-1),Space.Tile x(y+1)] `S.difference`visited))

-- Constructor ordinals0..6 and event ordinals0..4 are frozen schema3 vocabulary.
-- Check nested receipts/events as well as inputs; recomputing a save checksum
-- cannot smuggle new operations into an old rules profile.
commandAllowedInRuleset :: String -> Command -> Bool
commandAllowedInRuleset rules command=case command of
  PlaceConstructionPlan{}->isM1Ruleset rules
  CancelConstructionPlan{}->isM1Ruleset rules
  AssignWorkers{}->isM1Ruleset rules
  OrderProduction{}->True
  CancelProduction{}->True
  SetSiteEnabled{}->True
  RequestDelivery{}->True
  CancelDelivery{}->True
  RequestMaintenance{}->True
  CancelFacilityMaintenance{}->True
eventAllowedInRuleset :: String -> DomainEvent -> Bool
eventAllowedInRuleset rules event=case event of
  ConstructionPlanned{}->isM1Ruleset rules
  ConstructionStarted{}->isM1Ruleset rules
  ConstructionCompleted{}->isM1Ruleset rules
  ConstructionCancelled{}->isM1Ruleset rules
  WorkersAssigned{}->isM1Ruleset rules
  GroundCacheRetired{}->isM1Ruleset rules
  JobPlanned{}->True
  JobStarted{}->True
  JobCompleted{}->True
  JobCancelled{}->True
  JobExpired{}->True

-- Strong committed-boundary links for the new spatial profile. Reservation IDs
-- refer to actual source/resource/destination, not only matching aggregate sums.
validateM1TransportLinks :: World -> Either Failure()
validateM1TransportLinks world=do
  let inventory=worldInventory world;transport=worldTransport world
      requests=transportRequests transport;shipments=transportShipments transport
      check b=unless b . Left . InvariantViolation
      quantities ident=[claim|claim<-M.elems(invQuantity inventory),quantityJob claim==ident]
      capacities ident=[claim|claim<-M.elems(invCapacity inventory),capacityJob claim==ident]
      matches owner resource claim=case M.lookup(quantityLot claim)(invLots inventory)of
        Just lot->lotOwner lot==owner&&lotResource lot==resource&&usable(simTick world)lot
        Nothing->False
  check(all(\claim->M.member(naturalJob claim)(worldJobs world))(M.elems(invNatural inventory)))"natural reservation belongs to non-extraction domain"
  mapM_(\request->do
    let ident=requestId request;active=requestStatus request==RequestOpen
    check(requestPriority request>=0&&requestPriority request<=3&&requestReadySince request<=simTick world)"delivery priority/time invalid"
    check(not active||lookupPublicPort(requestDestination request)transport/=Nothing)"live delivery destination is not a public endpoint"
    -- A fully loaded outbound request may retain its deleted source cache's
    -- historical identity. Only unreceived stock still requires a source port.
    check(not active||requestRemaining request==0||lookupPublicPort(requestSource request)transport/=Nothing)"unloaded delivery source is not a public endpoint"
    check(all(matches(requestSource request)(requestResource request))(quantities ident))"parent reservation differs from physical source/resource"
    check(all((==requestDestination request).capacityOwner)(capacities ident))"parent has capacity at an unrelated destination"
    check(active||null(capacities ident))"terminal parent retains foreign capacity"
    check(not active||requestRemaining request>0||any(\sid->maybe False(not . shipmentTerminal)(M.lookup sid shipments))(requestChildren request))"unreserved terminal work remains an open request") (M.elems requests)
  mapM_(\shipment->do
    let ident=shipmentId shipment;caps=capacities ident;claims=quantities ident
        cargoWeight=sum[weightOf inventory(lotResource lot)(qtyValue(quantityAmount claim))|claim<-claims,Just lot<-[M.lookup(quantityLot claim)(invLots inventory)]]
    check(shipmentQuantity shipment>0&&shipmentQuantity shipment<=9000000000000)"shipment quantity bounds"
    case shipmentKind shipment of
      DeliveryChild parent->do
        request<-maybe(Left TargetGone)Right(M.lookup parent requests)
        check(ident `elem` requestChildren request&&shipmentSource shipment==requestSource request&&shipmentResource shipment==requestResource request&&shipmentDestination shipment==Just(requestDestination request))"delivery child differs from its parent contract"
        check(shipmentTerminal shipment||requestStatus request==RequestOpen)"live child belongs to terminal request"
      ReturnShipment predecessor->do
        previous<-maybe(Left TargetGone)Right(M.lookup predecessor shipments)
        check(shipmentSource shipment==shipmentSource previous&&shipmentResource shipment==shipmentResource previous&&shipmentQuantity shipment==shipmentQuantity previous&&shipmentVehicle shipment==shipmentVehicle previous)"Return changes original cargo/source/vehicle identity"
    if shipmentTerminal shipment then check(null(shipmentLots shipment))"terminal shipment retains physical manifest"else do
      check(shipmentStatus shipment/=ShipmentReserved)"transient unloaded child escaped the atomic loading phase"
      check(not(null claims))"live shipment has no actual cargo claims"
      case shipmentDestination shipment of
        Nothing->check(null caps)"destinationless Return retains capacity"
        Just destination->do
          check(lookupPublicPort destination transport/=Nothing)"live cargo/Return destination is not a public endpoint"
          check(all((==destination).capacityOwner)caps&&sum(map capacityWeight caps)==cargoWeight)"live shipment capacity differs from exact cargo destination/weight") (M.elems shipments)

vehicleHasLiveDuty :: M1State -> TransportVehicle -> Bool
vehicleHasLiveDuty state vehicle=M.member(vehicleId vehicle)(m1Pickups state)||vehicleJob vehicle/=Nothing||not(null(vehicleRoute vehicle))||case vehiclePosition vehicle of Traversing{}->True;_->False
