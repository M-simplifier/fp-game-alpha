module Colony.SchedulerCore where
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Types
import Colony.World
import Colony.Power
import Colony.Needs
import Colony.Transport
import Colony.Maintenance
import Colony.M1Commands
import Colony.M1State
import qualified Colony.Workforce as Workforce
import qualified Data.Set as S
import Control.DeepSeq (deepseq)
import Control.Monad (foldM, unless)
import qualified Data.Map.Strict as M
import Data.List (find)
import Data.Word (Word64)

type Staged = (World,ColonyOutput)
type Checked a = Either (Phase,Failure) a
fatal :: Phase -> Either Failure a -> Checked a
fatal phase=either(Left . (phase,))Right

pureStepWith :: (NativeInput -> World -> Checked Staged) -> NativeInput -> World -> (World,ColonyOutput)
pureStepWith executePhases native@(Boundary _ commands _) original = case validateBoundary native original of
  Left reason->(original,ColonyOutput [] [] [FatalBoundaryRejected reason])
  Right ()->case executePhases native original of
    Left(phase,reason)->(original {worldMode=Faulted reason},ColonyOutput [] [] [FaultDiagnostic phase reason(map commandId commands)])
    Right(next,output)->next `deepseq` output `deepseq` (next,output)

validateBoundary :: NativeInput -> World -> Either String ()
validateBoundary (Boundary h commands _) w=do
  let check b m=unless b(Left m)
  check(headerWorld h==worldId w && headerBranch h==branchId w) "world/branch mismatch"
  check(headerAuthority h==worldAuthority w && headerRuleset h==worldRuleset w) "authority/ruleset mismatch"
  check(expectedBoundarySeq h==boundarySeq w) "boundary sequence mismatch"
  check(worldMode w==Active || worldMode w==Paused) "world faulted"
  check(not(advanceSim h) || worldMode w==Active) "paused world cannot advance"
  check(all(commandAllowedInRuleset(worldRuleset w).commandBody)commands) "command vocabulary/profile mismatch"
  check(length commands<=256) "command fuel exceeded"
  check(map commandOrdinal commands==take(length commands)[0..]) "command ordinal mismatch"
  -- Session epoch and role admission is also checked here: direct kernel replay cannot bypass it.
  mapM_ (\cmd->case commandId cmd of
    CommandId wid controller epoch _->do
      check(wid==worldId w) "command world mismatch"
      p<-maybe(Left "unknown controller")Right(M.lookup controller(worldParticipants w))
      check(participantEpoch p==epoch) "epoch mismatch"
      check(participantRole p/=ViewerRole) "viewer mutation") commands
  check(M.size(M.fromList[(commandId c,())|c<-commands])==length commands) "duplicate command ID"
  _<-foldM (\water cmd->do
    let cid@(CommandId _ controller epoch n)=commandId cmd; high=M.findWithDefault 0(controller,epoch)water
    check(n<=high || (high<maxBound && n==high+1)) "NeedSequence"
    case find((==cid).receiptCommand)(worldReceipts w) of
      Just receipt->check(receiptBody receipt==commandBody cmd) "SequenceCollision"
      Nothing->Right()
    pure(M.insert(controller,epoch)(max n high)water)) (worldHighWater w) commands
  pure()

runPhases :: NativeInput -> World -> Checked Staged
runPhases (Boundary h commands management) original=do
  let SimTick tick=simTick original; BoundarySeq seqn=boundarySeq original
  if seqn==maxBound || (advanceSim h && tick==maxBound) || worldRevision original==maxBound then Left(P0,CounterOverflow) else Right()
  let evaluation=SimTick(tick+if advanceSim h then 1 else 0)
  p1<-foldM (applyCommand evaluation) (original,mempty) commands
  let (w1,o1)=p1
      managed=foldl (\w event->w {worldMode=case event of PauseWorld->Paused;ResumeWorld->Active}) w1 management
  result<-if advanceSim h then do
    p2<-phaseExpiry evaluation(managed,o1)
    p3<-phasePaths evaluation p2
    p4<-phaseTransport P4 evaluation 0 p3
    p5Maintenance<-phaseMaintenanceStart p4
    p5Transport<-phaseTransport P5 evaluation 0 p5Maintenance
    p5<-phaseStart evaluation p5Transport
    p6<-phasePower evaluation p5
    p7<-phaseWork evaluation p6
    let productionCount=fromIntegral(length(filter((==Running).jobPhase)(M.elems(worldJobs(fst p6)))))
    (p7Maint,maintenanceCount)<-phaseMaintenanceWork productionCount p7
    entered<-phaseTransport P7 evaluation (productionCount+maintenanceCount) p7Maint
    p8<-phaseNeeds evaluation entered
    -- P9 campaign/progression remains explicitly unfinished.
    pure p8
    else pure(managed,o1)
  let (precommit,out)=result
      committed=precommit {boundarySeq=BoundarySeq(seqn+1),worldRevision=worldRevision original+if precommit/=original then 1 else 0
                          ,worldRecentEvents=take 256(reverse(outputEvents out)++worldRecentEvents precommit)}
  fatal P10(validateWorld committed)
  pure(committed,out)

