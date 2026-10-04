{-# LANGUAGE BangPatterns #-}
module SchedulerTests (schedulerTests) where

import Colony.Arena
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Power
import Colony.RNG (initialRng)
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad (forM_, unless, void)
import qualified Data.Map.Strict as M
import Data.Either (isLeft)
import Data.List (nub)
import Data.Word (Word64)
import qualified Game.Arena as A
import Game.Transition (stepMachine)
import System.Environment (lookupEnv)

assert :: String -> Bool -> IO ()
assert label yes = unless yes (ioError (userError ("Scheduler assertion failed: " ++ label)))
must :: Show e => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

source, destination :: Owner
source = Owner Warehouse (EntityId 100)
destination = Owner MachineOutput (EntityId 101)
hand, farm, electric :: EntityId
hand = EntityId 1000
farm = EntityId 1001
electric = EntityId 1002
fixtureTx :: TxId
fixtureTx = TxId 1 1 (BoundarySeq 0) P0 0

-- Canonical, unmodified content: static fixture staffing is not workforce or
-- power simulation. Initial stock is minted only through checked transactions.
fixture :: Content -> IO World
fixture c = do
  (deposit,inv) <- must "checked initial grants" $ runInventory (do
    addStorage source (Storage 2000000 Nothing (EntityId 1))
    addStorage destination (Storage 400000 Nothing (EntityId 1))
    void (mintLot fixtureTx InitialGrant Nothing Water 600000 source (SimTick 0) Nothing "scheduler fixture")
    addDeposit "aquifer" Water 2000000) (emptyInventory c)
  let sources=M.singleton "aquifer" deposit
      w=(initialWorld c) {worldInventory=inv {invNextId=1003},worldSites=M.fromList
        [(hand,Site hand "hand_water" source destination sources 2 True),
         (farm,Site farm "grow" source destination M.empty 4 True),
         (electric,Site electric "pump" source destination sources 2 True)]}
  must "fixture world invariant" (validateWorld w)
  pure w

header :: Bool -> World -> BoundaryHeader
header advancing w=BoundaryHeader (worldId w) (branchId w) (boundarySeq w) advancing (worldAuthority w) (worldRuleset w)
epoch :: World -> Epoch
epoch w=participantEpoch (worldParticipants w M.! 1)
command :: World -> Word64 -> Word64 -> Command -> OrderedCommand
command w ordinal number body=OrderedCommand ordinal (CommandId (worldId w) 1 (epoch w) number) body
nextSequence :: World -> Word64
nextSequence w=1+M.findWithDefault 0 (1,epoch w) (worldHighWater w)
commands :: World -> [Command] -> [OrderedCommand]
commands w bodies=zipWith (\i body -> command w i (nextSequence w+i) body) [0..] bodies

step :: Bool -> [Command] -> [ManagementEvent] -> World -> (World,ColonyOutput)
step advancing bodies management w=pureStep (Boundary (header advancing w) (commands w bodies) management) w
passive :: World -> World
passive w=fst (step True [] [] w)
advanceTicks :: Integer -> World -> World
advanceTicks n w=go n w where go 0 !s=s; go k !s=go (k-1) (passive s)
jobAt :: EntityId -> World -> Job
jobAt site w=case [j | j<-M.elems(worldJobs w),M.lookup(jobId j)(worldJobSites w)==Just site] of
  j:_->j; []->error "test fixture missing job"
physical :: Resource -> Inventory -> Integer
physical resource inv=sum [qtyValue(lotQty l)|l<-M.elems(invLots inv),lotResource l==resource]
quantityAt :: Resource -> Owner -> Inventory -> Integer
quantityAt resource owner inv=sum [qtyValue(lotQty l)|l<-M.elems(invLots inv),lotResource l==resource,lotOwner l==owner]
ledger :: Resource -> Reason -> Inventory -> Integer
ledger resource reason inv=M.findWithDefault 0 (resource,reason) (invLedger inv)
noRefs :: EntityId -> Inventory -> Bool
noRefs jid inv=all ((/=jid).quantityJob) (M.elems(invQuantity inv)) &&
  all ((/=jid).capacityJob) (M.elems(invCapacity inv)) && all ((/=jid).naturalJob) (M.elems(invNatural inv))
eventJob :: DomainEvent -> EntityId
eventJob event=case event of JobPlanned _ j->j;JobStarted _ j->j;JobCompleted _ j->j;JobCancelled _ j->j;JobExpired _ j->j;_->error "legacy scheduler fixture emitted schema4 event"
eventId :: DomainEvent -> EventId
eventId event=case event of JobPlanned i _->i;JobStarted i _->i;JobCompleted i _->i;JobCancelled i _->i;JobExpired i _->i;ConstructionPlanned i _->i;ConstructionStarted i _->i;ConstructionCompleted i _->i;ConstructionCancelled i _->i;WorkersAssigned i _->i;GroundCacheRetired i _ _->i
isTerminalEvent :: DomainEvent -> Bool
isTerminalEvent JobCompleted{}=True
isTerminalEvent JobCancelled{}=True
isTerminalEvent JobExpired{}=True
isTerminalEvent _=False

parity :: Content -> IO ()
parity c=do
  initial<-fixture c
  let loop :: Word64 -> World -> World -> World -> [DomainEvent] -> IO ()
      loop !count !direct !machine !arena !history
        | simTick direct==SimTick 10000 = do
            assert "trace has exactly 10000 advancing ticks" (simTick arena==SimTick 10000 && count==10004)
            assert "trace final state invariant" (validateWorld direct==Right ())
            let terminalEvents=filter isTerminalEvent history
            assert "trace exercises completion" (length terminalEvents>=6)
            assert "trace event IDs unique" (length(map eventId history)==length(nub(map eventId history)))
            assert "trace terminal event uniqueness" (length(map eventJob terminalEvents)==length(nub(map eventJob terminalEvents)))
            assert "trace checked extraction accounting" (ledger Water Extraction(worldInventory direct)==300000)
            assert "trace checked farm output accounting" (ledger Crops RecipeOutput(worldInventory direct)==60000)
            putStrLn ("scheduler parity: "++show count++" admitted boundaries, 10000 simulation ticks, "++show(length history)++" events; direct == Machine == Arena")
        | otherwise=do
            let SimTick tick=simTick direct
                advancing=worldMode direct==Active
                target=tick+1
                pausedCount=count-tick
                manage | advancing && target `elem` [1000,5000]=[PauseWorld]
                       | not advancing && odd pausedCount=[ResumeWorld]
                       | otherwise=[]
                bodies | not advancing=[]
                       | target==1=[OrderProduction hand,OrderProduction farm]
                       | target `mod` 1000==1=[OrderProduction hand]
                       | target `mod` 997==0=[SetSiteEnabled (EntityId 99999) True]
                       | otherwise=[]
                cmds=commands direct bodies
                h=header advancing direct
                native=Boundary h cmds manage
                context=RecordedBoundary h (map commandId cmds) manage
                choices=if null cmds then A.nobody else A.singleton 1 (OrderedBatch cmds)
                directResult=pureStep native direct
                machineResult=stepMachine Colony native machine
            admittedNative<-must ("trace admission boundary "++show count) (A.admit Colony context choices arena)
            assert "admission preserves exact native input" (admittedNative==native)
            arenaResult<-must "Arena.play" (A.play Colony context choices arena)
            assert ("parity at boundary "++show count) (directResult==machineResult && directResult==arenaResult)
            let (next,output)=directResult
            assert "admitted trace has no fatal diagnostics" (null(outputDiagnostics output))
            assert "per-boundary committed invariant" (validateWorld next==Right ())
            loop (count+1) next (fst machineResult) (fst arenaResult) (outputEvents output++history)
  loop 0 initial initial initial []

observation :: Content -> IO ()
observation c=do
  w<-fixture c
  let changed=w {worldRng=initialRng 938471}
  assert "private RNG really differs" (worldRng w/=worldRng changed)
  forM_ [1,999] $ \participant ->
    assert "observation excludes private RNG" (A.observe Colony participant w==A.observe Colony participant changed)
  assert "observation identifies unknown participant" (not(viewKnownParticipant(A.observe Colony 999 w)))
  assert "observation reflects visible changes" (A.observe Colony 1 w/=A.observe Colony 1 (w {simTick=SimTick 1}))

ordering :: Content -> IO ()
ordering c=do
  w<-fixture c
  let plannedId=EntityId(invNextId(worldInventory w))
      (next,out)=step False [OrderProduction farm,CancelProduction plannedId] [] w
  assert "P1 preserves create-then-cancel order" (map receiptOutcome(outputReceipts out)==[Applied(Just plannedId),Applied(Just plannedId)])
  assert "later command sees earlier command" (jobPhase(worldJobs next M.! plannedId)==Cancelled)
  assert "planned and cancelled event order" (case outputEvents out of [JobPlanned _ a,JobCancelled _ b]->a==plannedId && b==a;_->False)
  let (reverseNext,reverseOut)=step False [CancelProduction plannedId,OrderProduction farm] [] w
  assert "reversed command batch has different intended result" (jobPhase(worldJobs reverseNext M.! plannedId)==Planned &&
    map receiptOutcome(outputReceipts reverseOut)==[CommandFailed TargetGone,Applied(Just plannedId)])

retransmission :: Content -> IO ()
retransmission c=do
  w<-fixture c
  let (once,out1)=step False [OrderProduction hand] [] w
      old=command once 0 1 (OrderProduction hand)
      suffix=command once 1 2 (SetSiteEnabled hand False)
      cmds=[old,suffix]
      h=header False once
      context=RecordedBoundary h (map commandId cmds) []
  (twice,out2)<-must "partial known-prefix retransmit" (A.play Colony context (A.singleton 1(OrderedBatch cmds)) once)
  assert "retransmit produces cached original receipt" (head(outputReceipts out2)==head(outputReceipts out1))
  assert "known prefix does not execute again" (M.size(worldJobs twice)==1 && null(outputEvents out2))
  assert "only new suffix executes" (not(siteEnabled(worldSites twice M.! hand)) && M.lookup(1,epoch twice)(worldHighWater twice)==Just 2)
  let pruned=twice {worldReceipts=[]}
      (afterPrune,out3)=pureStep (Boundary(header False pruned)[old][]) pruned
  assert "pruned receipt uses AlreadyProcessed without replaying effect" (map receiptOutcome(outputReceipts out3)==[AlreadyProcessed] && worldJobs afterPrune==worldJobs pruned && null(outputEvents out3))
  -- A batch whose prefix is known still cannot be reordered by Context.
  let a=old {commandOrdinal=1}; b=suffix {commandOrdinal=0}
      contextWrong=RecordedBoundary h [commandId b,commandId a] []
  assert "context cannot reorder known-prefix batch" (isLeft(A.admit Colony contextWrong (A.singleton 1(OrderedBatch[a,b])) once))

admission :: Content -> IO ()
admission c=do
  w<-fixture c
  let valid=command w 0 1 (OrderProduction hand)
      rejected label state cmds recorded participant=case A.attempt Colony recorded (A.singleton participant(OrderedBatch cmds)) state of
        A.Rejected _ unchanged->assert (label++" rejected with identical state") (unchanged==state)
        _->assert (label++" unexpectedly admitted") False
      context state cmds=RecordedBoundary(header False state)(map commandId cmds)[]
      check label state cmds=rejected label state cmds (context state cmds) 1
  check "duplicate identity" w [valid,valid {commandOrdinal=1}]
  check "future gap" w [command w 0 2 (OrderProduction hand)]
  check "internal batch gap" w [valid,command w 1 3 (OrderProduction farm)]
  check "epoch mismatch" w [valid {commandId=CommandId 1 1(Epoch "stale" 0)1}]
  check "viewer mutation" (w {worldParticipants=M.adjust(\p->p {participantRole=ViewerRole})1(worldParticipants w)}) [valid]
  check "ordinal mismatch" w [valid {commandOrdinal=1}]
  check "participant batch fuel" w [command w n (n+1)(SetSiteEnabled hand True)|n<-[0..64]]
  rejected "context omissions" w [valid] (RecordedBoundary(header False w)[][]) 1
  rejected "unknown participant" w [valid] (context w [valid]) 9
  rejected "wrong authority" w [valid] (RecordedBoundary((header False w){headerAuthority="untrusted"})[commandId valid][]) 1
  let (once,_)=step False [OrderProduction hand][] w
      collision=command once 0 1 (OrderProduction farm)
  check "sequence collision" once [collision]
  forM_ [[valid,valid {commandOrdinal=1}], [command w 0 2 (OrderProduction hand)],
         [valid {commandId=CommandId 1 1(Epoch "stale" 0)1}]] $ \cmds -> do
    let (same,out)=pureStep(Boundary(header False w)cmds[])w
    assert "direct admission rejects unchanged" (same==w && null(outputEvents out) && null(outputReceipts out) && case outputDiagnostics out of [FatalBoundaryRejected _]->True;_->False)
  assert "Joint rejects duplicate participant" (isLeft(A.joint [(1 :: Word64,OrderedBatch[valid]),(1,OrderedBatch[])]))

failureConsumes :: Content -> IO ()
failureConsumes c=do
  w<-fixture c
  let (next,out)=step False [CancelProduction(EntityId 99999),OrderProduction hand][] w
  assert "world failure emits receipt" (case map receiptOutcome(outputReceipts out) of [CommandFailed TargetGone,Applied(Just _)]->True;_->False)
  assert "world failure consumes sequence allowing next command" (M.lookup(1,epoch next)(worldHighWater next)==Just 2 && M.size(worldJobs next)==1)

pause :: Content -> IO ()
pause c=do
  w<-fixture c
  let (paused,out)=step True [OrderProduction hand][PauseWorld] w
      j=jobAt hand paused
  assert "PauseWorld keeps this boundary's advance decision" (simTick paused==SimTick 1 && worldMode paused==Paused && jobProgress j==100 && jobPhase j==Running && null(outputDiagnostics out))
  let (planned,_)=step False [OrderProduction farm][] paused
      (still,_)=step False [][] planned
  assert "paused boundary does no automatic start, movement or work" (worldInventory still==worldInventory planned && worldJobs still==worldJobs planned && simTick still==SimTick 1 && jobPhase(jobAt farm still)==Planned)
  let badNative=Boundary(header True still)[][]
      (rejected,outBad)=pureStep badNative still
  assert "paused cannot advance" (rejected==still && case outputDiagnostics outBad of [FatalBoundaryRejected _]->True;_->False)
  let (resumed,_)=step False [][ResumeWorld] still
  assert "ResumeWorld does not advance same paused boundary" (simTick resumed==SimTick 1 && jobProgress(jobAt hand resumed)==100 && worldMode resumed==Active)
  let (next,_)=step True [][] resumed
  assert "resume starts automatic work at next boundary" (simTick next==SimTick 2 && jobProgress(jobAt hand next)==200 && jobPhase(jobAt farm next)==Running)

cancelWins :: Content -> IO ()
cancelWins c=do
  w<-fixture c
  let (started,_)=step True [OrderProduction hand][] w
      ready=advanceTicks 1198 started
      job=jobAt hand ready
      jid=jobId job
      beforeInv=worldInventory ready
      (finished,outFinished)=step True [][] ready
      (cancelled,out)=step True [CancelProduction jid][] ready
  assert "reachable cancellation fixture one credit before completion" (jobProgress job==jobRequired job-100 && simTick ready==SimTick 1199)
  assert "control without cancellation actually completes" (jobPhase(jobAt hand finished)==Completed && any isTerminalEvent(outputEvents outFinished))
  assert "P1 cancellation wins over P7 completion" (jobPhase(jobAt hand cancelled)==Cancelled && jobTerminalCount(jobAt hand cancelled)==1 && case outputEvents out of [JobCancelled _ j]->j==jid;_->False)
  assert "cancellation releases natural and capacity reservations" (noRefs jid(worldInventory cancelled))
  assert "cancelled extraction does not mint or deplete" (invDeposits(worldInventory cancelled)==invDeposits beforeInv && physical Water(worldInventory cancelled)==physical Water beforeInv && ledger Water Extraction(worldInventory cancelled)==0)
  let (again,outAgain)=step True [CancelProduction jid][] cancelled
  assert "terminal cannot transition twice" (jobPhase(jobAt hand again)==Cancelled && jobTerminalCount(jobAt hand again)==1 && map receiptOutcome(outputReceipts outAgain)==[CommandFailed AlreadyTerminal] && null(outputEvents outAgain))

-- Real powered cook WIP expires at the next boundary; no invented recipe/input.
expiry :: Content -> IO ()
expiry c=do
  base<-fixture c
  let cookId=EntityId 5000;gridId'=EntityId 6000
      kitchen=Site cookId "cook" source destination M.empty 2 True
      grid=PowerGrid gridId' [] [Generator(EntityId 6001)source True 100] [] M.empty
      registered=(worldInventory base){invNextId=6002}
  (_,stock)<-must "expiry physical stock" $ runInventory (do
    void(mintLot fixtureTx InitialGrant Nothing Crops 20000 source(SimTick 0)(Just(SimTick 2))"cook expiry input")
    void(mintLot fixtureTx InitialGrant Nothing Fuel 1100 source(SimTick 0)Nothing"cook and generator fuel"))registered
  let ready=base {worldInventory=stock,worldSites=M.insert cookId kitchen(worldSites base),worldPowerGrids=M.singleton gridId' grid,worldSiteGrids=M.singleton cookId gridId'}
      (running,startOutput)=step True [OrderProduction cookId][] ready
      j0=jobAt cookId running;jid=jobId j0
      j=j0 {jobProgress=jobRequired j0-100}
      before=running {worldJobs=M.insert jid j(worldJobs running)}
      inv=worldInventory before
      originalWater=physical Water inv
      (after,out)=step True [][] before
      finalInv=worldInventory after
  must "real powered expiry fixture invariants" (validateWorld before)
  assert "cook really started and powered before expiry"(jobPhase j0==Running&&jobProgress j0==100&&null(outputDiagnostics startOutput))
  assert "P2 WIP expiry wins over would-complete P7" (jobPhase(worldJobs after M.! jid)==Failed ExpiredInput && jobTerminalCount(worldJobs after M.! jid)==1 && case outputEvents out of [JobExpired _ ident]->ident==jid;_->False)
  assert "WIP expiry releases all references" (noRefs jid finalInv)
  assert "expired physical input does not return or complete recipe" (physical Crops finalInv==0 && ledger Crops SpoilageInput finalInv==20000 && ledger Ration RecipeOutput finalInv==0)
  assert "surviving input returns exactly once without process loss" (physical Water finalInv==originalWater && quantityAt Water destination finalInv==10000 && quantityAt Water(wipOwner j)finalInv==0 && ledger Water CancelledProcessLoss finalInv==0)
  assert "natural sources remain untouched on expiry" (invDeposits finalInv==invDeposits inv)
  assert "expiry remains terminal on next boundary" (jobPhase(jobAt cookId(passive after))==Failed ExpiredInput)

rollback :: Content -> IO ()
rollback c=do
  w<-fixture c
  let bodies=[OrderProduction hand]
      (_,goodOut)=step True bodies[] w
      corrupt=w {worldJobSites=M.singleton (EntityId 999999) hand}
      native=Boundary(header True corrupt)(commands corrupt bodies)[]
      (after,out)=pureStep native corrupt
  assert "rollback control normally stages events and receipts" (length(outputEvents goodOut)==2 && length(outputReceipts goodOut)==1)
  case outputDiagnostics out of
    [FaultDiagnostic P10 reason ids]->do
      assert "P10 resets every world field except Faulted marker" (after==corrupt {worldMode=Faulted reason})
      assert "P10 diagnostic identifies all attempted commands" (ids==map commandId(commands corrupt bodies))
    _->assert "P10 fault diagnostic expected" False
  assert "P10 publishes no staged events or receipts" (null(outputEvents out) && null(outputReceipts out))
  assert "P10 keeps tick boundary high-water and receipt checkpoint" (simTick after==simTick corrupt && boundarySeq after==boundarySeq corrupt && worldHighWater after==worldHighWater corrupt && worldReceipts after==worldReceipts corrupt)
  let (blocked,outBlocked)=step False [][] after
  assert "faulted world blocks further boundary" (blocked==after && case outputDiagnostics outBlocked of [FatalBoundaryRejected _]->True;_->False)

overflow :: Content -> IO ()
overflow c=do
  w<-fixture c
  forM_ [("boundary",w {boundarySeq=BoundarySeq maxBound},[]),
         ("tick",w {simTick=SimTick maxBound},[]),
         ("revision",w {worldRevision=maxBound},[]),
         ("allocation",w {worldInventory=(worldInventory w){invNextId=maxBound}},[OrderProduction hand])] $ \(label,before,bodies)->do
    let (after,out)=step True bodies[] before
    assert (label++" limit stops before wrap with full rollback") (after==before {worldMode=Faulted CounterOverflow} && null(outputEvents out) && null(outputReceipts out) && case outputDiagnostics out of [FaultDiagnostic _ CounterOverflow _]->True;_->False)
  -- A completed farm product would acquire a shelf life beyond Word64.
  let (started,_)=step True [OrderProduction farm][] w
      j=jobAt farm started
      before=started {simTick=SimTick(maxBound-1),worldJobs=M.adjust(\x->x {jobProgress=jobRequired x-100})(jobId j)(worldJobs started)}
      (after,out)=step True [][] before
  assert "output expiry arithmetic refuses wrap atomically" (after==before {worldMode=Faulted CounterOverflow} && null(outputEvents out) && null(outputReceipts out))

powerAdmission :: Content -> IO ()
powerAdmission c=do
  w<-fixture c
  let (next,out)=step True [OrderProduction electric][] w
      j=jobAt electric next
  assert "electric job cannot work without actual P6 supply" (jobBlocked j==Just(InvalidReference "NoPower") && jobProgress j==0 && jobPhase j==Running)
  assert "power-starved extraction preserves deposit and reservations" (not(noRefs(jobId j)(worldInventory next)) && invDeposits(worldInventory next)==invDeposits(worldInventory w) && physical Water(worldInventory next)==physical Water(worldInventory w))
  assert "electric request is admitted world outcome" (case map receiptOutcome(outputReceipts out) of [Applied(Just _)]->True;_->False)
  (_,fuelled)<-must "checked generator fuel grant" $ runInventory
    (void(mintLot fixtureTx InitialGrant Nothing Fuel 20 source (SimTick 1) Nothing "P6 integration fixture")) (worldInventory next)
  let gid=EntityId 2000
      grid=PowerGrid gid [] [Generator (EntityId 2001) source True 100] [] M.empty
      supplied=next {worldInventory=fuelled {invNextId=max(invNextId fuelled)10003},worldPowerGrids=M.singleton gid grid,worldSiteGrids=M.singleton electric gid}
      (powered,poweredOut)=step True [][] supplied
      poweredJob=jobAt electric powered
      (starved,_)=step True [][] powered
  must "real generator fixture invariant" (validateWorld supplied)
  assert "P6 burns real fuel before P7 grants work" (jobProgress poweredJob==100 && jobBlocked poweredJob==Nothing && ledger Fuel FuelBurned(worldInventory powered)==20 && null(outputDiagnostics poweredOut))
  assert "P6 served-energy accounting is real" (M.findWithDefault 0 ConsumerServed(gridEnergyLedger(worldPowerGrids powered M.! gid))==18000)
  assert "fuel exhaustion stops subsequent work without losing reservations" (jobProgress(jobAt electric starved)==100 && jobBlocked(jobAt electric starved)==Just(InvalidReference "NoPower") && invNatural(worldInventory starved)==invNatural(worldInventory powered))

schedulerTests :: Content -> IO ()
schedulerTests c=do
  selected<-lookupEnv "RED_DUNE_SCHEDULER_CASE"
  let cases=[("observation",observation),("ordering",ordering),("retransmission",retransmission),
             ("admission",admission),("failure-sequence",failureConsumes),("pause",pause),
             ("cancel",cancelWins),("expiry",expiry),("rollback",rollback),
             ("overflow",overflow),("power",powerAdmission),("parity",parity)]
  assert "requested scheduler test case exists" (maybe True (`elem` map fst cases) selected)
  forM_ cases $ \(name,test)->whenSelected selected name (test c >> putStrLn("scheduler case PASS: "++name))
  where whenSelected selected name action=if maybe True(==name)selected then action else pure ()
