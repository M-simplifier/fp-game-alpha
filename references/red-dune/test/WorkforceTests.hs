module WorkforceTests (workforceTests) where

import Colony.Needs
import Colony.Types
import Colony.Workforce
import Control.Monad (foldM, forM_, unless)
import qualified Data.Map.Strict as M
import Data.Word (Word64)

assert :: String -> Bool -> IO ()
assert label condition = unless condition (ioError (userError label))
right :: Show e => String -> Either e a -> IO a
right label = either (\err -> ioError (userError (label++": "++show err))) pure
left :: Show a => String -> Either e a -> IO ()
left label result = case result of Left _ -> pure (); Right value -> ioError (userError (label++": unexpected success "++show value))

colony :: EntityId
colony=EntityId 500
farm, construction, maintenance, vehicle, service :: WorkTarget
farm=OperateFacility (EntityId 1)
construction=ConstructSite (EntityId 1)
maintenance=MaintainJob (EntityId 1)
vehicle=DriveVehicle (EntityId 1)
service=OperateFacility (EntityId 2)

catalog :: TargetCatalog
catalog=M.fromList
  [(farm,TargetRequirement colony 4 OperatorRole (Just ProcessSkill) False)
  ,(construction,TargetRequirement colony 2 BuilderRole (Just BuildSkill) False)
  ,(maintenance,TargetRequirement colony 1 MaintainerRole (Just MaintainSkill) False)
  ,(vehicle,TargetRequirement colony 1 DriverRole (Just TransportSkill) False)
  ,(service,TargetRequirement colony 1 ServiceRole Nothing False)]

fixture :: Integer -> SimTick -> (NeedsState,WorkforceState)
fixture number tick = (ns,initialWorkforce tick ns)
  where
    ns=NeedsState (M.fromList [(residentId r,r)|n<-[1..number],let ident=EntityId (fromInteger (100+n)),let r=(newResident ident colony) {residentShift=0}]) M.empty

ids :: [Integer] -> [EntityId]
ids=map (EntityId . fromInteger . (+100))

context :: Word64 -> TickContext
context tick=TickContext (SimTick tick) (toInteger ((tick `mod` 28800) `div` 9600))

changeResident :: EntityId -> (Resident -> Resident) -> NeedsState -> NeedsState
changeResident ident f ns=ns {needsResidents=M.adjust f ident (needsResidents ns)}
changeWorker :: EntityId -> (WorkerAdjunct -> WorkerAdjunct) -> WorkforceState -> WorkforceState
changeWorker ident f wf=wf {workforceWorkers=M.adjust f ident (workforceWorkers wf)}
getResident :: NeedsState -> EntityId -> Resident
getResident ns ident=needsResidents ns M.! ident
getWorker :: WorkforceState -> EntityId -> WorkerAdjunct
getWorker wf ident=workforceWorkers wf M.! ident

workforceTests :: IO ()
workforceTests=do
  assignmentTests
  coefficientGoldens
  forcedRestTests
  experienceTests
  evidenceTests
  speedTests
  putStrLn "WorkforceTests PASS: 128 independent Integer coefficient vectors; typed/atomic assignments; exact named crews; partial held duty; force-rest/expiry/overflow; phase capture after terminal release; XP and deterministic elapsed-tick replay"
  putStrLn "Scope: pure Workforce module tests only; World/Arena/UI integration remains a separate gate. Existing 139,968-observation independent model is separate evidence, not a real-kernel pass."

