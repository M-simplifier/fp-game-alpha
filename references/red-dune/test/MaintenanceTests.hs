module MaintenanceTests (maintenanceTests) where

import Colony.Content
import Colony.Inventory
import Colony.Maintenance
import Colony.Power
import Colony.Types
import Colony.Units
import Control.Monad (foldM, forM_, unless)
import qualified Data.Map.Strict as M
import qualified Data.Set as S

assert :: String -> Bool -> IO ()
assert label condition = unless condition (ioError (userError ("Maintenance: " ++ label)))
right :: Show e => String -> Either e a -> IO a
right label = either (ioError . userError . ((label ++ ": ") ++) . show) pure
invariant :: Either Failure a -> Bool
invariant (Left (InvariantViolation _)) = True
invariant _ = False

tx :: TxId
tx = TxId 1 1 (BoundarySeq 1) P7 0

-- Every primary/storage/colony ID in these fixtures goes through freshId.
fixture :: Content -> String -> [Integer] -> Integer -> Integer -> IO (MaintenanceState,EntityId,Owner,Owner,Inventory)
fixture content building quantities sourceCapacity returnCapacity = do
  ((state,target,source,destination),inventory) <- right "fixture" $ runInventory (do
    colony <- freshId
    target <- freshId
    sourceId <- freshId
    returnId <- freshId
    let source = Owner Warehouse sourceId; destination = Owner MachineOutput returnId
    addStorage source (Storage sourceCapacity Nothing colony)
    addStorage destination (Storage returnCapacity Nothing colony)
    forM_ (zip [1..] quantities) $ \(n,quantity) -> do
      _ <- mintLot tx InitialGrant Nothing Parts quantity source (SimTick n) Nothing ("parts-lot-" ++ show n)
      pure ()
    facility <- either throwTx pure (newFacility content target building)
    pure (emptyMaintenance {maintenanceFacilities=M.singleton target facility},target,source,destination)) (emptyInventory content)
  pure (state,target,source,destination,inventory)

jobAt :: EntityId -> MaintenanceState -> MaintenanceJob
jobAt ident state = maintenanceJobs state M.! ident
facilityAt :: EntityId -> MaintenanceState -> Facility
facilityAt ident state = maintenanceFacilities state M.! ident
stock :: Owner -> Resource -> Inventory -> Integer
stock owner resource inventory = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inventory),lotOwner lot == owner,lotResource lot == resource]
mutateFacility :: EntityId -> (Facility -> Facility) -> MaintenanceState -> MaintenanceState
mutateFacility ident change state = state {maintenanceFacilities=M.adjust change ident (maintenanceFacilities state)}

runWork :: EntityId -> Integer -> (MaintenanceState,Inventory) -> IO (MaintenanceState,Inventory)
runWork ident count initial = foldM (\(state,inventory) _ -> right "work" (runInventory (workMaintenance tx ident 1 100 state) inventory)) initial [1..count]

maintenanceTests :: Content -> IO ()
maintenanceTests content = do
  ageAndWeather content
  lifecycle content
  repairAndPromotion content
  cancellation content
  corruption content
  putStrLn "MaintenanceTests PASS: operating-age and weather thresholds; reserved-to-physical-WIP 600/1200-tick lifecycle; crew/work-credit bounds; shortage, promotion, proportional physical cancellation, atomic capacity failure, exact-WIP and terminal invariants"

