module Colony.M1Commands where
import Colony.Construction hiding(ConstructionPlanned,ConstructionCompleted,ConstructionCancelled)
import Colony.Inventory
import Colony.Jobs
import Colony.M1Infrastructure
import Colony.M1State
import Colony.Pickup(reconcilePickups)
import Colony.Topology(topologyRevision,dropPath)
import qualified Colony.Space as Space
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as Workforce
import Colony.World
import Control.Monad(foldM,forM_)
import Control.Monad.State.Strict(get)
import Data.List(sortOn)
import qualified Data.Map.Strict as M

-- Parent whole-boundary rollback remains authoritative. An ordinary command
-- failure returns no candidate World, event, ID allocation or physical transfer.
executeM1Command :: SimTick -> TxId -> World -> Command -> Either Failure(World,Outcome,[DomainEvent])
executeM1Command tick tx world command=do
  state<-maybe(Left(InvalidReference "M1 operation requires schema4 profile"))Right(worldM1 world)
  case command of
    PlaceConstructionPlan colony shape priority selected->do
      requireColony colony state
      ((job,space),inventory)<-runInventory(placeConstruction(worldContent world)tick colony shape priority selected(m1Space state))(worldInventory world)
      let construction=(m1Construction state){constructionJobs=M.insert(constructionSiteId job)job(constructionJobs(m1Construction state))}
      (mapped,transport)<-syncInfrastructure(worldContent world)inventory(boundarySeq world)construction space(worldTransport world)
      let next=world{worldInventory=inventory,worldTransport=transport,worldM1=Just state{m1Space=mapped,m1Construction=construction}}
      pure(next,Applied(Just(constructionSiteId job)),[ConstructionPlanned(EventId tx 0)(constructionSiteId job)])
    CancelConstructionPlan site revision->do
      job<-maybe(Left TargetGone)Right(M.lookup site(constructionJobs(m1Construction state)))
      ((cancelled,space,transport),inventory)<-runInventory(do
        let detached=(worldTransport world){transportPorts=M.delete(constructionInput job)(transportPorts(worldTransport world))}
            incident=[requestId request|request<-M.elems(transportRequests detached),requestStatus request==RequestOpen
              ,requestSource request==constructionInput job||requestDestination request==constructionInput job]
        cancelledDeliveries<-foldM(\current ident->cancelDelivery tick ident current)detached incident
        current<-get
        bound<-either throwTx pure(bindTransportCaches(worldContent world)current cancelledDeliveries(m1Space state))
        (changed,space)<-cancelConstruction(worldContent world)tx revision job bound
        retired<-retireTransportPort(boundarySeq world)(constructionInput job)cancelledDeliveries
        pure(changed,space,retired))(worldInventory world)
      let construction=(m1Construction state){constructionJobs=M.insert site cancelled(constructionJobs(m1Construction state))}
          workforce=Workforce.retireTarget(Workforce.ConstructSite site)(m1Workforce state)
      (mapped,connected)<-syncInfrastructure(worldContent world)inventory(boundarySeq world)construction space transport
      pure(world{worldInventory=inventory,worldTransport=connected,worldM1=Just state{m1Space=mapped,m1Construction=construction,m1Workforce=workforce}},Applied(Just site),[ConstructionCancelled(EventId tx 0)site])
    AssignWorkers target shift residents->do
      catalog<-workTargetCatalog world
      workforce<-either(Left . Workforce.workforceFailure)Right(Workforce.assignWorkers catalog(worldNeeds world)target shift residents(m1Workforce state))
      pure(world{worldM1=Just state{m1Workforce=workforce}},Applied Nothing,[WorkersAssigned(EventId tx 0)target])
    _->Left(InvalidReference "not an M1 command")
  where requireColony colony state=if M.member colony(m1ColonyDepots state)then Right()else Left TargetGone

-- Unreceived material is requestRemaining plus live delivery children, never
-- the original requested quantity plus its children (which double counts).
constructionIncoming :: TransportState -> Owner -> Resource -> Integer
constructionIncoming=incomingDeliveryQuantity

validateM1Delivery :: World -> Owner -> Owner -> Resource -> Integer -> Either Failure()
validateM1Delivery world source destination resource quantity=case worldM1 world of
  Nothing->Right()
  Just state->do
    let jobs=M.elems(constructionJobs(m1Construction state))
        activeInputs=[constructionInput job|job<-jobs,not(constructionTerminal job)]
        allEscrows=[constructionEscrow job|job<-jobs]
    -- Active construction input cannot be drained behind its cost contract.
    -- The cancellation command is the explicit, accounted return path.
    if source `elem` activeInputs||source `elem` allEscrows||destination `elem` allEscrows
      then Left(InvalidReference "Construction site material is managed by its plan")else Right()
    case [job|job<-jobs,constructionInput job==destination,not(constructionTerminal job)]of
      []->Right()
      job:_->admitConstructionDelivery job resource quantity(constructionIncoming(worldTransport world)destination resource)(worldInventory world)

