-- Real schema4 phase execution. Shared boundary protocol, inventory transactions,
-- production/transport/power/needs modules remain the simulation authorities.
module Colony.M1Scheduler(runM1Phases) where
import qualified Colony.Construction as C
import Colony.Inventory
import Colony.Jobs
import Colony.M1Commands
import Colony.M1State
import Colony.M1Logistics
import Colony.Pickup
import Colony.Maintenance
import Colony.Needs
import qualified Colony.SchedulerCore as Base
import Colony.Transport
import Colony.Types
import qualified Colony.Workforce as W
import Colony.World
import Control.Monad(foldM,unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word(Word64)

type Duties=M.Map W.WorkTarget W.DutyEvidence
type Staged=(World,ColonyOutput,Duties)
type Checked a=Base.Checked a
fatal :: Phase -> Either Failure a -> Checked a
fatal=Base.fatal
workforce :: Phase -> Either W.WorkforceError a -> Checked a
workforce phase=fatal phase . either(Left . W.workforceFailure)Right
context :: SimTick -> W.TickContext
context tick@(SimTick n)=W.TickContext tick(toInteger(n `mod` 28800 `div` 9600))
getM1 :: World -> Checked M1State
getM1 world=maybe(Left(P10,InvariantViolation "M1 state absent"))Right(worldM1 world)
setWorkforce :: World -> W.WorkforceState -> World
setWorkforce world next=world{worldM1=fmap(\state->state{m1Workforce=next})(worldM1 world)}
basePhase :: (Base.Staged -> Checked Base.Staged) -> Staged -> Checked Staged
basePhase operation(world,out,duties)=do
  (next,output)<-operation(world,out)
  connected<-fatal P10(reconcileM1Infrastructure next)
  pure(connected,output,duties)

runM1Phases :: NativeInput -> World -> Checked Base.Staged
runM1Phases(Boundary header commands management) original=do
  let SimTick oldTick=simTick original;BoundarySeq oldBoundary=boundarySeq original
  unless(oldBoundary<maxBound&&worldRevision original<maxBound&&not(advanceSim header&&oldTick==maxBound))(Left(P0,CounterOverflow))
  let tick=SimTick(oldTick+if advanceSim header then 1 else 0)
  (commanded,commandOutput)<-foldM(apply tick)(original,mempty)commands
  let managed=foldl(\world event->world{worldMode=case event of PauseWorld->Paused;ResumeWorld->Active})commanded management
  (candidate,out,_)<-if advanceSim header then do
      p2<-basePhase(Base.phaseExpiry tick)(managed,commandOutput,M.empty)
      reconciled<-reconcilePhase tick p2
      p3<-basePhase(Base.phasePaths tick)reconciled
      p4<-driverPhase P4 tick 0 p3
      p5<-startPhase tick p4
      p6<-basePhase(Base.phasePower tick)p5
      (p7,ordinal)<-workPhase tick p6
      entered<-driverPhase P7 tick ordinal p7
      needsPhase tick entered
    else pure(managed,commandOutput,M.empty)
  let committed=candidate{boundarySeq=BoundarySeq(oldBoundary+1)
        ,worldRevision=worldRevision original+if candidate/=original then 1 else 0
        ,worldRecentEvents=take 256(reverse(outputEvents out)++worldRecentEvents candidate)}
  fatal P10(validateWorld committed)
  pure(committed,out)
  where
    apply tick staged command=do
      (world,out)<-Base.applyCommand tick staged command
      connected<-fatal P1(reconcileM1Infrastructure world)
      retired<-retireGoneTargets connected
      pure(retired,out)

retireGoneTargets :: World -> Checked World
retireGoneTargets world=do
  state<-getM1 world
  catalog<-fatal P10(workTargetCatalog world)
  let wf=m1Workforce state
      missing=S.toList(S.fromList[target|((target,_),_)<-M.toList(W.workforceRosters wf),not(M.member target catalog)])
      next=foldr W.retireTarget wf missing
  pure(setWorkforce world next)
reconcilePhase :: SimTick -> Staged -> Checked Staged
reconcilePhase tick(world,out,duties)=do
  retired<-retireGoneTargets world
  state<-getM1 retired
  catalog<-fatal P2(workTargetCatalog retired)
  reconciled<-workforce P2(W.reconcileClaims(context tick)catalog(worldNeeds retired)(m1Workforce state))
  let running=S.fromList[site|job<-M.elems(worldJobs retired),jobPhase job==Running,Just site<-[M.lookup(jobId job)(worldJobSites retired)]]
      idle=[target|target@(W.OperateFacility ident)<-M.elems(W.workforceClaims reconciled),M.member ident(worldSites retired),not(S.member ident running)]
  pure(setWorkforce retired(foldr W.releaseTargetClaims reconciled idle),out,duties)

claim :: Phase -> SimTick -> W.WorkTarget -> World -> Checked(World,W.CrewView)
claim phase tick target world=do
  state<-getM1 world
  catalog<-fatal phase(workTargetCatalog world)
  (next,view)<-workforce phase(W.claimCrew(context tick)catalog(worldNeeds world)(m1Workforce state)target)
  pure(setWorkforce world next,view)
credit :: Phase -> SimTick -> W.WorkTarget -> Integer -> World -> Checked Integer
credit phase tick target maintenance world=do
  state<-getM1 world;catalog<-fatal phase(workTargetCatalog world)
  (_,amount)<-workforce phase(W.crewCredit(context tick)catalog(worldNeeds world)(m1Workforce state)target 100 maintenance)
  pure amount
capture :: Phase -> SimTick -> W.WorkTarget -> Maybe Integer -> World -> Duties -> Checked Duties
capture phase tick target amount world duties=do
  state<-getM1 world;catalog<-fatal phase(workTargetCatalog world)
  let wf=m1Workforce state;ids=M.keys(M.filter(==target)(W.workforceClaims wf))
  if null ids then pure duties else do
    evidence<-workforce phase $ case amount of
      Just n|n>0->W.captureCreditedDuty(context tick)catalog(worldNeeds world)wf target ids n
      _->W.captureHeldDuty(context tick)catalog(worldNeeds world)wf target ids
    workforce phase(W.recordDuty evidence duties)
release :: W.WorkTarget -> World -> World
release target world=world{worldM1=fmap(\s->s{m1Workforce=W.releaseTargetClaims target(m1Workforce s)})(worldM1 world)}

prepareDrivers :: Phase -> SimTick -> World -> Checked World
prepareDrivers phase tick initial=foldM one initial(M.keys(transportVehicles(worldTransport initial)))
  where
    one world ident=do
      state<-getM1 world;catalog<-fatal phase(workTargetCatalog world)
      let target=W.DriveVehicle ident;vehicle=transportVehicles(worldTransport world)M.!ident
          bound=vehicleHasLiveDuty state vehicle
      view<-workforce phase(W.observeCrew(context tick)catalog(worldNeeds world)(m1Workforce state)target)
      (next,actual)<-if bound then claim phase tick target world else pure(release target world,view)
      let transport=worldTransport next
      pure next{worldTransport=transport{transportVehicles=M.adjust(\v->v{vehicleHasDriver=W.crewReady actual})ident(transportVehicles transport)}}

driverPhase :: Phase -> SimTick -> Word64 -> Staged -> Checked Staged
driverPhase phase tick ordinal(world,out,duties)=do
  prepared<-prepareDrivers phase tick world
  state<-getM1 prepared
  let before=worldTransport prepared
      targets=pickupTargets before(m1Pickups state)
      fuelWaiting=M.keysSet(M.filter(not . pickupFuelReady)(m1Pickups state))
      action=case phase of P4->phaseTransportArrivalWithPolicy True targets tick;P7->phaseTransportEnterWithFuelGate fuelWaiting(Base.mkTx prepared P7 ordinal)tick;_->pure
  (transport,inventory)<-fatal phase(runInventory(action before)(worldInventory prepared))
  connected<-fatal phase(reconcileM1Infrastructure prepared{worldTransport=transport,worldInventory=inventory})
  recorded<-foldM(\recorded ident->do
    let moved=phase==P4&&case(M.lookup ident(transportVehicles before),M.lookup ident(transportVehicles transport))of
          (Just old,Just new)->case vehiclePosition old of Traversing{}->vehiclePosition old/=vehiclePosition new;_->False
          _->False
    capture phase tick(W.DriveVehicle ident)(if moved then Just 100 else Nothing)prepared recorded) duties(M.keys(transportVehicles transport))
  pure(connected,out,recorded)

-- Bound256 assignment attempts across maintenance, transport, production and
-- construction. Legacy scheduler remains byte-identical; this slice retains the
-- existing class ordering, with per-class stable IDs (global ageing is a ledger gate).
startPhase :: SimTick -> Staged -> Checked Staged
startPhase tick(world,out,duties)=do
  maintenance<-foldM startMaintenanceOne(world{worldMaintenanceAttempts=0},out,duties)
    (take 256[job|job<-M.elems(maintenanceJobs(worldMaintenance world)),maintenancePhase job==MaintenancePlanned])
  let (m,mo,md)=maintenance
  prepared<-prepareDrivers P5 tick m
  fuelled<-fatal P5(preparePickupFuel tick prepared)
  assigned<-fatal P5(assignM1Transport tick(256-worldMaintenanceAttempts fuelled)fuelled)
  after<-fatal P5(reconcileM1Infrastructure assigned)
  let budget=256-worldMaintenanceAttempts after-transportLastAssignments(worldTransport after)
      recipes=[(0::Int,jobId job)|job<-M.elems(worldJobs after),not(terminal job),jobPhase job/=Running]
  state<-getM1 after
  let construction=[(1,C.constructionSiteId job)|job<-M.elems(C.constructionJobs(m1Construction state)),not(C.constructionTerminal job),C.constructionPhase job/=C.ConstructionRunning]
  foldM startOne(after,mo,md)(zip[0..](take(fromIntegral budget)(recipes++construction)))
  where
    startMaintenanceOne(current,outputs,recorded) job=do
      (claimed,crew)<-claim P5 tick(W.MaintainJob(maintenanceJobId job))current
      let attempted=claimed{worldMaintenanceAttempts=worldMaintenanceAttempts claimed+1}
      case runInventory(startMaintenance(maintenanceJobId job)(if W.crewReady crew then 1 else 0)(worldMaintenance attempted))(worldInventory attempted)of
        Left err|Base.fatalFailure err->Left(P5,err)
                |otherwise->pure(release(W.MaintainJob(maintenanceJobId job))attempted,outputs,recorded)
        Right(next,inv)->let result=attempted{worldMaintenance=next,worldInventory=inv}
                        in pure(if maybe True((/=MaintenanceRunning).maintenancePhase)(M.lookup(maintenanceJobId job)(maintenanceJobs next))then release(W.MaintainJob(maintenanceJobId job))result else result,outputs,recorded)
    startOne(current,outputs,recorded)(ordinal,(kind,ident))
      |kind==0=do
        job<-maybe(Left(P5,TargetGone))Right(M.lookup ident(worldJobs current))
        sid<-maybe(Left(P5,TargetGone))Right(M.lookup ident(worldJobSites current))
        (claimed,crew)<-claim P5 tick(W.OperateFacility sid)current
        let ready=if W.crewReady crew then Base.readySite claimed job>>Right()else Left(InvalidReference "WaitingWorkers")
            started=ready>>runInventory(startJob(worldContent claimed)tick job)(worldInventory claimed)
        case started of
          Left err|Base.fatalFailure err->Left(P5,err)
                  |otherwise->pure((release(W.OperateFacility sid)claimed){worldJobs=M.insert ident(job{jobPhase=WaitingInputs,jobBlocked=Just err})(worldJobs claimed)},outputs,recorded)
          Right(next,inventory)->pure(claimed{worldJobs=M.insert ident next(worldJobs claimed),worldInventory=inventory},outputs{outputEvents=outputEvents outputs++[JobStarted(EventId(Base.mkTx claimed P5 ordinal)0)ident]},recorded)
      |otherwise=do
        state<-getM1 current
        job<-maybe(Left(P5,TargetGone))Right(M.lookup ident(C.constructionJobs(m1Construction state)))
        (claimed,crew)<-claim P5 tick(W.ConstructSite ident)current
        claimedState<-getM1 claimed
        case runInventory(C.startConstruction(worldContent claimed)tick(W.crewReady crew)job(m1Space claimedState))(worldInventory claimed)of
          Left err|Base.fatalFailure err->Left(P5,err)
                  |otherwise->do
                    let hasIncoming=any(\r->constructionIncoming(worldTransport claimed)(C.constructionInput job)r>0)(M.keys(C.constructionCost(C.constructionSnapshot job)))
                    (waiting,inventory)<-fatal P5(runInventory(C.setConstructionWaiting hasIncoming err job)(worldInventory claimed))
                    let changed=putConstruction waiting claimed{worldInventory=inventory}
                    pure(release(W.ConstructSite ident)changed,outputs,recorded)
          Right((next,space),inventory)->do
            let changed=putConstruction next claimed{worldInventory=inventory,worldM1=Just claimedState{m1Space=space}}
            pure(changed,outputs{outputEvents=outputEvents outputs++[ConstructionStarted(EventId(Base.mkTx claimed P5 ordinal)0)ident]},recorded)

putConstruction :: C.ConstructionJob -> World -> World
putConstruction job world=world{worldM1=fmap(\s->s{m1Construction=(m1Construction s){C.constructionJobs=M.insert(C.constructionSiteId job)job(C.constructionJobs(m1Construction s))}})(worldM1 world)}

workPhase :: SimTick -> Staged -> Checked(Staged,Word64)
workPhase tick initial@(world,_,_)=do
  let recipes=[jobId job|job<-M.elems(worldJobs world),jobPhase job==Running]
  state<-getM1 world
  let construction=[C.constructionSiteId job|job<-M.elems(C.constructionJobs(m1Construction state)),C.constructionPhase job==C.ConstructionRunning]
      maintenance=[maintenanceJobId job|job<-M.elems(maintenanceJobs(worldMaintenance world)),maintenancePhase job==MaintenanceRunning]
      jobs=map((,)0)recipes++map((,)1)construction++map((,)2)maintenance
  next<-foldM work initial(zip[0..]jobs)
  pure(next,fromIntegral(length jobs))
  where
    work staged@(current,outputs,duties)(ordinal,(kind::Int,ident))
      |kind==0=do
        job<-maybe(Left(P7,TargetGone))Right(M.lookup ident(worldJobs current))
        sid<-maybe(Left(P7,TargetGone))Right(M.lookup ident(worldJobSites current))
        (claimed,_)<-claim P7 tick(W.OperateFacility sid)current
        let stopped=Base.readySite claimed job >>= \site->if Base.sitePowered claimed site then Right site else Left(InvalidReference "NoPower")
        case stopped of
          Left reason->do
            recorded<-capture P7 tick(W.OperateFacility sid)Nothing claimed duties
            pure(claimed{worldJobs=M.insert ident(job{jobBlocked=Just reason})(worldJobs claimed)},outputs,recorded)
          Right site->do
            amount<-credit P7 tick(W.OperateFacility sid)(Base.siteMaintenancePct claimed site)claimed
            recorded<-capture P7 tick(W.OperateFacility sid)(Just amount)claimed duties
            let advanced=job{jobProgress=min(jobRequired job)(jobProgress job+amount),jobBlocked=Nothing}
                operating=if amount>0 then S.insert sid(worldOperatingFacilities claimed)else worldOperatingFacilities claimed
                working=claimed{worldOperatingFacilities=operating}
            if jobProgress advanced<jobRequired advanced then pure(working{worldJobs=M.insert ident advanced(worldJobs working)},outputs,recorded)else do
              (completed,inventory)<-fatal P7(runInventory(completeJob(worldContent working)(Base.mkTx working P7 ordinal)tick advanced)(worldInventory working))
              pure(release(W.OperateFacility sid)working{worldInventory=inventory,worldJobs=M.insert ident completed(worldJobs working)},outputs{outputEvents=outputEvents outputs++[JobCompleted(EventId(Base.mkTx working P7 ordinal)0)ident]},recorded)
      |kind==1=do
        state<-getM1 current
        job<-maybe(Left(P7,TargetGone))Right(M.lookup ident(C.constructionJobs(m1Construction state)))
        (claimed,crew)<-claim P7 tick(W.ConstructSite ident)current
        amount<-credit P7 tick(W.ConstructSite ident)100 claimed
        recorded<-capture P7 tick(W.ConstructSite ident)(Just amount)claimed duties
        claimedState<-getM1 claimed
        ((advanced,space,completion),inventory)<-fatal P7(runInventory(C.advanceConstruction(worldContent claimed)(Base.mkTx claimed P7 ordinal)amount job(m1Space claimedState))(worldInventory claimed))
        let blocked=advanced{C.constructionBlocked=if W.crewReady crew then Nothing else Just(InvalidReference "WaitingWorkers")}
            changed=putConstruction blocked claimed{worldInventory=inventory,worldM1=Just claimedState{m1Space=space}}
        case completion of
          Nothing->pure(changed,outputs,recorded)
          Just result->do
            completed<-finishConstruction result advanced changed
            connected<-fatal P7(reconcileM1Infrastructure completed)
            pure(connected,outputs{outputEvents=outputEvents outputs++[ConstructionCompleted(EventId(Base.mkTx current P7 ordinal)0)ident]},recorded)
      |kind==2=do
        job<-maybe(Left(P7,TargetGone))Right(M.lookup ident(maintenanceJobs(worldMaintenance current)))
        (claimed,crew)<-claim P7 tick(W.MaintainJob ident)current
        amount<-credit P7 tick(W.MaintainJob ident)100 claimed
        recorded<-capture P7 tick(W.MaintainJob ident)(Just amount)claimed duties
        (maintenance,inventory)<-fatal P7(runInventory(workMaintenance(Base.mkTx claimed P7 ordinal)ident(if W.crewReady crew then 1 else 0)amount(worldMaintenance claimed))(worldInventory claimed))
        let changed=claimed{worldMaintenance=maintenance,worldInventory=inventory}
        retired<-if maybe False maintenanceTerminal(M.lookup ident(maintenanceJobs maintenance))then retireGoneTargets changed else pure changed
        -- Maintenance target is stopped while repaired; only its crew receives XP.
        job `seq` pure(retired,outputs,recorded)
      |otherwise=pure staged

finishConstruction :: C.ConstructionCompletion -> C.ConstructionJob -> World -> Checked World
finishConstruction completion job world=do
  state<-getM1 world
  let costs=M.insert(C.constructionSiteId job)(C.constructionCost(C.constructionSnapshot job))(C.constructionAccountedCosts(m1Construction state))
      newState=state{m1Construction=(m1Construction state){C.constructionAccountedCosts=costs}
        ,m1Workforce=W.retireTarget(W.ConstructSite(C.constructionSiteId job))(m1Workforce state)}
      base=world{worldM1=Just newState}
  case completion of
    C.PumpConstructed ident input output source->do
      facility<-fatal P7(newFacility(worldContent world)ident "hand_pump")
      let site=Site ident "hand_water" input output(M.singleton "aquifer" source)2 True
      pure base{worldSites=M.insert ident site(worldSites base)
        ,worldMaintenance=(worldMaintenance base){maintenanceFacilities=M.insert ident facility(maintenanceFacilities(worldMaintenance base))}}
    C.RoadConstructed _ _->pure base

needsPhase :: SimTick -> Staged -> Checked Staged
needsPhase tick(world,out,duties)=do
  let allPantries=needsPantries(worldNeeds world)
      owners=S.toAscList(S.fromList(concat(M.elems allPantries)))
  (staffed,active,recorded)<-foldM staff(world,S.empty,duties)owners
  state<-getM1 staffed;catalog<-fatal P8(workTargetCatalog staffed)
  (fatigued,workers,_)<-workforce P8(W.advanceWorkforce W.PositiveCreditElapsedTick(context tick)catalog(worldNeeds staffed)(m1Workforce state)recorded)
  let withActivePantries=fatigued{needsPantries=M.map(filter(`S.member`active))allPantries}
  ((consumed,_),inventory)<-fatal P8(runInventory(stepNeedsWithFatigue False(Base.mkTx staffed P8 0)tick withActivePantries)(worldInventory staffed))
  let nextNeeds=consumed{needsPantries=allPantries}
  reconciled<-workforce P8(W.reconcileClaims(context tick)catalog nextNeeds workers)
  maintenance<-fatal P8(advanceFacilities True tick(worldWeather staffed)(worldOperatingFacilities staffed)(worldMaintenance staffed))
  let hadPopulation=any((/=Evacuated).residentStatus)(M.elems(needsResidents(worldNeeds staffed)))
      abandoned=hadPopulation&&all((==Evacuated).residentStatus)(M.elems(needsResidents nextNeeds))
  let serviced=staffed{worldInventory=inventory,worldNeeds=nextNeeds,worldMaintenance=maintenance
        ,worldOperatingFacilities=S.empty,worldMode=if abandoned then Abandoned else worldMode staffed
        ,worldM1=Just state{m1Workforce=reconciled}}
  (cleaned,retired)<-fatal P8(retireEmptyCaches tick serviced)
  let events=[GroundCacheRetired(EventId(Base.mkTx cleaned P8 ordinal)0)owner tile|(ordinal,(owner,tile))<-zip[1..]retired]
  pure(cleaned,out{outputEvents=outputEvents out++events},recorded)
  where
    staff(current,active,recorded)owner@(Owner _ ident)=do
      (claimed,crew)<-claim P8 tick(W.OperateFacility ident)current
      captured<-capture P8 tick(W.OperateFacility ident)Nothing claimed recorded
      pure(claimed,if W.crewReady crew then S.insert owner active else active,captured)