mkTx :: World -> Phase -> Word64 -> TxId
mkTx w phase ordinal=TxId(worldId w)(branchId w)(boundarySeq w)phase ordinal

applyCommand :: SimTick -> Staged -> OrderedCommand -> Checked Staged
applyCommand evaluation (w,out) cmd=do
  let cid@(CommandId _ controller epoch sequenceNumber)=commandId cmd
      high=M.findWithDefault 0(controller,epoch)(worldHighWater w)
      tx=mkTx w P1(commandOrdinal cmd)
      receipt outcome=CommandReceipt cid(boundarySeq w)outcome tx(commandBody cmd)
  case find((==cid).receiptCommand)(worldReceipts w) of
    Just old | receiptBody old/=commandBody cmd ->Left(P1,InvalidReference "SequenceCollision")
             | otherwise->Right(w,out {outputReceipts=outputReceipts out++[old]})
    Nothing | sequenceNumber<=high->Right(w,out {outputReceipts=outputReceipts out++[receipt AlreadyProcessed]})
            | sequenceNumber/=high+1 || high==maxBound->Left(P1,InvalidReference("NeedSequence "++show(high+1)))
            | otherwise->do
                (next,outcome,events)<-executeCommand evaluation tx w(commandBody cmd)
                let rec=receipt outcome
                    recent=retainReceipts (rec:worldReceipts next)
                    committed=next {worldHighWater=M.insert(controller,epoch)sequenceNumber(worldHighWater next),worldReceipts=recent}
                pure(committed,out {outputReceipts=outputReceipts out++[rec],outputEvents=outputEvents out++events})

retainReceipts :: [CommandReceipt] -> [CommandReceipt]
retainReceipts=go M.empty where
  go _ []=[]
  go counts(r:rs)=let CommandId _ controller _ _=receiptCommand r;n=M.findWithDefault(0::Word64)controller counts
                 in if n>=4096 then go counts rs else r:go(M.insert controller(n+1)counts)rs

