{-# LANGUAGE DeriveAnyClass, DeriveGeneric #-}
-- Profile6/7 construction slice. Physical input arrives by ordinary transport;
-- this module only transfers already present complete cost into escrow.
module Colony.Construction where
import Colony.Content
import Colony.ContentCodec(contentIdentity,knownRecipeCatalogsForContent)
import Colony.Inventory
import Colony.Jobs(planReturnPlacement,resourceLotGroups)
import qualified Colony.Space as Space
import Colony.Types
import Colony.Units
import Control.DeepSeq(NFData)
import Control.Monad(forM_,unless,when)
import Control.Monad.State.Strict(get,gets,modify')
import qualified Data.ByteString as BS
import Data.List(sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word(Word64)
import GHC.Generics(Generic)

data ConstructionKind=BuildHandPump|BuildRoad deriving(Eq,Ord,Show,Read,Generic,NFData)
data ConstructionSnapshot=ConstructionSnapshot
  { constructionKind :: !ConstructionKind,constructionCost :: !(M.Map Resource Integer)
  ,constructionRequired :: !Integer,constructionCrewRequired :: !Integer
  ,constructionContentId :: !BS.ByteString,constructionRuleVersion :: !Word64 }
  deriving(Eq,Show,Read,Generic,NFData)
data ConstructionPhase=ConstructionPlanned|ConstructionWaitingInputs|ConstructionMovingInputs|ConstructionReady
  |ConstructionRunning|ConstructionCompleted|ConstructionCancelled
  deriving(Eq,Ord,Show,Read,Generic,NFData)
data ConstructionJob=ConstructionJob
  { constructionJobId :: !EntityId,constructionSiteId :: !EntityId
  ,constructionShape :: !Space.PlacementShape,constructionColony :: !EntityId
  ,constructionInput :: !Owner,constructionEscrow :: !Owner
  ,constructionSnapshot :: !ConstructionSnapshot,constructionPhase :: !ConstructionPhase
  ,constructionBlocked :: !(Maybe Failure),constructionProgress :: !Integer
  ,constructionTerminalCount :: !Integer,constructionRevision :: !Word64
  ,constructionPriority :: !Integer,constructionReadySince :: !SimTick
  ,constructionOrigin :: !Space.Tile,constructionSource :: !(Maybe EntityId) }
  deriving(Eq,Show,Read,Generic,NFData)
data ConstructionState=ConstructionState
  { constructionJobs :: !(M.Map EntityId ConstructionJob)
  , constructionAccountedCosts :: !(M.Map EntityId (M.Map Resource Integer)) }
  deriving(Eq,Show,Read,Generic,NFData)
data ConstructionCompletion=PumpConstructed !EntityId !Owner !Owner !EntityId|RoadConstructed !EntityId !Space.Tile
  deriving(Eq,Show,Read,Generic,NFData)

emptyConstruction :: ConstructionState
emptyConstruction=ConstructionState M.empty M.empty
constructionTerminal :: ConstructionJob -> Bool
constructionTerminal job=constructionPhase job `elem`[ConstructionCompleted,ConstructionCancelled]
constructionFailure :: String -> Failure
constructionFailure=InvalidReference . ("Construction: "++)
checkedRevision :: ConstructionJob -> InventoryTx Word64
checkedRevision job=do require(constructionRevision job<maxBound)CounterOverflow;pure(constructionRevision job+1)

snapshotFor :: Content -> Space.PlacementShape -> Either Failure ConstructionSnapshot
snapshotFor content shape=do
  digest<-either(Left . InvalidReference)Right(contentIdentity content)
  _<-either(Left . InvalidReference)Right(knownRecipeCatalogsForContent content)
  case shape of
    Space.BuildingShape "hand_pump" _ _->do
      building<-either(Left . InvalidReference)Right(lookupBuilding content "hand_pump")
      pure(ConstructionSnapshot BuildHandPump(buildingCost building)(buildingBuildWorkTicks building*100)2 digest 1)
    Space.RoadShape _->pure(ConstructionSnapshot BuildRoad(M.singleton Stone 2000)2000 2 digest 1)
    _->Left(constructionFailure "UnsupportedPrototype: this M1 slice constructs hand_pump and road only")

-- IDs, stores and placement are returned only with the caller's whole World
-- transaction. No material, worker, road or completed facility is granted here.
placeConstruction :: Content -> SimTick -> EntityId -> Space.PlacementShape -> Integer -> Maybe EntityId
                  -> Space.SpatialState -> InventoryTx(ConstructionJob,Space.SpatialState)
placeConstruction content tick colony shape priority selected space=do
  require(priority>=0&&priority<=3)InvalidQuantity
  snapshot<-either throwTx pure(snapshotFor content shape)
  site<-freshId;job<-freshId
  inventory<-get
  (placement,placed)<-either(throwTx . Space.spaceFailure)pure $ case shape of
    Space.BuildingShape prototype tile rotation->Space.reserveBuildingPlan content inventory site colony prototype tile rotation selected space
    Space.RoadShape tile->if selected==Nothing then Space.reserveRoadPlan content inventory site colony tile space else Left(Space.UnneededSource(maybe site id selected))
  let input=Owner MachineInput site;escrow=Owner ConstructionEscrow job
      costWeight=sum[weightOf inventory resource quantity|(resource,quantity)<-M.toList(constructionCost snapshot)]
      origin=case shape of Space.BuildingShape _ tile _->tile;Space.RoadShape tile->tile
  require(costWeight<=400000)(constructionFailure "UnsupportedCost: construction site input is 400000g")
  addStorage input(Storage 400000 Nothing colony)
  addStorage escrow(Storage costWeight Nothing colony)
  after<-get
  location<-either(throwTx . Space.spaceFailure)pure(materialLocation content placed placement)
  withInput<-either(throwTx . Space.spaceFailure)pure(Space.registerOwnerLocation after input location placed)
  withEscrow<-either(throwTx . Space.spaceFailure)pure(Space.registerOwnerLocation after escrow location withInput)
  pure(ConstructionJob job site shape colony input escrow snapshot ConstructionPlanned Nothing 0 0 1 priority tick origin(Space.placementSource placement),withEscrow)

-- A building uses its external connector; an unfinished road receives from an
-- existing adjacent road. Parent mirrors these endpoints into real Transport.
materialLocation :: Content -> Space.SpatialState -> Space.Placement -> Either Space.SpaceError Space.OwnerLocation
materialLocation content space placement=case Space.placementShape placement of
  Space.RoadShape tile->Right(Space.OwnerLocation tile(Space.cacheRoadPort space tile))
  _->do
    (_,port)<-Space.placementGeometry content placement
    maybe(Left Space.InvalidFootprint)(\p->Right(Space.OwnerLocation(Space.boundaryPort p)(Just(Space.roadConnector p))))port

-- Admission helper: parent accounts for all unreceived incoming reservations.
-- Prevent unrelated/extra deliveries from stranding stock when a road site ends.
admitConstructionDelivery :: ConstructionJob -> Resource -> Integer -> Integer -> Inventory -> Either Failure()
admitConstructionDelivery job resource quantity incoming inventory=do
  unless(not(constructionTerminal job)&&constructionPhase job/=ConstructionRunning)(Left(constructionFailure "SiteNotReceiving"))
  let required=M.findWithDefault 0 resource(constructionCost(constructionSnapshot job))
      present=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots inventory),lotOwner lot==constructionInput job,lotResource lot==resource]
  unless(quantity>0&&incoming>=0&&required>0&&present+incoming+quantity<=required)(Left(constructionFailure "UnexpectedOrExcessSiteMaterial"))

setConstructionWaiting :: Bool -> Failure -> ConstructionJob -> InventoryTx ConstructionJob
setConstructionWaiting incoming reason job=do
  let phase=if reason==MissingStock then if incoming then ConstructionMovingInputs else ConstructionWaitingInputs else ConstructionReady
  if constructionPhase job==phase&&constructionBlocked job==Just reason then pure job else do
    revision<-checkedRevision job
    pure job{constructionPhase=phase,constructionBlocked=Just reason,constructionRevision=revision}

startConstruction :: Content -> SimTick -> Bool -> ConstructionJob -> Space.SpatialState
                  -> InventoryTx(ConstructionJob,Space.SpatialState)
startConstruction content tick crewReady job space=do
  require(not(constructionTerminal job)&&constructionPhase job/=ConstructionRunning)AlreadyTerminal
  require crewReady (constructionFailure "WaitingWorkers")
  inventory<-get
  either throwTx pure(validateConstructionJob content inventory space job)
  started<-either(throwTx . Space.spaceFailure)pure(Space.startPlacement content inventory(constructionSiteId job)space)
  forM_(M.toAscList(constructionCost(constructionSnapshot job)))$ \(resource,quantity)->reserveQuantity tick(constructionJobId job)(constructionInput job)resource quantity
  moveReserved(constructionJobId job)(constructionInput job)(constructionEscrow job)
  revision<-checkedRevision job
  pure(job{constructionPhase=ConstructionRunning,constructionBlocked=Nothing,constructionRevision=revision},started)

advanceConstruction :: Content -> TxId -> Integer -> ConstructionJob -> Space.SpatialState
                    -> InventoryTx(ConstructionJob,Space.SpatialState,Maybe ConstructionCompletion)
advanceConstruction content tx credit job space=do
  require(constructionPhase job==ConstructionRunning)AlreadyTerminal
  require(credit>=0&&credit<=130)InvalidQuantity
  inventory<-get
  either throwTx pure(validateConstructionJob content inventory space job)
  if credit==0 then pure(job,space,Nothing)else do
    revision<-checkedRevision job
    let required=constructionRequired(constructionSnapshot job)
        progress=min required(constructionProgress job+credit)
        advanced=job{constructionProgress=progress,constructionBlocked=Nothing,constructionRevision=revision}
    if progress<required then pure(advanced,space,Nothing)else do
      consumeAllAt tx ConstructionConsumed(constructionJobId job)(constructionEscrow job)
      now<-get
      completed<-either(throwTx . Space.spaceFailure)pure(Space.completePlacement content now(constructionSiteId job)space)
      (finished,completion)<-case constructionShape job of
        Space.BuildingShape "hand_pump" _ _->do
          source<-maybe(throwTx(constructionFailure "Completed pump lost source"))pure(constructionSource job)
          let output=Owner MachineOutput(constructionSiteId job)
          addStorage output(Storage 400000 Nothing(constructionColony job))
          current<-get
          location<-maybe(throwTx MissingOwner)pure(M.lookup(constructionInput job)(Space.spatialOwnerLocations completed))
          placed<-either(throwTx . Space.spaceFailure)pure(Space.registerOwnerLocation current output location completed)
          pure(placed,PumpConstructed(constructionSiteId job)(constructionInput job)output source)
        Space.RoadShape tile->do
          deleteEmptyStorage(constructionInput job)
          pure(completed{Space.spatialOwnerLocations=M.delete(constructionInput job)(Space.spatialOwnerLocations completed)},RoadConstructed(constructionSiteId job)tile)
        _->throwTx(constructionFailure "Unsupported completed prototype")
      deleteEmptyStorage(constructionEscrow job)
      let finalSpace=finished{Space.spatialOwnerLocations=M.delete(constructionEscrow job)(Space.spatialOwnerLocations finished)}
      pure(advanced{constructionPhase=ConstructionCompleted,constructionTerminalCount=1},finalSpace,Just completion)

constructionRefund :: Integer -> Integer -> Integer -> Either Failure Integer
constructionRefund quantity progress required=do
  unless(quantity>=0&&required>0&&progress>=0&&progress<=required)(Left InvalidQuantity)
  pure(quantity*(10000-(5000*progress `div` required)) `div` 10000)

-- Caller first cancels every incoming/outgoing transport request incident on the
-- site, inside this SAME transaction. Unreceived cargo remains a vehicle/Return;
-- it is not part of the site's refund. Foreign claims cause unchanged failure.
cancelConstruction :: Content -> TxId -> Word64 -> ConstructionJob -> Space.SpatialState
                   -> InventoryTx(ConstructionJob,Space.SpatialState)
cancelConstruction content tx expected job space=do
  require(not(constructionTerminal job))AlreadyTerminal
  require(expected==constructionRevision job)(constructionFailure "StaleEntityRevision")
  inventory<-get
  either throwTx pure(validateConstructionJob content inventory space job)
  releaseJob(constructionJobId job)
  when(constructionPhase job==ConstructionRunning)$forM_(M.toAscList(constructionCost(constructionSnapshot job)))$ \(resource,quantity)->do
    refund<-either throwTx pure(constructionRefund quantity(constructionProgress job)(constructionRequired(constructionSnapshot job)))
    loseConstruction tx job resource(quantity-refund)
  unplaced<-either(throwTx . Space.spaceFailure)pure(Space.removePlacement(constructionSiteId job)space)
  let released=unplaced{Space.spatialOwnerLocations=foldr M.delete(Space.spatialOwnerLocations unplaced)[constructionInput job,constructionEscrow job]}
      context=Space.CacheContext(constructionOrigin job)(constructionColony job)(Space.ConstructionReturn(constructionSiteId job))
  (returned,_)<-returnPhysicalToSpace content context[constructionInput job,constructionEscrow job][] released
  deleteEmptyStorage(constructionInput job);deleteEmptyStorage(constructionEscrow job)
  revision<-checkedRevision job
  pure(job{constructionPhase=ConstructionCancelled,constructionBlocked=Nothing,constructionTerminalCount=1,constructionRevision=revision},returned)

loseConstruction :: TxId -> ConstructionJob -> Resource -> Integer -> InventoryTx()
loseConstruction tx job resource quantity=do
  lots<-gets(sortOn fefo . filter(\lot->lotOwner lot==constructionEscrow job&&lotResource lot==resource) . M.elems . invLots)
  go quantity lots
  where
    go 0 _=pure()
    go _ []=throwTx(InvariantViolation "construction loss exceeds physical escrow")
    go remaining(lot:rest)=do
      let amount=min remaining(qtyValue(lotQty lot))
      _<-removeFromLot(lotId lot)amount
      record tx ConstructionLoss(Just(constructionJobId job))resource amount(Just(constructionEscrow job))Nothing
      go(remaining-amount)rest

-- Shared spatial extension of the existing exact supported-weight allocator.
-- Candidate caches are allocated only while planning a complete transaction;
-- failed feasibility/transfer rolls back IDs and stores with the whole result.
returnPhysicalToSpace :: Content -> Space.CacheContext -> [Owner] -> [Owner] -> Space.SpatialState
                      -> InventoryTx(Space.SpatialState,[(Resource,Owner,Integer)])
returnPhysicalToSpace content context sources preferred space=do
  inventory<-get
  let lots=filter((`elem`sources).lotOwner)(M.elems(invLots inventory))
      demand=M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-lots]
      warehouses=[owner| (owner@(Owner Warehouse _),storage)<-M.toAscList(invStorage inventory),storageColony storage==Space.cacheColony context,owner `notElem` sources]
      initial=filter(`notElem`sources)preferred++warehouses
      candidates=Space.cacheCandidates content space context
      loads=S.fromList[weightOf inventory resource 1|(resource,quantity)<-M.toList demand,quantity>0,weightOf inventory resource 1>1]
  require(S.size loads<=1)(constructionFailure "UnsupportedMixedReturnWeights")
  (destinations,placed)<-plan demand initial candidates space
  forM_(resourceLotGroups lots)$ \(resource,group)->
    move[(owner,quantity)|(r,owner,quantity)<-destinations,r==resource][(lotId lot,qtyValue(lotQty lot))|lot<-sortOn fefo group]
  pure(placed,destinations)
  where
    plan demand owners remaining current=do
      inventory<-get
      case planReturnPlacement inventory owners demand of
        Right placements->pure(placements,current)
        Left ReturnCapacityFull->case remaining of
          []->throwTx ReturnCapacityFull
          tile:rest->do
            (owner,next)<-Space.ensureGroundCache content context tile current
            plan demand(owners++[owner])rest next
        Left err->throwTx err
    move [] []=pure()
    move((owner,needed):destinations)((ident,available):lots)=do
      let amount=min needed available
      transferSelected owner[(ident,amount)]
      move(if needed==amount then destinations else(owner,needed-amount):destinations)(if available==amount then lots else(ident,available-amount):lots)
    move _ _=throwTx(InvariantViolation "spatial return plan differs from physical survivors")

