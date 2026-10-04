module MaintenanceIntegrationTests(maintenanceIntegrationTests) where
import Colony.Content
import Colony.Fixture
import Colony.Inventory
import Colony.Jobs
import Colony.Maintenance
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(unless,foldM)
import qualified Data.Map.Strict as M

maintenanceIntegrationTests :: Content -> IO()
maintenanceIntegrationTests content=do
  original<-right(fourColonyFixture content)
  let site=head[s|s<-M.elems(worldSites original),siteRecipe s=="cook"]
      sid=siteId site
      src=siteInput site
  facility<-right(newFacility content sid "kitchen")
  building<-either fail pure(lookupBuilding content "kitchen")
  let parts=buildingMaintenanceParts building
      tx=TxId 1 1(BoundarySeq 0)P0 0
  (_,stock)<-right(runInventory(mintLot tx InitialGrant Nothing Parts parts src(SimTick 0)Nothing"maintenance integration") (worldInventory original))
  let initial=original {worldInventory=stock,worldMaintenance=MaintenanceState(M.singleton sid(facility {facilityAge=facilityPeriod facility}))M.empty,worldMaintenanceCrews=M.singleton sid 1}
  right(validateWorld initial)
  (started,_)<-advance True[OrderProduction sid,RequestMaintenance sid src src][]initial
  let maintenance=head(M.elems(maintenanceJobs(worldMaintenance started)))
      production=head(M.elems(worldJobs started))
  assert "P5 maintenance starts before production demand"(maintenancePhase maintenance==MaintenanceRunning&&maintenanceProgress maintenance==100&&jobProgress production==0&&jobBlocked production==Just(InvalidReference "UnderMaintenanceOrBroken"))
  at100<-iterateSteps 99 started
  (paused,_)<-advance False[][PauseWorld]at100
  held<-foldM(\w _->fst <$> advance False[][]w)paused[1..100::Integer]
  assert "paused native boundaries preserve maintenance and energy"(worldMaintenance held==worldMaintenance paused&&worldInventory held==worldInventory paused&&simTick held==simTick paused)
  (resumed,_)<-advance False[][ResumeWorld]held
  done<-iterateSteps 500 resumed
  let finalMaintenance=head(M.elems(maintenanceJobs(worldMaintenance done)))
      finalFacility=maintenanceFacilities(worldMaintenance done)M.!sid
  assert "600th actual work tick completes maintenance once"(simTick done==SimTick 600&&maintenancePhase finalMaintenance==MaintenanceCompleted&&maintenanceTerminalCount finalMaintenance==1&&facilityAge finalFacility==0&&facilityCondition finalFacility==1000)
  assert "stopped site consumes no generator fuel"(M.findWithDefault 0(Fuel,FuelBurned)(invLedger(worldInventory done))==0)
  let partsEntries=[e|e<-invRecentLedger(worldInventory done),ledgerResource e==Parts,ledgerReason e==RecipeInput]
  assert "maintenance completion emits exact normative subreason"(length partsEntries==1&&all(\e->ledgerQuantity e==parts&&ledgerSubreason e==Just Maintenance)partsEntries)
  (working,_)<-advance True[][]done
  let running=head(M.elems(worldJobs working))
  assert "next P5/P6/P7 starts normal-power production"(jobPhase running==Running&&jobProgress running==100&&M.lookup(Fuel,FuelBurned)(invLedger(worldInventory working))==Just 20&&facilityAge(maintenanceFacilities(worldMaintenance working)M.!sid)==1)
  -- Same-tick cancellation beats the 600th automatic maintenance completion.
  at599<-iterateSteps 598 started
  let mid=maintenanceJobId(head(M.elems(maintenanceJobs(worldMaintenance at599))))
  (cancelled,_)<-advance True[CancelFacilityMaintenance mid][]at599
  assert "P1 cancel wins before P7 maintenance completion"(maintenancePhase(maintenanceJobs(worldMaintenance cancelled)M.!mid)==MaintenanceCancelled&&M.findWithDefault 0(Parts,RecipeInput)(invLedger(worldInventory cancelled))==0)
  putStrLn "MaintenanceIntegrationTests PASS: actual P1/P5/P6/P7/P8 gating, paused boundaries, exact600tick completion/subreason, resumed generation and cancel-before-complete"
  where
    assert label condition=unless condition(ioError(userError label))
    right :: Show e => Either e a -> IO a
    right=either(ioError.userError.show)pure
    advance active bodies management world=do
      let epoch=participantEpoch(worldParticipants world M.!1)
          next=M.findWithDefault 0(1,epoch)(worldHighWater world)+1
          commands=[OrderedCommand ordinal(CommandId(worldId world)1 epoch(next+ordinal))body|(ordinal,body)<-zip[0..]bodies]
          input=Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)active(worldAuthority world)(worldRuleset world))commands management
          result@(_,out)=pureStep input world
      assert("native maintenance diagnostics "++show(outputDiagnostics out))(null(outputDiagnostics out))
      pure result
    iterateSteps count world=foldM(\w _->fst <$> advance True[][]w)world[1..count::Integer]