ageAndWeather :: Content -> IO ()
ageAndWeather content = do
  forM_ (M.elems (contentBuildings content)) $ \building -> do
    facility <- right "new facility" (newFacility content (EntityId 99) (buildingId building))
    let period = facilityPeriod facility
    assert "new condition and age" (facilityCondition facility == 1000 && facilityAge facility == 0 && maintenancePct facility == 100)
    if period == 0 then do
      state <- right "exempt facility" (advanceFacilities True (SimTick 1) Clear (S.singleton (EntityId 99)) (emptyMaintenance {maintenanceFacilities=M.singleton (EntityId 99) facility}))
      assert "exempt never ages" (facilityAge (facilityAt (EntityId 99) state) == 0)
      else forM_ [(period*4 `div` 5-1,Operational,100),(period*4 `div` 5,MaintenanceWarning,100),(period-1,MaintenanceWarning,100),(period,MaintenanceDue,70),(period*3 `div` 2-1,MaintenanceDue,70),(period*3 `div` 2,FacilityBroken,0)] $ \(age,status,pct) ->
        assert ("age boundary " ++ show (buildingId building,age)) (maintenanceStatus facility {facilityAge=age} == status && maintenancePct facility {facilityAge=age} == pct)
  facility <- right "odd period" (newFacility content (EntityId 99) "pump")
  let ident = facilityId facility
      oddFacility = facility {facilityPeriod=7}
      state = emptyMaintenance {maintenanceFacilities=M.singleton ident facility}
  assert "integer threshold avoids early rounding" (maintenanceStatus oddFacility {facilityAge=5} == Operational && maintenanceStatus oddFacility {facilityAge=6} == MaintenanceWarning && maintenanceStatus oddFacility {facilityAge=10} == MaintenanceDue && maintenanceStatus oddFacility {facilityAge=11} == FacilityBroken)
  active <- right "operating tick" (advanceFacilities True (SimTick 1) Clear (S.singleton ident) state)
  stopped <- right "non-operating tick" (advanceFacilities True (SimTick 2) Clear S.empty active)
  paused <- right "paused at weather boundary" (advanceFacilities False (SimTick 1200) Sandstorm (S.singleton ident) stopped)
  assert "only operating ages; paused damage inert" (facilityAge (facilityAt ident active) == 1 && active == stopped && stopped == paused)
  let nearBroken = mutateFacility ident (\f -> f {facilityAge=facilityPeriod f*3 `div` 2-1}) state
  broken <- right "age enters broken" (advanceFacilities True (SimTick 1) Clear (S.singleton ident) nearBroken)
  stoppedBroken <- right "broken cannot age" (advanceFacilities True (SimTick 2) Clear (S.singleton ident) broken)
  assert "operating reaches 150% then stops" (facilityStopped broken ident && stoppedBroken == broken)
  forM_ ["solar","pump","brine_pump","mine","quarry","generator","battery","greenhouse","workshop","garage"] $ \name -> do
    f <- right "weather facility" (newFacility content ident name)
    let weatherState = emptyMaintenance {maintenanceFacilities=M.singleton ident f}
        exposed = name `elem` ["solar","pump","brine_pump","mine","quarry","generator"]
    early <- right "before weather hour" (advanceFacilities True (SimTick 1199) Sandstorm S.empty weatherState)
    zero <- right "no hour at tick zero" (advanceFacilities True (SimTick 0) Sandstorm S.empty weatherState)
    clear <- right "clear weather hour" (advanceFacilities True (SimTick 1200) Clear S.empty weatherState)
    haze <- right "haze weather hour" (advanceFacilities True (SimTick 1200) Haze S.empty weatherState)
    hour <- right "sandstorm hour" (advanceFacilities True (SimTick 1200) Sandstorm S.empty weatherState)
    assert "eligible damage only, even while stopped" (early == weatherState && zero == weatherState && clear == weatherState && haze == weatherState && facilityAge (facilityAt ident hour) == 0 && facilityCondition (facilityAt ident hour) == if exposed then 980 else 1000)
    final <- foldM (\s tick -> right "weather trace" (advanceFacilities True (SimTick tick) Sandstorm S.empty s)) weatherState [1200,2400..61200]
    assert "condition reaches zero without underflow" (facilityCondition (facilityAt ident final) == if exposed then 0 else 1000)
  assert "vehicles are not facility content" (case newFacility content ident "vehicle" of Left (InvalidReference _) -> True; _ -> False)