executeCommand :: SimTick -> TxId -> World -> Command -> Checked (World,Outcome,[DomainEvent])
executeCommand evaluation tx w command=case command of
  OrderProduction ident->case M.lookup ident(worldSites w) of
    Nothing->pure(w,CommandFailed TargetGone,[])
    Just site | any(\j->not(terminal j)&&M.lookup(jobId j)(worldJobSites w)==Just ident)(M.elems(worldJobs w))->pure(w,CommandFailed(InvalidReference "site already has active job"),[])
              | otherwise->case runInventory(planJob(worldContent w)(siteRecipe site)(siteInput site)(siteOutput site)(siteNatural site))(worldInventory w) of
                Left err->worldFailure err
                Right(job,inv)->pure(w {worldInventory=inv,worldJobs=M.insert(jobId job)job(worldJobs w),worldJobSites=M.insert(jobId job)ident(worldJobSites w)},Applied(Just(jobId job)),[JobPlanned(EventId tx 0)(jobId job)])
  CancelProduction ident->case M.lookup ident(worldJobs w) of
    Nothing->pure(w,CommandFailed TargetGone,[])
    Just job->case worldM1 w of
      Just _->case cancelProductionSpatial tx w job of
        Left err->worldFailure err
        Right(changed,next)->pure(changed{worldJobs=M.insert ident next(worldJobs changed)},Applied(Just ident),[JobCancelled(EventId tx 0)ident])
      Nothing->case runInventory(cancelJob(worldRuleset w) tx job)(worldInventory w) of
        Left err->worldFailure err
        Right(next,inv)->pure(w {worldInventory=inv,worldJobs=M.insert ident next(worldJobs w)},Applied(Just ident),[JobCancelled(EventId tx 0)ident])
  SetSiteEnabled ident enabled->case M.lookup ident(worldSites w) of
    Nothing->pure(w,CommandFailed TargetGone,[])
    Just site->pure(w {worldSites=M.insert ident(site {siteEnabled=enabled})(worldSites w)},Applied(Just ident),[])
  RequestDelivery src dst resource quantity priority->case runInventory(either throwTx pure(validateM1Delivery w src dst resource quantity)>>planDelivery evaluation src dst resource quantity priority(worldTransport w))(worldInventory w)of
    Left err->worldFailure err
    Right((ident,transport),inv)->pure(w {worldInventory=inv,worldTransport=transport},Applied(Just ident),[])
  CancelDelivery ident->case runInventory(cancelDelivery evaluation ident(worldTransport w))(worldInventory w)of
    Left err->worldFailure err
    Right(transport,inv)->pure(w {worldInventory=inv,worldTransport=transport},Applied(Just ident),[])
  RequestMaintenance ident src dst->case runInventory(do
    either throwTx pure(validateMaintenanceOwners w ident src dst)
    planMaintenance(worldContent w)evaluation ident src dst(worldMaintenance w))(worldInventory w)of
    Left err->worldFailure err
    Right((job,state),inv)->pure(w {worldInventory=inv,worldMaintenance=state},Applied(Just job),[])
  CancelFacilityMaintenance ident->case runInventory(cancelMaintenance tx ident(worldMaintenance w))(worldInventory w)of
    Left err->worldFailure err
    Right(state,inv)->pure(w {worldInventory=inv,worldMaintenance=state},Applied(Just ident),[])
  PlaceConstructionPlan{}->newCommand
  CancelConstructionPlan{}->newCommand
  AssignWorkers{}->newCommand
  where
    newCommand=case executeM1Command evaluation tx w command of
      Left err->worldFailure err
      Right result->pure result
    worldFailure err=case err of
      InvariantViolation _->Left(P1,err)
      CounterOverflow->Left(P1,err)
      _->pure(w,CommandFailed err,[])

phaseExpiry :: SimTick -> Staged -> Checked Staged
phaseExpiry tick(w,out)=do
  let expiredWip=[ident|l<-M.elems(invLots(worldInventory w)),not(usable tick l),let Owner kind ident=lotOwner l,kind==MachineInput]
      tx=mkTx w P2 0
  ((affected,jobs,transport),inv)<-fatal P2$runInventory (do
    affected<-expireInventory tx tick
    jobs<-mapM (failExpiredJob tx) [j|j<-M.elems(worldJobs w),jobId j `elem` (affected++expiredWip),not(terminal j)]
    transport<-phaseTransportExpiry tick(worldTransport w)
    pure(affected,jobs,transport)) (worldInventory w)
  let nextJobs=foldr(\j->M.insert(jobId j)j)(worldJobs w)jobs
      events=[JobExpired(EventId tx n)(jobId j)|(n,j)<-zip[0..]jobs]
  affected `seq` pure(w {simTick=tick,worldInventory=inv,worldJobs=nextJobs,worldTransport=transport},out {outputEvents=outputEvents out++events})

phaseStart :: SimTick -> Staged -> Checked Staged
phaseStart tick initial=foldM start initial . zip[0..] . take (fromIntegral(256-worldMaintenanceAttempts(fst initial)-transportLastAssignments(worldTransport(fst initial)))) . filter(\j->not(terminal j)&&jobPhase j/=Running) . M.elems . worldJobs . fst $ initial
  where
    start(w,out)(ordinal,j)=case readySite w j of
      Left err->pure(w {worldJobs=M.insert(jobId j)(j {jobBlocked=Just err})(worldJobs w)},out)
      Right _->case runInventory(startJob(worldContent w)tick j)(worldInventory w) of
        Left err | fatalFailure err->Left(P5,err)
                 | otherwise->pure(w {worldJobs=M.insert(jobId j)(j {jobPhase=WaitingInputs,jobBlocked=Just err})(worldJobs w)},out)
        Right(next,inv)->pure(w {worldInventory=inv,worldJobs=M.insert(jobId j)next(worldJobs w)},out {outputEvents=outputEvents out++[JobStarted(EventId(mkTx w P5 ordinal)0)(jobId j)]})