cancelProductionSpatial :: TxId -> World -> Job -> Either Failure(World,Job)
cancelProductionSpatial tx world job=do
  state<-maybe(Left(InvalidReference "spatial cancellation without M1"))Right(worldM1 world)
  siteIdValue<-maybe(Left TargetGone)Right(M.lookup(jobId job)(worldJobSites world))
  placement<-maybe(Left TargetGone)Right(M.lookup siteIdValue(Space.spatialPlacements(m1Space state)))
  let origin=case Space.placementShape placement of Space.BuildingShape _ tile _->tile;Space.RoadShape tile->tile
      context=Space.CacheContext origin(Space.placementColony placement)(Space.RecipeReturn(jobId job))
  ((cancelled,space),inventory)<-runInventory(do
    ordinary<-tryInventory(cancelJob(worldRuleset world)tx job)
    case ordinary of
      Right next->pure(next,m1Space state)
      Left ReturnCapacityFull->do
        require(jobPhase job==Running)AlreadyTerminal
        initial<-get
        let lots=filter((==wipOwner job).lotOwner)(M.elems(invLots initial))
        releaseJob(jobId job)
        forM_(resourceLotGroups lots)$ \(_,group)->loseResourceGroup tx job(jobProgress job)(jobRequired job)group
        (space,_)<-returnPhysicalToSpace(worldContent world)context[wipOwner job][jobOutput job](m1Space state)
        pure(job{jobPhase=Cancelled,jobBlocked=Nothing,jobTerminalCount=jobTerminalCount job+1},space)
      Left reason->throwTx reason)(worldInventory world)
  (mapped,transport)<-syncInfrastructure(worldContent world)inventory(boundarySeq world)(m1Construction state)space(worldTransport world)
  let workforce=Workforce.releaseTargetClaims(Workforce.OperateFacility siteIdValue)(m1Workforce state)
  pure(world{worldInventory=inventory,worldTransport=transport,worldM1=Just state{m1Space=mapped,m1Workforce=workforce}},cancelled)

-- Any legacy operation may have created a road-node return cache. Reconcile it
-- before P10, preserving one physical owner and one2,000,000g tile capacity.
reconcileM1Infrastructure :: World -> Either Failure World
reconcileM1Infrastructure world=case worldM1 world of
  Nothing->Right world
  Just state->do
    bound<-bindTransportCaches(worldContent world)(worldInventory world)(worldTransport world)(m1Space state)
    (space,transport)<-syncInfrastructure(worldContent world)(worldInventory world)(boundarySeq world)(m1Construction state)bound(worldTransport world)
    let topologyChanged=topologyRevision(transportTopology transport)/=topologyRevision(transportTopology(worldTransport world))
        -- A source port/road edit invalidates the saved empty-trip return/fuel
        -- witness. Keep the parent rights, finish the paid edge and go home;
        -- the request may dispatch again with a fresh real route/fuel plan.
        invalidated=[ident|ident<-M.keys(m1Pickups state),topologyChanged||maybe True((/=topologyRevision(transportTopology transport)).vehicleRouteRevision)(M.lookup ident(transportVehicles transport))]
        reset=transport{transportVehicles=foldr(M.adjust(\vehicle->vehicle{vehicleRoute=[],vehicleBlock=case vehiclePosition vehicle of AtRoadNode _->Nothing;_->vehicleBlock vehicle}))(transportVehicles transport)invalidated
          ,transportPaths=foldr dropPath(transportPaths transport)invalidated}
        (routed,pickups)=reconcilePickups(worldInventory world)reset(foldr M.delete(m1Pickups state)invalidated)
        boundState=state{m1Space=space,m1Pickups=pickups}
        idle=[Workforce.DriveVehicle(vehicleId vehicle)|vehicle<-M.elems(transportVehicles routed),not(vehicleHasLiveDuty boundState vehicle)]
        cleaned=boundState{m1Workforce=foldr Workforce.releaseTargetClaims(m1Workforce boundState)idle}
    pure world{worldM1=Just cleaned,worldTransport=routed}

-- V4 P8-final cleanup. Empty caches are temporary physical containers, not
-- permanent invisible terrain. Outstanding capacity/quantity rights prevent
-- retirement; referenced old owner IDs remain explicit transport tombstones.
retireEmptyCaches :: SimTick -> World -> Either Failure(World,[(Owner,Space.Tile)])
retireEmptyCaches tick world=case worldM1 world of
  Nothing->Right(world,[])
  Just state->do
    let inventory=worldInventory world
        empty owner=not(any((==owner).lotOwner)(M.elems(invLots inventory)))
          &&not(any((==owner).capacityOwner)(M.elems(invCapacity inventory)))
          &&not(any(\claim->maybe False((==owner).lotOwner)(M.lookup(quantityLot claim)(invLots inventory)))(M.elems(invQuantity inventory)))
        retiring=sortOn fst[(Space.cacheOwner cache,tile)|(tile,cache)<-M.toList(Space.spatialCaches(m1Space state)),empty(Space.cacheOwner cache)]
    if null retiring then Right(world,[])else do
      ((space,transport),after)<-runInventory(foldM retire(m1Space state,worldTransport world)retiring)inventory
      let changed=world{worldInventory=after,worldTransport=transport,worldM1=Just state{m1Space=space}}
      connected<-reconcileM1Infrastructure changed
      pure(connected,retiring)
  where
    retire(space,transport)(owner,tile)=do
      deleteEmptyStorage owner
      ports<-retireTransportPort(boundarySeq world)owner transport
      -- Fully loaded outbound children can still finish. Only work still
      -- needing the vanished endpoint fails, and cancellation keeps cargo in
      -- ordinary Return jobs rather than stranding an unreserved request.
      let waiting=[request|request<-M.elems(transportRequests ports),requestStatus request==RequestOpen
            ,requestDestination request==owner||(requestSource request==owner&&requestRemaining request>0)]
      stopped<-foldM(\current request->terminateRequest tick RequestFailed request current)ports waiting
      pure(space{Space.spatialCaches=M.delete tile(Space.spatialCaches space),Space.spatialOwnerLocations=M.delete owner(Space.spatialOwnerLocations space)},stopped)