deleteEmptyStorage :: Owner -> InventoryTx()
deleteEmptyStorage owner=do
  inventory<-get
  require(all((/=owner).lotOwner)(M.elems(invLots inventory))&&all((/=owner).capacityOwner)(M.elems(invCapacity inventory)))ReturnCapacityFull
  modify'$ \s->s{invStorage=M.delete owner(invStorage s)}

validateConstructionSnapshot :: Content -> Space.PlacementShape -> ConstructionSnapshot -> Either Failure()
validateConstructionSnapshot content shape snapshot=do
  expected<-snapshotFor content shape
  catalogs<-either(Left . InvalidReference)Right(knownRecipeCatalogsForContent content)
  unless(M.member(constructionContentId snapshot)catalogs)(Left(InvariantViolation "unknown construction snapshot catalog"))
  -- The two supported catalogs differ only in cook recipe fields; every building
  -- and road cost/work definition is identical. No arbitrary mod is authorized.
  unless(snapshot{constructionContentId=constructionContentId expected}==expected)(Left(InvariantViolation "construction snapshot differs from known prototype/rules"))

validateConstructionJob :: Content -> Inventory -> Space.SpatialState -> ConstructionJob -> Either Failure()
validateConstructionJob content inventory space job=do
  let check condition=unless condition . Left . InvariantViolation
      snapshot=constructionSnapshot job;phase=constructionPhase job
      physical owner=M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-M.elems(invLots inventory),lotOwner lot==owner]
      EntityId jid=constructionJobId job;EntityId sid=constructionSiteId job
  check(jid>0&&sid>0&&jid/=sid&&max jid sid<invNextId inventory)"construction identity"
  check(constructionInput job==Owner MachineInput(constructionSiteId job)&&constructionEscrow job==Owner ConstructionEscrow(constructionJobId job))"construction owner identity"
  check(constructionPriority job>=0&&constructionPriority job<=3&&constructionRevision job>0)"construction priority/revision"
  check(constructionProgress job>=0&&constructionProgress job<=constructionRequired snapshot)"construction progress"
  check(constructionTerminalCount job==if constructionTerminal job then 1 else 0)"construction terminal count"
  validateConstructionSnapshot content(constructionShape job)snapshot
  let expectedOrigin=case constructionShape job of Space.BuildingShape _ tile _->tile;Space.RoadShape tile->tile
      inputStock=physical(constructionInput job)
      costWeight=sum[weightOf inventory resource quantity|(resource,quantity)<-M.toList(constructionCost snapshot)]
  check(constructionOrigin job==expectedOrigin)"construction return origin differs from shape"
  either(Left . Space.spaceFailure)Right(Space.checkTile(Space.spatialMap space)expectedOrigin)
  case constructionShape job of
    Space.BuildingShape name tile rotation->do
      building<-either(Left . InvalidReference)Right(lookupBuilding content name)
      (footprint,_)<-either(Left . Space.spaceFailure)Right(Space.footprintGeometry(buildingFootprint building)tile rotation)
      source<-maybe(Left(InvariantViolation "construction natural source absent"))Right(constructionSource job)
      either(Left . Space.spaceFailure)Right(Space.validateBinding content inventory space(Space.sourceRequirements content name)footprint False source)
    Space.RoadShape _->check(constructionSource job==Nothing)"road construction has a natural source"
  when(not(constructionTerminal job))$do
    check(M.lookup(constructionInput job)(invStorage inventory)==Just(Storage 400000 Nothing(constructionColony job)))"construction input schema/colony"
    check(M.lookup(constructionEscrow job)(invStorage inventory)==Just(Storage costWeight Nothing(constructionColony job)))"construction escrow schema/colony"
    check(all(\(resource,quantity)->quantity<=M.findWithDefault 0 resource(constructionCost snapshot))(M.toList inputStock))"unrequested or excess construction input"
    check(phase==ConstructionRunning||constructionProgress job==0)"pre-start construction progress"
  when(phase==ConstructionRunning)(check(M.null inputStock)"running construction retains unescrowed input")
  check(all((/=constructionJobId job).quantityJob)(M.elems(invQuantity inventory))&&all((/=constructionJobId job).capacityJob)(M.elems(invCapacity inventory))&&all((/=constructionJobId job).naturalJob)(M.elems(invNatural inventory)))"construction transient reservation escaped phase"
  when(phase==ConstructionRunning)$do
    check(constructionProgress job<constructionRequired snapshot)"running construction already complete"
    check(physical(constructionEscrow job)==constructionCost snapshot)"construction escrow differs from known cost"
  when(phase/=ConstructionRunning)(check(M.null(physical(constructionEscrow job)))"non-running construction owns escrow stock")
  when(phase==ConstructionCompleted)(check(constructionProgress job==constructionRequired snapshot)"completed construction progress")
  when(phase==ConstructionCancelled)(check(constructionProgress job<constructionRequired snapshot)"cancelled construction has completed progress")
  when(not(constructionTerminal job))$do
    check(M.member(constructionInput job)(invStorage inventory)&&M.member(constructionEscrow job)(invStorage inventory))"construction stores missing"
    placement<-maybe(Left(InvariantViolation "construction placement missing"))Right(M.lookup(constructionSiteId job)(Space.spatialPlacements space))
    check(Space.placementShape placement==constructionShape job&&Space.placementColony placement==constructionColony job&&Space.placementSource placement==constructionSource job)"construction placement/snapshot mismatch"
    check(Space.placementStage placement==if phase==ConstructionRunning then Space.BuildingSite else Space.PlanReserved)"construction spatial lifecycle mismatch"
  when(constructionTerminal job)$do
    check(all((/=constructionJobId job).quantityJob)(M.elems(invQuantity inventory))&&all((/=constructionJobId job).capacityJob)(M.elems(invCapacity inventory))&&all((/=constructionJobId job).naturalJob)(M.elems(invNatural inventory)))"terminal construction reservation"
    case phase of
      ConstructionCancelled->check(not(M.member(constructionSiteId job)(Space.spatialPlacements space))&&not(M.member(constructionInput job)(invStorage inventory))&&not(M.member(constructionEscrow job)(invStorage inventory)))"cancelled construction retains site/input/escrow"
      ConstructionCompleted->do
        placement<-maybe(Left(InvariantViolation "completed construction placement absent"))Right(M.lookup(constructionSiteId job)(Space.spatialPlacements space))
        check(Space.placementStage placement==Space.Built&&Space.placementShape placement==constructionShape job&&Space.placementColony placement==constructionColony job&&Space.placementSource placement==constructionSource job)"completed construction placement differs from snapshot"
        check(not(M.member(constructionEscrow job)(invStorage inventory)))"completed construction escrow store retained"
        case constructionShape job of
          Space.RoadShape _->check(not(M.member(constructionInput job)(invStorage inventory)))"completed road input store retained"
          _->do
            check(M.lookup(constructionInput job)(invStorage inventory)==Just(Storage 400000 Nothing(constructionColony job)))"completed pump input schema/colony"
            check(M.lookup(Owner MachineOutput(constructionSiteId job))(invStorage inventory)==Just(Storage 400000 Nothing(constructionColony job)))"completed pump output schema/colony"
      _->pure()