-- Static staffing is a fixture input in this foundation; resident shifts are an open M1 feature.
readySite :: World -> Job -> Either Failure Site
readySite w j=do
  sid<-maybe(Left TargetGone)Right(M.lookup(jobId j)(worldJobSites w))
  site<-maybe(Left TargetGone)Right(M.lookup sid(worldSites w))
  recipe<-either(Left . InvalidReference)Right(lookupRecipe(worldContent w)(jobRecipe j))
  building<-either(Left . InvalidReference)Right(lookupBuilding(worldContent w)(recipeBuilding recipe))
  unless(not(facilityStopped(worldMaintenance w)(siteId site)))(Left(InvalidReference "UnderMaintenanceOrBroken"))
  unless(siteEnabled site)(Left(InvalidReference "SiteDisabled"))
  case worldM1 w of
    Nothing->unless(siteWorkers site>=buildingWorkers building)(Left(InvalidReference "NoWorker"))
    Just state|buildingWorkers building==0->pure()
              |otherwise->do
        catalog<-workTargetCatalog w
        let SimTick current=simTick w
            context=Workforce.TickContext(simTick w)(toInteger(current `mod` 28800 `div` 9600))
        crew<-either(Left . Workforce.workforceFailure)Right(Workforce.observeCrew context catalog(worldNeeds w)(m1Workforce state)(Workforce.OperateFacility sid))
        unless(Workforce.crewReady crew)(Left(InvalidReference "WaitingWorkers"))
  pure site

phaseWork :: SimTick -> Staged -> Checked Staged
phaseWork tick initial=foldM work initialWithOperating . zip[0..] . filter((==Running).jobPhase) . M.elems . worldJobs . fst $ initial
  where
    (starting,outputs)=initial
    operating=S.fromList[siteId site|job<-M.elems(worldJobs starting),jobPhase job==Running,Right site<-[readySite starting job],sitePowered starting site]
    initialWithOperating=(starting {worldOperatingFacilities=S.union operating(worldOperatingFacilities starting)},outputs)
    work(w,out)(ordinal,j)=case readySite w j of
      Left err->pure(w {worldJobs=M.insert(jobId j)(j {jobBlocked=Just err})(worldJobs w)},out)
      Right site | not(sitePowered w site)->pure(w {worldJobs=M.insert(jobId j)(j {jobBlocked=Just(InvalidReference "NoPower")})(worldJobs w)},out)
                 | otherwise->let credited=j {jobProgress=min(jobRequired j)(jobProgress j+siteMaintenancePct w site),jobBlocked=Nothing}
                              in if jobProgress credited<jobRequired credited
                                 then pure(w {worldJobs=M.insert(jobId j)credited(worldJobs w)},out)
                                 else do
                                   (completed,inv)<-fatal P7(runInventory(completeJob(worldContent w)(mkTx w P7 ordinal)tick credited)(worldInventory w))
                                   pure(w {worldInventory=inv,worldJobs=M.insert(jobId j)completed(worldJobs w)},out {outputEvents=outputEvents out++[JobCompleted(EventId(mkTx w P7 ordinal)0)(jobId j)]})
fatalFailure :: Failure -> Bool
fatalFailure(InvariantViolation _)=True
fatalFailure CounterOverflow=True
fatalFailure _=False

sitePowered :: World -> Site -> Bool
sitePowered w site=case lookupRecipe(worldContent w)(siteRecipe site) >>= lookupBuilding(worldContent w) . recipeBuilding of
  Right building->buildingPower building==0 || S.member(siteId site)(worldPoweredSites w)
  Left _->False

phasePower :: SimTick -> Staged -> Checked Staged
phasePower tick(w,out)=do
  let demands=[(sid,PowerDemand sid 2(buildingPower building))|j<-M.elems(worldJobs w),jobPhase j==Running,Right site<-[readySite w j],let sid=siteId site,Right recipe<-[lookupRecipe(worldContent w)(jobRecipe j)],Right building<-[lookupBuilding(worldContent w)(recipeBuilding recipe)]]
  (grids,inv,served,operated)<-foldM (step demands)(M.empty,worldInventory w,S.empty,S.empty)(zip[0..](M.toAscList(worldPowerGrids w)))
  pure(w {worldInventory=inv,worldPowerGrids=grids,worldPoweredSites=served,worldOperatingFacilities=operated},out)
  where
    step demands(grids,inv,served,operated)(ordinal,(ident,grid))=do
      let local=[d|(site,d)<-demands,M.lookup site(worldSiteGrids w)==Just ident]
      ((next,result),after)<-fatal P6(runInventory(stepPower(mkTx w P6 ordinal)tick(worldWeather w)local(applyMaintenancePower w grid))inv)
      pure(M.insert ident next grids,after,S.union served(poweredConsumers result),S.union operated(operatingPowerDevices result))