assignmentTests :: IO ()
assignmentTests=do
  let (ns,base)=fixture 8 (SimTick 0)
      one=EntityId 101;two=EntityId 102;three=EntityId 103;four=EntityId 104
      five=EntityId 105;six=EntityId 106;seven=EntityId 107;eight=EntityId 108
  assigned<-right "assign actual farm residents" (assignWorkers catalog ns farm 0 [four,two,one,three] base)
  assert "canonical sorted roster and unchanged Needs shifts" (M.lookup (farm,0) (workforceRosters assigned)==Just [one,two,three,four] && all ((==0).residentShift) (M.elems (needsResidents ns)))
  (claimed,view)<-right "claim actual four-person crew" (claimCrew (context 1) catalog ns assigned farm)
  assert "all named residents claimed" (crewReady view && crewSelected view==[one,two,three,four] && M.size (workforceClaims claimed)==4)
  left "duplicates reject" (assignWorkers catalog ns farm 0 [one,one] claimed)
  left "unknown resident rejects" (assignWorkers catalog ns farm 0 [EntityId 999999] claimed)
  left "wrong shift rejects" (assignWorkers catalog ns farm 1 [one] claimed)
  let elsewhere=changeResident five (\r->r {residentColony=EntityId 501}) ns
  left "wrong colony rejects" (assignWorkers catalog elsewhere farm 0 [five] claimed)
  forM_ [construction,maintenance,vehicle] $ \target -> do
    left "cross-kind assignment cannot steal farm resident" (assignWorkers catalog ns target 0 [one] claimed)
    assert "failed candidate leaves original roster and claims" (M.lookup (farm,0) (workforceRosters claimed)==Just [one,two,three,four] && M.lookup one (workforceClaims claimed)==Just farm)
  swapped<-right "whole roster replacement" (assignWorkers catalog ns farm 0 [five,six,seven,eight] claimed)
  assert "full replacement releases old claims and roles atomically" (M.null (workforceClaims swapped) && workerRole (getWorker swapped one)==Nothing && M.lookup (farm,0) (workforceRosters swapped)==Just [five,six,seven,eight])
  short<-right "short roster allowed without fake people" (assignWorkers catalog ns farm 0 [one,two,three] swapped)
  (_,shortView)<-right "short crew gate" (claimCrew (context 1) catalog ns short farm)
  (_,shortCredit)<-right "short crew has no proportional credit" (crewCredit (context 1) catalog ns short farm 100 100)
  assert "3/4 means zero work" (crewAvailable shortView==[one,two,three] && null (crewSelected shortView) && shortCredit==0)
  forM_ [Living,Incapacitated,InTransit,Evacuated] $ \status -> do
    let unavailable=changeResident four (\r->r {residentStatus=status,residentHealth=if status==Living then 0 else residentHealth r}) ns
    absent<-right "enough IDs but one unavailable" (observeCrew (context 1) catalog unavailable assigned farm)
    assert "unavailable resident never enters denominator" (length (crewAvailable absent)==3 && not (crewReady absent))
  off<-right "offshift has no current crew" (observeCrew (context 9600) catalog ns assigned farm)
  assert "roster doesn't change resident shift" (null (crewAvailable off))
  released<-right "shift boundary releases all ineligible claims" (reconcileClaims (context 9600) catalog ns claimed)
  assert "no stale shift claims" (M.null (workforceClaims released))
  drivers<-right "assign actual driver" (assignWorkers catalog ns vehicle 0 [five] claimed)
  let busyCatalog=M.adjust (\r->r {targetRemovalBusy=True}) vehicle catalog
  assert "moving driver removal is Busy" (assignWorkers busyCatalog ns vehicle 0 [] drivers==Left (Busy vehicle))
  unchanged<-right "same moving driver may remain" (assignWorkers busyCatalog ns vehicle 0 [five] drivers)
  assert "no replacement driver minted" (unchanged==drivers)
  (driven,_)<-right "bind current actual driver" (claimCrew (context 1) catalog ns drivers vehicle)
  reserve<-right "adding reserve doesn't release moving driver" (assignWorkers busyCatalog ns vehicle 0 [five,six] driven)
  reservedView<-right "bound driver remains selected" (observeCrew (context 1) busyCatalog ns reserve vehicle)
  assert "driver claim remains nonpreemptive" (M.lookup five (workforceClaims reserve)==Just vehicle && crewSelected reservedView==[five])
  let shiftNs=changeResident eight (\r->r {residentShift=1}) ns
  shifted<-right "editing inactive shift preserves live claims" (assignWorkers busyCatalog shiftNs vehicle 1 [eight] reserve)
  assert "inactive roster edit doesn't stop a moving driver" (M.lookup five (workforceClaims shifted)==Just vehicle)
  -- A smaller resident ID arriving as a reserve must not replace the held one.
  justDriver<-right "driver nonpreemption fixture" (assignWorkers catalog ns vehicle 0 [five] base)
  (heldDriver,_)<-right "driver nonpreemption claim" (claimCrew (context 1) catalog ns justDriver vehicle)
  withLower<-right "lower-ID reserve does not preempt" (assignWorkers busyCatalog ns vehicle 0 [one,five] heldDriver)
  lowerView<-right "held precedence over lower ID" (observeCrew (context 1) busyCatalog ns withLower vehicle)
  assert "held driver beats lower free resident ID" (crewSelected lowerView==[five])
  let retired=retireTarget farm claimed
  right "terminal target removed from catalog" (validateWorkforce (M.delete farm catalog) ns retired)
  assert "terminal retires roster and claims but not people" (M.null (workforceClaims retired) && M.size (workforceWorkers retired)==8)
  let corrupt=claimed {workforceClaims=M.insert one construction (workforceClaims claimed)}
  left "invalid cross-target claim rejects validation" (validateWorkforce catalog ns corrupt)