lifecycle :: Content -> IO ()
lifecycle content = do
  (state,target,source,destination,inventory) <- fixture content "pump" [1,1,2,8] 2000000 400000
  ((ident,planned),reserved) <- right "plan" (runInventory (planMaintenance content (SimTick 0) target source destination state) inventory)
  let plannedJob = jobAt ident planned
  assert "planned exact content parts and 600 ticks" (maintenanceParts plannedJob == 4 && maintenanceRequired plannedJob == 60000 && maintenancePhase plannedJob == MaintenancePlanned && stock source Parts reserved == 12 && stock (maintenanceWipOwner plannedJob) Parts reserved == 0 && length (M.elems (invQuantity reserved)) == 3)
  assert "planned target can still operate" (not (facilityStopped planned target))
  assert "one outstanding maintenance per facility" (case runInventory (planMaintenance content (SimTick 0) target source destination planned) reserved of Left (InvalidReference _) -> True; _ -> False)
  (uncrewed,sameReserved) <- right "no worker at start" (runInventory (startMaintenance ident 0 planned) reserved)
  assert "no worker preserves reservations/phase" (maintenanceBlocked (jobAt ident uncrewed) == Just (InvalidReference "NoWorker") && sameReserved == reserved && maintenancePhase (jobAt ident uncrewed) == MaintenancePlanned)
  (running,wipInventory) <- right "start" (runInventory (startMaintenance ident 1 uncrewed) sameReserved)
  let runningJob = jobAt ident running
  assert "start is actual WIP, not consumption" (stock source Parts wipInventory == 8 && stock (maintenanceWipOwner runningJob) Parts wipInventory == 4 && M.null (invQuantity wipInventory) && invLedger wipInventory == invLedger inventory && facilityStopped running target)
  aged <- right "running maintenance excludes age" (advanceFacilities True (SimTick 15) Clear (S.singleton target) running)
  assert "maintenance excludes operated-set error" (aged == running)
  (withoutCrew,unchanged) <- right "crew missing during maintenance" (runInventory (workMaintenance tx ident 0 100 running) wipInventory)
  assert "no worker does not progress" (maintenanceProgress (jobAt ident withoutCrew) == 0 && unchanged == wipInventory && maintenanceBlocked (jobAt ident withoutCrew) == Just (InvalidReference "NoWorker"))
  forM_ [-1,131,quantityMax] $ \credit -> assert "bounded tick work credit" (runInventory (workMaintenance tx ident 1 credit running) wipInventory == Left InvalidQuantity)
  (extraCrew,_) <- right "crew is one slot" (runInventory (workMaintenance tx ident 8 130 running) wipInventory)
  assert "extra crew does not multiply bounded credit" (maintenanceProgress (jobAt ident extraCrew) == 130)
  (zeroCredit,_) <- right "zero credit" (runInventory (workMaintenance tx ident 1 0 running) wipInventory)
  assert "zero credit is inert" (zeroCredit == running)
  let damaged = mutateFacility target (\f -> f {facilityAge=123,facilityCondition=777}) running
  (almost,almostInventory) <- runWork ident 599 (damaged,wipInventory)
  assert "599 ticks does not finish" (maintenancePhase (jobAt ident almost) == MaintenanceRunning && stock (maintenanceWipOwner runningJob) Parts almostInventory == 4)
  (complete,after) <- runWork ident 1 (almost,almostInventory)
  assert "600 completes atomically with exact sink" (maintenancePhase (jobAt ident complete) == MaintenanceCompleted && maintenanceTerminalCount (jobAt ident complete) == 1 && stock (maintenanceWipOwner runningJob) Parts after == 0 && M.lookup (Parts,RecipeInput) (invLedger after) == Just 4 && facilityAge (facilityAt target complete) == 0 && facilityCondition (facilityAt target complete) == 1000 && not (facilityStopped complete target))
  let completedEntries = [entry | entry <- invRecentLedger after,ledgerJob entry == Just ident,ledgerReason entry == RecipeInput]
  assert "maintenance golden ledger entry only at completion" (M.notMember (Parts,RecipeInput) (invLedger almostInventory) && map (\entry -> (ledgerResource entry,ledgerSubreason entry,ledgerQuantity entry,ledgerFrom entry,ledgerTo entry)) completedEntries == [(Parts,Just Maintenance,4,Just (maintenanceWipOwner runningJob),Nothing)] && M.notMember (Parts,ConstructionConsumed) (invLedger after))
  assert "late work never repeats terminal" (runInventory (workMaintenance tx ident 1 100 complete) after == Left AlreadyTerminal)
  assert "late cancel never resurrects" (runInventory (cancelMaintenance tx ident complete) after == Left AlreadyTerminal)
  (_,afterExpiry) <- right "parts expiry irrelevant" (runInventory (expireInventory tx (SimTick 1000000000)) wipInventory)
  assert "parts reservations/WIP have no expiry" (afterExpiry == wipInventory)
  (scarce,t,src,dst,small) <- fixture content "pump" [3] 2000000 400000
  assert "missing parts planning fails atomically" (runInventory (planMaintenance content (SimTick 0) t src dst scarce) small == Left MissingStock && M.null (invQuantity small))
  (exempt,te,se,de,ie) <- fixture content "tank" [4] 2000000 400000
  assert "exempt facility cannot enter maintenance" (case runInventory (planMaintenance content (SimTick 0) te se de exempt) ie of Left (InvalidReference "MaintenanceNotRequired") -> True; _ -> False)