validateConstruction :: Content -> Inventory -> Space.SpatialState -> ConstructionState -> Either Failure()
validateConstruction content inventory space state=do
  forM_(M.toList(constructionJobs state))$ \(site,job)->do
    unless(site==constructionSiteId job)(Left(InvariantViolation "construction map key mismatch"))
    validateConstructionJob content inventory space job
  let jobIds=map constructionJobId(M.elems(constructionJobs state))
  unless(length jobIds==S.size(S.fromList jobIds))(Left(InvariantViolation "duplicate construction job ID"))
  unless(S.null(S.intersection(S.fromList jobIds)(M.keysSet(constructionJobs state))))(Left(InvariantViolation "construction job/site ID collision"))
  forM_(M.toList(constructionAccountedCosts state))$ \(site,cost)->do
    placement<-maybe(Left(InvariantViolation "accounted cost has no built placement"))Right(M.lookup site(Space.spatialPlacements space))
    expected<-case Space.placementShape placement of
      Space.BuildingShape name _ _->buildingCost <$> either(Left . InvalidReference)Right(lookupBuilding content name)
      Space.RoadShape _->Right(M.singleton Stone 2000)
    unless(Space.placementStage placement==Space.Built&&cost==expected)(Left(InvariantViolation "invalid accounted building cost"))
  forM_(M.elems(constructionJobs state)) $ \job->when(constructionPhase job==ConstructionCompleted)$do
    unless(M.lookup(constructionSiteId job)(constructionAccountedCosts state)==Just(constructionCost(constructionSnapshot job)))(Left(InvariantViolation "completed construction lacks exact accounted cost"))