coefficientGoldens :: IO ()
coefficientGoldens=do
  raw<-readFile "data/m1-workforce/credit-golden.txt"
  let vectors=[read row :: ([Integer],[Integer],[Integer],Integer,Integer,Integer)|row<-lines raw,not (null row),head row/='#']
  assert "golden is fixed at128 independent vectors" (length vectors==128)
  forM_ (zip [0::Integer ..] vectors) $ \(index,(levels,fatigues,healths,weather,maint,expected))->do
    let amount=toInteger (length levels)
        (initial,base)=fixture amount (SimTick 0)
        members=ids [1..amount]
        ns=foldr (\(ident,f,h)->changeResident ident (\r->r {residentFatigue=f,residentHealth=h})) initial (zip3 members fatigues healths)
        wf=foldr (\(ident,level)->changeWorker ident (\w->w {workerSkills=M.insert ProcessSkill (SkillProgress level 0) (workerSkills w)})) base (zip members levels)
        cat=M.adjust (\r->r {targetRequiredPeople=amount}) farm catalog
    assigned<-right "golden assign" (assignWorkers cat ns farm 0 members wf)
    (view,actual)<-right "golden credit" (crewCredit (context 1) cat ns assigned farm weather maint)
    assert ("independent coefficient golden "++show index) (crewReady view && actual==expected)
  let (ns,base)=fixture 4 (SimTick 0)
  assigned<-right "invalid coefficient setup" (assignWorkers catalog ns farm 0 (ids [1..4]) base)
  left "oversized weather is not silently clamped" (crewCredit (context 1) catalog ns assigned farm 101 100)
  left "negative maintenance rejects" (crewCredit (context 1) catalog ns assigned farm 100 (-1))