repairAndPromotion :: Content -> IO ()
repairAndPromotion content = do
  (state,target,source,destination,inventory) <- fixture content "pump" [8] 2000000 400000
  let broken = mutateFacility target (\f -> f {facilityCondition=0}) state
  ((ident,planned),reserved) <- right "repair plan" (runInventory (planMaintenance content (SimTick 0) target source destination broken) inventory)
  assert "repair doubles parts and work" (maintenanceKind (jobAt ident planned) == BrokenRepair && maintenanceParts (jobAt ident planned) == 8 && maintenanceRequired (jobAt ident planned) == 120000)
  (running,wipInventory) <- right "repair start" (runInventory (startMaintenance ident 1 planned) reserved)
  (half,halfInv) <- runWork ident 600 (running,wipInventory)
  assert "repair still running at 600 ticks" (maintenancePhase (jobAt ident half) == MaintenanceRunning && maintenanceProgress (jobAt ident half) == 60000)
  (complete,after) <- runWork ident 600 (half,halfInv)
  assert "broken target can be repaired at 1200 ticks" (maintenancePhase (jobAt ident complete) == MaintenanceCompleted && facilityCondition (facilityAt target complete) == 1000 && M.lookup (Parts,RecipeInput) (invLedger after) == Just 8)
  let repairEntries = [entry | entry <- invRecentLedger after,ledgerJob entry == Just ident,ledgerReason entry == RecipeInput]
  assert "repair golden ledger entry only at completion" (M.notMember (Parts,RecipeInput) (invLedger halfInv) && map (\entry -> (ledgerResource entry,ledgerSubreason entry,ledgerQuantity entry,ledgerFrom entry,ledgerTo entry)) repairEntries == [(Parts,Just Repair,8,Just (maintenanceWipOwner (jobAt ident running)),Nothing)] && M.notMember (Parts,ConstructionConsumed) (invLedger after))
  ((normalId,normalPlan),normalInv) <- right "normal planned before break" (runInventory (planMaintenance content (SimTick 0) target source destination state) inventory)
  let nowBroken = mutateFacility target (\f -> f {facilityCondition=0}) normalPlan
  (promoted,promotedInv) <- right "promote preventive to repair" (runInventory (startMaintenance normalId 1 nowBroken) normalInv)
  assert "late break cannot obtain cheap repair" (maintenanceParts (jobAt normalId promoted) == 8 && maintenanceRequired (jobAt normalId promoted) == 120000 && stock (maintenanceWipOwner (jobAt normalId promoted)) Parts promotedInv == 8)
  (few,t,src,dst,fewInv) <- fixture content "pump" [4] 2000000 400000
  ((fewId,fewPlanned),fewReserved) <- right "scarce normal plan" (runInventory (planMaintenance content (SimTick 0) t src dst few) fewInv)
  let fewBroken = mutateFacility t (\f -> f {facilityCondition=0}) fewPlanned
  assert "promotion shortage retains original reservation" (runInventory (startMaintenance fewId 1 fewBroken) fewReserved == Left MissingStock && sum (map (qtyValue . quantityAmount) (M.elems (invQuantity fewReserved))) == 4)
  let normal = facilityAt target state
      due = normal {facilityAge=facilityPeriod normal}
      solar = Solar target (maintenancePct due)
      battery = Battery target 0 0 (maintenancePct due)
  assert "maintenance separate power output/limit semantics" (maintenancePct due == 70 && solarEnergy (SimTick 12000) Clear solar == 84000 && chargeInputRoom battery == 42000 && batteryCapacityJ == 720000000)
  (_,fuelInventory) <- right "due generator fuel" (runInventory (mintLot tx InitialGrant Nothing Fuel 20 source (SimTick 0) Nothing "generator-test") inventory)
  let generator = Generator target source True (maintenancePct due)
      grid = PowerGrid (EntityId 998) [] [generator] [] M.empty
  ((_,power),fuelAfter) <- right "due generator supply" (runInventory (stepPower tx (SimTick 0) Clear [PowerDemand (EntityId 999) 0 28000] grid) fuelInventory)
  assert "due generator lowers generation, never fuel batch" (generatedJ power == 84000 && servedJ power == 84000 && M.lookup (Fuel,FuelBurned) (invLedger fuelAfter) == Just 20)
  ((_,unpowered),_) <- right "unmet full demand remains unpowered" (runInventory (stepPower tx (SimTick 0) Clear [PowerDemand (EntityId 999) 0 40000] grid) fuelInventory)
  assert "power demand not scaled with maintenance work credit" (S.null (poweredConsumers unpowered) && generatedJ unpowered == 84000 && servedJ unpowered == 0)