phaseNeeds :: SimTick -> Staged -> Checked Staged
phaseNeeds tick(w,out)=do
  ((next,_),inv)<-fatal P8(runInventory(stepNeeds(mkTx w P8 0)tick(worldNeeds w))(worldInventory w))
  let hadPopulation=any((/=Evacuated).residentStatus)(M.elems(needsResidents(worldNeeds w)))
      abandoned=hadPopulation && all((==Evacuated).residentStatus)(M.elems(needsResidents next))
  maintenance<-fatal P8(advanceFacilities True tick(worldWeather w)(worldOperatingFacilities w)(worldMaintenance w))
  pure(w {worldInventory=inv,worldNeeds=next,worldMode=if abandoned then Abandoned else worldMode w,worldMaintenance=maintenance,worldOperatingFacilities=S.empty},out)

phasePaths :: SimTick -> Staged -> Checked Staged
phasePaths tick(w,out)=do
  next<-fatal P3(phaseTransportPaths tick(worldTransport w))
  pure(w {worldTransport=next},out)

phaseTransport :: Phase -> SimTick -> Word64 -> Staged -> Checked Staged
phaseTransport phase tick ordinal(w,out)=do
  let action=case phase of
        P4->phaseTransportArrival tick
        P5->phaseTransportAssignBudget(256-worldMaintenanceAttempts w)tick
        P7->phaseTransportEnter(mkTx w P7 ordinal)tick
        _->pure
  (next,inv)<-fatal phase(runInventory(action(worldTransport w))(worldInventory w))
  pure(w {worldTransport=next,worldInventory=inv},out)

siteMaintenancePct :: World -> Site -> Integer
siteMaintenancePct w site=maybe 100 maintenancePct(M.lookup(siteId site)(maintenanceFacilities(worldMaintenance w)))

applyMaintenancePower :: World -> PowerGrid -> PowerGrid
applyMaintenancePower w grid=grid
  {gridSolar=[panel {solarMaintenancePct=percent(solarId panel)(solarMaintenancePct panel)}|panel<-gridSolar grid]
  ,gridGenerators=[generator {generatorMaintenancePct=percent(generatorId generator)(generatorMaintenancePct generator)}|generator<-gridGenerators grid]
  ,gridBatteries=[battery {batteryMaintenancePct=percent(batteryId battery)(batteryMaintenancePct battery)}|battery<-gridBatteries grid]}
  where percent ident fallback=if facilityStopped(worldMaintenance w)ident then 0 else maybe fallback maintenancePct(M.lookup ident(maintenanceFacilities(worldMaintenance w)))

phaseMaintenanceStart :: Staged -> Checked Staged
phaseMaintenanceStart(w,out)=foldM start(w {worldMaintenanceAttempts=0},out)(take 256[job|job<-M.elems(maintenanceJobs(worldMaintenance w)),maintenancePhase job==MaintenancePlanned]) where
  start(current,outputs)job=do
    let crew=M.findWithDefault 0(maintenanceTarget job)(worldMaintenanceCrews current)
        attempted=current {worldMaintenanceAttempts=worldMaintenanceAttempts current+1}
    case runInventory(startMaintenance(maintenanceJobId job)crew(worldMaintenance attempted))(worldInventory attempted)of
      Left failure | fatalFailure failure->Left(P5,failure)
                   | otherwise->let state=worldMaintenance attempted in pure(attempted {worldMaintenance=state {maintenanceJobs=M.adjust(\j->j {maintenanceBlocked=Just failure})(maintenanceJobId job)(maintenanceJobs state)}},outputs)
      Right(state,inv)->pure(attempted {worldInventory=inv,worldMaintenance=state},outputs)

phaseMaintenanceWork :: Word64 -> Staged -> Checked (Staged,Word64)
phaseMaintenanceWork first initial=do
  let jobs=[job|job<-M.elems(maintenanceJobs(worldMaintenance(fst initial))),maintenancePhase job==MaintenanceRunning]
  result<-foldM work initial(zip[first..]jobs)
  pure(result,fromIntegral(length jobs))
  where
    work(w,out)(ordinal,job)=do
      let crew=M.findWithDefault 0(maintenanceTarget job)(worldMaintenanceCrews w)
      (state,inv)<-fatal P7(runInventory(workMaintenance(mkTx w P7 ordinal)(maintenanceJobId job)crew 100(worldMaintenance w))(worldInventory w))
      pure(w {worldInventory=inv,worldMaintenance=state},out)