forcedRestTests :: IO ()
forcedRestTests=do
  let (initial,base)=fixture 1 (SimTick 0)
      one=EntityId 101
      ns=changeResident one (\r->r {residentFatigue=899}) initial
      fractional=changeWorker one (\w->w {workerFatigueRemainder=1140}) base
  assigned<-right "fatigue boundary assignment" (assignWorkers catalog ns maintenance 0 [one] fractional)
  (claimed,_)<-right "fatigue899 still eligible" (claimCrew (context 1) catalog ns assigned maintenance)
  held<-right "capture held899" (captureHeldDuty (context 1) catalog ns claimed maintenance [one])
  (at900,resting,delta)<-right "cross900 triggers timer" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns claimed (M.singleton maintenance held))
  assert "forced8h starts at reaching900 and releases claim" (residentFatigue (getResident at900 one)==900 && workerForcedRestUntil (getWorker resting one)==Just (SimTick 9601) && newlyForcedRest delta==[one] && M.null (workforceClaims resting))
  sameTick<-right "no same-tick reentry" (observeCrew (context 1) catalog at900 resting maintenance)
  assert "900 excludes worker immediately" (not (crewReady sameTick))
  left "double P8 accounting rejects" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog at900 resting M.empty)
  let noBed=changeResident one (\r->r {residentBed=False}) at900
  (atExpiry,expired)<-foldM (\(n,w) t->do
      (n',w',_)<-right "bedless8h rest" (advanceWorkforce PositiveCreditElapsedTick (context t) catalog n w M.empty)
      pure (n',w')) (noBed,resting) [2..9601]
  assert "bedless8h ends660 not fully rested" (residentFatigue (getResident atExpiry one)==660 && workerForcedRestUntil (getWorker expired one)==Nothing)
  absent<-right "expiry reevaluates shift" (observeCrew (context 9601) catalog atExpiry expired maintenance)
  assert "expiry doesn't authorize a driver/worker flag" (not (crewReady absent) && M.null (workforceClaims expired))
  eligible<-right "explicit matching shift after expiry" (observeCrew (TickContext (SimTick 9601) 0) catalog atExpiry expired maintenance)
  assert "fatigue660 may work80 percent when actually eligible" (crewReady eligible)
  forM_ [Incapacitated,InTransit,Evacuated] $ \status -> do
    result<-right "expiry status revalidation" (observeCrew (TickContext (SimTick 9601) 0) catalog (changeResident one (\r->r {residentStatus=status}) atExpiry) expired maintenance)
    assert "timer cannot revive invalid status" (not (crewReady result))
  assert "midtimer state is serialization-representable" ((read (show resting) :: WorkforceState)==resting)
  left "malformed rest duration cannot enter a save" (validateWorkforce catalog at900 (changeWorker one (\w->w {workerForcedRestUntil=Just (SimTick 9602)}) resting))
  left "expired rest timer is not a canonical persisted state" (validateWorkforce catalog at900 (changeWorker one (\w->w {workerForcedRestUntil=Just (SimTick 1)}) resting))
  let end=(maxBound::Word64)-100
      nearNs=ns
      near=claimed {workforceLastAccountedTick=SimTick (end-1)}
      nearContext=TickContext (SimTick end) 0
  captured<-right "near overflow live capture" (captureHeldDuty nearContext catalog nearNs near maintenance [one])
  assert "forced-rest future overflow rejects rather than wraps" (advanceWorkforce PositiveCreditElapsedTick nearContext catalog nearNs near (M.singleton maintenance captured)==Left WorkforceCounterOverflow)
  assert "max last-accounted tick rejects advance" (advanceWorkforce PositiveCreditElapsedTick (TickContext (SimTick maxBound) 0) catalog initial (base {workforceLastAccountedTick=SimTick maxBound}) M.empty==Left WorkforceCounterOverflow)
  left "explicit checked timer overflow" (checkedFuture (SimTick maxBound) 1)
  let frozenNs=changeResident one (\r->r {residentStatus=InTransit,residentFatigue=600}) initial
  (unchanged,_,_)<-right "transit fatigue excluded" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog frozenNs base M.empty)
  assert "transit meters remain owned by separate transit scope" (residentFatigue (getResident unchanged one)==600)
  (rested,_,_)<-right "unassigned rests" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns base M.empty)
  assert "unassigned on-shift resident rests" (residentFatigue (getResident rested one)==898)
  let already900=changeResident one (\r->r {residentFatigue=900}) initial
  (_,guarded,_)<-right "fatigue900 without timer starts forced rest" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog already900 base M.empty)
  assert "initial900 cannot evade forced-rest timer" (workerForcedRestUntil (getWorker guarded one)==Just (SimTick 9601))

experienceTests :: IO ()
experienceTests=do
  let (ns,base)=fixture 1 (SimTick 0)
      one=EntityId 101
      progressAt level xp=changeWorker one (\w->w {workerSkills=M.insert MaintainSkill (SkillProgress level xp) (workerSkills w)}) base
  forM_ [0..2] $ \level -> do
    assigned<-right "XP boundary assign" (assignWorkers catalog ns maintenance 0 [one] (progressAt level 28799))
    (claimed,_)<-right "XP boundary claim" (claimCrew (context 1) catalog ns assigned maintenance)
    forM_ [1,80,130] $ \amount -> do
      evidence<-right "positive-credit capture" (captureCreditedDuty (context 1) catalog ns claimed maintenance [one] amount)
      (_,advanced,delta)<-right "positive elapsed XP tick" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns claimed (M.singleton maintenance evidence))
      assert "any positive credited elapsed tick advances once" (M.lookup MaintainSkill (workerSkills (getWorker advanced one))==Just (SkillProgress (level+1) 0) && skillLevelChanges delta==[(one,MaintainSkill)])
    zero<-right "zero credit capture" (captureCreditedDuty (context 1) catalog ns claimed maintenance [one] 0)
    (_,noXp,_)<-right "zero credit no XP" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns claimed (M.singleton maintenance zero))
    assert "zero credit cannot mint experience" (M.lookup MaintainSkill (workerSkills (getWorker noXp one))==Just (SkillProgress level 28799))
  maxAssigned<-right "max-level assignment" (assignWorkers catalog ns maintenance 0 [one] (progressAt 3 0))
  (maxClaimed,_)<-right "max-level claim" (claimCrew (context 1) catalog ns maxAssigned maintenance)
  evidence<-right "max-level credit capture" (captureCreditedDuty (context 1) catalog ns maxClaimed maintenance [one] 130)
  (_,maxed,_)<-right "max-level XP stays bounded" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns maxClaimed (M.singleton maintenance evidence))
  assert "skill max3 has no unbounded hidden counter" (M.lookup MaintainSkill (workerSkills (getWorker maxed one))==Just (SkillProgress 3 0))
  left "malformed max-level XP rejects" (validateWorkforce catalog ns (progressAt 3 1))
  left "skill4 rejects" (validateWorkforce catalog ns (progressAt 4 0))
  let under=progressAt 0 28798
  assigned<-right "XP one before boundary assignment" (assignWorkers catalog ns maintenance 0 [one] under)
  (claimed,_)<-right "XP one before boundary claim" (claimCrew (context 1) catalog ns assigned maintenance)
  e<-right "XP one before boundary capture" (captureCreditedDuty (context 1) catalog ns claimed maintenance [one] 100)
  (_,next,_)<-right "XP one before boundary" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns claimed (M.singleton maintenance e))
  assert "28799 remains level0" (M.lookup MaintainSkill (workerSkills (getWorker next one))==Just (SkillProgress 0 28799))
  serviceAssigned<-right "service policy assignment" (assignWorkers catalog ns service 0 [one] base)
  (serviceClaimed,_)<-right "service policy claim" (claimCrew (context 1) catalog ns serviceAssigned service)
  serviceEvidence<-right "service captured duty" (captureCreditedDuty (context 1) catalog ns serviceClaimed service [one] 100)
  (_,served,_)<-right "service no invented skill" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns serviceClaimed (M.singleton service serviceEvidence))
  assert "service with no skill family accrues no skill XP" (workerSkills (getWorker served one)==workerSkills (getWorker base one))