cancellation :: Content -> IO ()
cancellation content = do
  (state,target,source,destination,inventory) <- fixture content "pump" [1,1,2] 2000000 400000
  ((ident,planned),reserved) <- right "cancel fixture plan" (runInventory (planMaintenance content (SimTick 0) target source destination state) inventory)
  (plannedCancelled,plannedAfter) <- right "planned cancel" (runInventory (cancelMaintenance tx ident planned) reserved)
  assert "planned cancel releases rights, consumes nothing" (M.null (invQuantity plannedAfter) && invLots plannedAfter == invLots inventory && invLedger plannedAfter == invLedger inventory && maintenanceTerminalCount (jobAt ident plannedCancelled) == 1)
  (running,wipInventory) <- right "cancel fixture start" (runInventory (startMaintenance ident 1 planned) reserved)
  forM_ [0,1,14999,15000,29999,30000,45000,59999,60000] $ \progress -> do
    let partial = putMaintenance (jobAt ident running) {maintenanceProgress=progress} running
        expectedLoss = 4*progress `div` 60000
    (cancelled,after) <- right "partial cancel" (runInventory (cancelMaintenance tx ident partial) wipInventory)
    assert ("single resource floor across split lots " ++ show progress) (stock destination Parts after == 4-expectedLoss && M.findWithDefault 0 (Parts,CancelledProcessLoss) (invLedger after) == expectedLoss && stock (maintenanceWipOwner (jobAt ident running)) Parts after == 0 && maintenancePhase (jobAt ident cancelled) == MaintenanceCancelled)
    assert "cancel only uses cancellation sink, never maintenance/repair completion" (M.notMember (Parts,RecipeInput) (invLedger after) && all ((==Nothing) . ledgerSubreason) [entry | entry <- invRecentLedger after,ledgerJob entry == Just ident,ledgerReason entry == CancelledProcessLoss])
    assert "returned parts preserve metadata" (all (\lot -> lotResource lot == Parts && lotExpires lot == Nothing && lotBorn lot `elem` [SimTick 1,SimTick 2,SimTick 3] && lotProvenance lot `elem` ["parts-lot-1","parts-lot-2","parts-lot-3"]) (M.elems (invLots after)))
    assert "terminal cancellation unique" (runInventory (cancelMaintenance tx ident cancelled) after == Left AlreadyTerminal)
  let partWeight = resourceLoad (contentResources content M.! Parts)
  (splitState,splitTarget,splitSource,splitDestination,splitInventory) <- fixture content "pump" [4] (4*partWeight) partWeight
  ((splitId,splitPlanned),splitReserved) <- right "split return plan" (runInventory (planMaintenance content (SimTick 0) splitTarget splitSource splitDestination splitState) splitInventory)
  (splitRunning,splitWip) <- right "split return start" (runInventory (startMaintenance splitId 1 splitPlanned) splitReserved)
  (_,splitReturned) <- right "return split across owners" (runInventory (cancelMaintenance tx splitId splitRunning) splitWip)
  assert "return can use partial preferred room and same-colony warehouse" (stock splitDestination Parts splitReturned == 1 && stock splitSource Parts splitReturned == 3 && M.notMember (Parts,CancelledProcessLoss) (invLedger splitReturned))
  (small,t,src,dst,smallInv) <- fixture content "pump" [4] (4*partWeight) 0
  ((smallId,smallPlan),smallReserved) <- right "no return plan" (runInventory (planMaintenance content (SimTick 0) t src dst small) smallInv)
  (smallRunning,smallWip) <- right "no return start" (runInventory (startMaintenance smallId 1 smallPlan) smallReserved)
  (_,filled) <- right "fill freed source" (runInventory (mintLot tx InitialGrant Nothing Metal (4*partWeight) src (SimTick 0) Nothing "block-return") smallWip)
  let half = putMaintenance (jobAt smallId smallRunning) {maintenanceProgress=30000} smallRunning
  assert "no return capacity fails entire loss+return atomically" (runInventory (cancelMaintenance tx smallId half) filled == Left ReturnCapacityFull && M.notMember (Parts,CancelledProcessLoss) (invLedger filled) && stock (maintenanceWipOwner (jobAt smallId half)) Parts filled == 4)
  (_,room) <- right "make return room" (runInventory (consumeFree tx ConstructionConsumed Nothing (SimTick 0) src Metal (2*partWeight)) filled)
  (cancelled,returned) <- right "retry after room" (runInventory (cancelMaintenance tx smallId half) room)
  assert "retry returns exactly survivors" (stock src Parts returned == 2 && M.lookup (Parts,CancelledProcessLoss) (invLedger returned) == Just 2 && maintenanceTerminalCount (jobAt smallId cancelled) == 1)