evidenceTests :: IO ()
evidenceTests=do
  let (ns,base)=fixture 4 (SimTick 0)
      one=EntityId 101;two=EntityId 102;three=EntityId 103;four=EntityId 104
  assigned<-right "evidence assignment" (assignWorkers catalog ns farm 0 [one,two,three,four] base)
  (claimed,view)<-right "evidence claim" (claimCrew (context 1) catalog ns assigned farm)
  credit<-right "capture before P7 completion" (captureCreditedDuty (context 1) catalog ns claimed farm (crewSelected view) 100)
  held<-right "capture previous held phase" (captureHeldDuty (context 1) catalog ns claimed farm [one,two,three,four])
  merged<-right "record same target in previous phase" (recordDuty held M.empty >>= recordDuty credit >>= recordDuty credit)
  (worked,finished,_)<-right "P8 consumes captured evidence after terminal retirement"
    (advanceWorkforce PositiveCreditElapsedTick (context 1) (M.delete farm catalog) ns (retireTarget farm claimed) merged)
  assert "finishing tick fatigue/XP survives terminal release" (M.null (workforceClaims finished) && workerFatigueRemainder (getWorker finished one)==60 && M.lookup ProcessSkill (workerSkills (getWorker finished one))==Just (SkillProgress 0 1) && residentFatigue (getResident worked one)==0)
  left "same captured evidence cannot be replayed next tick" (advanceWorkforce PositiveCreditElapsedTick (context 2) (M.delete farm catalog) worked finished merged)
  left "no live claim means no fabricated phase evidence" (captureHeldDuty (context 1) catalog ns assigned farm [one])
  let incapacitated=changeResident four (\r->r {residentStatus=Incapacitated,residentHealth=0}) ns
  partial<-right "reconcile removes only invalid held person" (reconcileClaims (context 1) catalog incapacitated claimed)
  assert "real partial crew remains held" (M.keys (workforceClaims partial)==[one,two,three])
  partialDuty<-right "partial held crew is actual duty" (captureHeldDuty (context 1) catalog incapacitated partial farm [one,two,three])
  left "partial crew cannot create work credit" (captureCreditedDuty (context 1) catalog incapacitated partial farm [one,two,three] 75)
  (_,bound,_)<-right "actual partial held crew fatigue" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog incapacitated partial (M.singleton farm partialDuty))
  assert "held partial crew gains fatigue without XP" (workerFatigueRemainder (getWorker bound one)==60 && M.lookup ProcessSkill (workerSkills (getWorker bound one))==Just (SkillProgress 0 0))
  (released,shortView)<-right "explicit reacquire shortage releases whole crew" (claimCrew (context 1) catalog incapacitated partial farm)
  assert "whole-release policy is explicit acquisition outcome" (not (crewReady shortView) && M.null (workforceClaims released))
  let retired=retireTarget farm claimed
  reassigned<-right "new target after explicit retirement" (assignWorkers catalog ns maintenance 0 [one] retired)
  (newClaim,_)<-right "new target claim" (claimCrew (context 1) catalog ns reassigned maintenance)
  second<-right "capture second owner to test duplicated work rejection" (captureHeldDuty (context 1) catalog ns newClaim maintenance [one])
  left "cross-target same-tick double duty rejects" (advanceWorkforce PositiveCreditElapsedTick (context 1) catalog ns newClaim (M.fromList [(farm,credit),(maintenance,second)]))
  atTwo<-right "another tick capture" (captureHeldDuty (context 2) catalog ns claimed farm [one])
  left "incompatible phase ticks cannot merge" (recordDuty atTwo merged)
  driverAssigned<-right "arrival driver assignment" (assignWorkers catalog ns vehicle 0 [one] base)
  let busyCatalog=M.adjust(\r->r{targetRemovalBusy=True})vehicle catalog
  (driverClaimed,_)<-right "arrival driver claim" (claimCrew(context 1)busyCatalog ns driverAssigned vehicle)
  moving<-right "P4 movement captures Busy driver" (captureCreditedDuty(context 1)busyCatalog ns driverClaimed vehicle[one]100)
  arrived<-right "P7 same driver after arrival" (captureHeldDuty(context 1)catalog ns driverClaimed vehicle[one])
  arrivalDuty<-right "Busy is not a different work contract" (recordDuty moving M.empty >>= recordDuty arrived)
  (_,arrivalWorker,_)<-right "arrival elapsed XP once" (advanceWorkforce PositiveCreditElapsedTick(context 1)catalog ns driverClaimed arrivalDuty)
  assert "arrival driver receives exactly one transport XP" (M.lookup TransportSkill(workerSkills(getWorker arrivalWorker one))==Just(SkillProgress 0 1))
  assert "normalization never changes live Busy removal guard" (assignWorkers busyCatalog ns vehicle 0 [] driverClaimed==Left(Busy vehicle))

speedTests :: IO ()
speedTests=do
  let (ns,base)=fixture 1 (SimTick 0)
      one=EntityId 101
  assigned<-right "speed fixture assignment" (assignWorkers catalog ns maintenance 0 [one] base)
  direct<-runFrames 1 12000 (ns,assigned)
  twice<-runFrames 2 6000 (ns,assigned)
  fourfold<-runFrames 4 3000 (ns,assigned)
  prefix<-runFrames 4 1000 (ns,assigned)
  let loaded=(read (show (fst prefix))::NeedsState,read (show (snd prefix))::WorkforceState)
  suffix<-runFrames 2 4000 loaded
  assert "pause and speed1/2/4 preserve every authoritative adjunct" (direct==twice && twice==fourfold && direct==suffix)
  let endWorker=getWorker (snd direct) one
  assert "active shift supplies exactly9599 success ticks under explicit evaluation convention" (M.lookup MaintainSkill (workerSkills endWorker)==Just (SkillProgress 0 9599))
  assert "shift boundary has no stale claims" (M.null (workforceClaims (snd direct)))
  where
    runFrames :: Integer -> Integer -> (NeedsState,WorkforceState) -> IO (NeedsState,WorkforceState)
    runFrames speed frames start = foldM (\state _ -> do
      -- Unit harness omits advanceWorkforce on paused boundaries. Actual
      -- Scheduler/Arena pause dispatch is tested by parent integration.
      foldM (\(ns,wf) _ -> do
        let SimTick lastTick=workforceLastAccountedTick wf
            ctx=context (lastTick+1)
        reconciled<-right "speed reconcile" (reconcileClaims ctx catalog ns wf)
        (claimed,view)<-right "speed exact crew" (claimCrew ctx catalog ns reconciled maintenance)
        duty<-if crewReady view then do
          e<-right "speed capture" (captureCreditedDuty ctx catalog ns claimed maintenance (crewSelected view) 100)
          pure (M.singleton maintenance e)
          else pure M.empty
        (n,w,_)<-right "speed elapsed tick" (advanceWorkforce PositiveCreditElapsedTick ctx catalog ns claimed duty)
        pure (n,w)) state [1..speed]) start [1..frames::Integer]