corruption :: Content -> IO ()
corruption content = do
  (state,target,source,destination,inventory) <- fixture content "pump" [4] 2000000 400000
  ((ident,planned),reserved) <- right "corruption plan" (runInventory (planMaintenance content (SimTick 0) target source destination state) inventory)
  (running,wipInventory) <- right "corruption start" (runInventory (startMaintenance ident 1 planned) reserved)
  (_,shortWip) <- right "remove physical part with ledger sink" (runInventory (consumeFree tx ConstructionConsumed (Just ident) (SimTick 0) (maintenanceWipOwner (jobAt ident running)) Parts 1) wipInventory)
  assert "exact WIP rejects understated physical parts" (invariant (validateMaintenance running shortWip) && invariant (runInventory (cancelMaintenance tx ident running) shortWip))
  let invalidCount = putMaintenance (jobAt ident running) {maintenanceTerminalCount=1} running
      invalidProgress = putMaintenance (jobAt ident running) {maintenanceProgress=60001} running
      invalidCondition = mutateFacility target (\f -> f {facilityCondition=1001}) running
      invalidAge = mutateFacility target (\f -> f {facilityAge=(-1)}) running
  forM_ [invalidCount,invalidProgress,invalidCondition,invalidAge] $ \bad -> assert "saved state bounds checked" (invariant (validateMaintenance bad wipInventory))
  let missingReservation = reserved {invQuantity=M.empty}
  assert "planned reservation must equal snapshot" (invariant (validateMaintenance planned missingReservation))
