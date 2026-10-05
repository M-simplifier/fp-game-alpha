{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Colony.Jobs where

import Colony.Content
import Colony.ContentCodec(contentIdentity)
import qualified Data.ByteString as BS
import Colony.Inventory
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (forM_, when, unless)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import GHC.Generics (Generic)

-- Reference job core. Workforce/power admission is provided by the scheduler.
data JobPhase = Planned | WaitingInputs | Reserved | MovingInputs | Ready | Running | Completed | Cancelled | Failed Failure
  deriving (Eq,Show,Read,Generic,NFData)
data Job = Job
  { jobId :: !EntityId, jobRecipe :: !String, jobInput :: !Owner, jobOutput :: !Owner
  , jobNaturalSources :: !(M.Map String EntityId), jobPhase :: !JobPhase, jobBlocked :: !(Maybe Failure)
  , jobProgress :: !Integer, jobRequired :: !Integer, jobTerminalCount :: !Integer, jobRecipeSnapshot :: !(Maybe Recipe), jobSnapshotContentId :: !(Maybe BS.ByteString) }
  deriving (Eq,Show,Read,Generic,NFData)

terminal :: Job -> Bool
terminal j=case jobPhase j of Completed->True; Cancelled->True; Failed _->True; _->False
wipOwner :: Job -> Owner
wipOwner j=Owner MachineInput (jobId j)

planJob :: Content -> String -> Owner -> Owner -> M.Map String EntityId -> InventoryTx Job
planJob content rid src dst sources=do
  recipe<-either (throwTx . InvalidReference) pure (lookupRecipe content rid)
  ident<-freshId
  s<-get
  st<-maybe (throwTx MissingOwner) pure (M.lookup src(invStorage s))
  addStorage (Owner MachineInput ident) (Storage 400000 Nothing (storageColony st))
  pure $ Job ident rid src dst sources Planned Nothing 0 (recipeWorkTicks recipe*100) 0 Nothing Nothing

startJob :: Content -> SimTick -> Job -> InventoryTx Job
startJob content tick j=do
  require (not(terminal j) && jobPhase j/=Running) AlreadyTerminal
  recipe<-either (throwTx . InvalidReference) pure (lookupRecipe content(jobRecipe j))
  forM_ (M.toAscList(recipeInputs recipe)) $ \(r,n)->reserveQuantity tick(jobId j)(jobInput j) r n
  forM_ (M.toAscList(recipeOutputs recipe)) $ \(r,n)->reserveCapacity(jobId j)(jobOutput j) r n
  forM_ (M.toAscList(recipeNaturalSources recipe)) $ \(kind,n)->do
    ident<-maybe(throwTx MissingStock)pure(M.lookup kind(jobNaturalSources j))
    depot<-gets(M.lookup ident . invDeposits) >>= maybe(throwTx MissingStock)pure
    definition<-maybe(throwTx(InvalidReference "natural source content missing"))pure(M.lookup kind(contentNaturalSources content))
    require(depositKind depot==kind&&depositResource depot==naturalSourceResource definition)(InvalidReference "natural source kind/resource mismatch")
    reserveNatural(jobId j) ident n
  when (not(M.null(recipeInputs recipe))) $ moveReserved(jobId j)(jobInput j)(wipOwner j)
  digest<-either(throwTx . InvalidReference)pure(contentIdentity content)
  pure j {jobPhase=Running,jobBlocked=Nothing,jobRequired=recipeWorkTicks recipe*100,jobRecipeSnapshot=Just recipe,jobSnapshotContentId=Just digest}

completeJob :: Content -> TxId -> SimTick -> Job -> InventoryTx Job
completeJob _content tx tick j=do
  require (jobPhase j==Running && jobProgress j>=jobRequired j && not(terminal j)) AlreadyTerminal
  current<-get
  either throwTx pure(validateRunningJob j current)
  recipe<-maybe(throwTx(InvariantViolation "running job has no RecipeSnapshot"))pure(jobRecipeSnapshot j)
  if M.null(recipeNaturalSources recipe)
    then do
      consumeAllAt tx RecipeInput(jobId j)(wipOwner j)
      releaseJob(jobId j)
      forM_ (M.toAscList(recipeOutputs recipe)) $ \(r,n)->do
        shelf<-gets(M.findWithDefault Nothing r.invShelf)
        let SimTick now=tick
        expiry<-case shelf of
          Nothing->pure Nothing
          Just life->do
            require (toInteger now+toInteger life<=toInteger(maxBound::Word64)) CounterOverflow
            pure(Just(SimTick(now+life)))
        _<-mintLot tx RecipeOutput(Just(jobId j)) r n(jobOutput j) tick expiry ("recipe:"++jobRecipe j)
        pure()
    else extractReserved tx(jobId j)(jobOutput j)tick >> releaseJob(jobId j)
  pure j {jobPhase=Completed,jobProgress=jobRequired j,jobTerminalCount=jobTerminalCount j+1}

-- Return destinations are deterministic and entire cancellation is preflighted in StateT.
-- This reference core supports machine output and same-colony warehouses. Spatial GroundCache
-- candidate generation is intentionally tracked as unfinished, never a hidden discard.
returnDestinations :: Job -> Inventory -> [Owner]
returnDestinations j s = jobOutput j : [o| (o@(Owner Warehouse _),st)<-M.toAscList(invStorage s),o/=jobOutput j,Just(storageColony st)==colony]
  where colony=storageColony <$> M.lookup(jobOutput j)(invStorage s)

returnPhysical :: TxId -> Job -> Integer -> Integer -> Bool -> InventoryTx ()
returnPhysical tx j progress required forced=do
  lots<-gets(filter((==wipOwner j).lotOwner).M.elems.invLots)
  releaseJob(jobId j)
  forM_ lots $ \l->do
    let q=qtyValue(lotQty l); loss=if required==0 then 0 else q*progress `div` required; back=q-loss
    when(loss>0) $ do
      _<-removeFromLot(lotId l)loss
      record tx CancelledProcessLoss(Just(jobId j))(lotResource l)loss(Just(wipOwner j))Nothing
    when(back>0) $ do
      s<-get
      let fits o=freeWeight s o>=weightOf s(lotResource l)back && maybe False (\st->maybe True(==lotResource l)(storageResource st))(M.lookup o(invStorage s))
      destination<-case filter fits(returnDestinations j s) of
        o:_->pure o
        [] | forced->do
          let recovery=Owner RecoveryHold(jobId j)
          when (not(M.member recovery(invStorage s))) $ do
            colony<-maybe(throwTx MissingOwner)(pure.storageColony)(M.lookup(jobOutput j)(invStorage s))
            addStorage recovery(Storage quantityMax Nothing colony)
          pure recovery
        []->throwTx ReturnCapacityFull
      case destination of
        Owner RecoveryHold _->transferRecovered destination [(lotId l,back)]
        _->transferSelected destination [(lotId l,back)]

cancelJob :: TxId -> Job -> InventoryTx Job
cancelJob tx j=do
  require(not(terminal j))AlreadyTerminal
  if jobPhase j==Running then returnPhysical tx j(jobProgress j)(jobRequired j)False else releaseJob(jobId j)
  pure j {jobPhase=Cancelled,jobBlocked=Nothing,jobTerminalCount=jobTerminalCount j+1}

failExpiredJob :: TxId -> Job -> InventoryTx Job
failExpiredJob tx j=do
  require(not(terminal j))AlreadyTerminal
  -- The expired lot was already transformed by P2; only surviving physical WIP is returned.
  returnPhysical tx j 0 1 True
  pure j {jobPhase=Failed ExpiredInput,jobBlocked=Nothing,jobTerminalCount=jobTerminalCount j+1}

validateJobs :: M.Map EntityId Job -> Inventory -> Either Failure ()
validateJobs jobs inventory=forM_ (M.toList jobs) $ \(ident,j)->do
  let requireJ b msg=unless b(Left(InvariantViolation msg))
  requireJ (ident==jobId j && jobProgress j>=0 && jobProgress j<=jobRequired j && jobRequired j>0) "invalid job progress"
  requireJ (jobTerminalCount j==if terminal j then 1 else 0) "job terminal uniqueness"
  when(jobPhase j==Running)(validateRunningJob j inventory)
  when(terminal j) $ do
    requireJ (all((/=ident).quantityJob)(M.elems(invQuantity inventory))) "terminal quantity reservation"
    requireJ (all((/=ident).capacityJob)(M.elems(invCapacity inventory))) "terminal capacity reservation"
    requireJ (all((/=ident).naturalJob)(M.elems(invNatural inventory))) "terminal natural reservation"
  requireJ (M.member(jobInput j)(invStorage inventory) && M.member(jobOutput j)(invStorage inventory)) "dangling job endpoint"

validateRunningJob :: Job -> Inventory -> Either Failure ()
validateRunningJob j inventory=do
  let check b message=unless b(Left(InvariantViolation message))
  snapshot<-maybe(Left(InvariantViolation "running job lacks recipe snapshot"))Right(jobRecipeSnapshot j)
  check(maybe False((==32).BS.length)(jobSnapshotContentId j)) "running snapshot lacks content ID"
  check(recipeId snapshot==jobRecipe j&&recipeWorkTicks snapshot*100==jobRequired j) "recipe snapshot mismatch"
  let physical=M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-M.elems(invLots inventory),lotOwner lot==wipOwner j]
      expectedCapacity=sum[weightOf inventory resource quantity|(resource,quantity)<-M.toList(recipeOutputs snapshot)]
      capacities=[r|r<-M.elems(invCapacity inventory),capacityJob r==jobId j]
      actualNatural=M.fromListWith(+)[(naturalSource r,qtyValue(naturalAmount r))|r<-M.elems(invNatural inventory),naturalJob r==jobId j]
  expectedNatural<-mapM(\(kind,quantity)->do
    source<-maybe(Left(InvariantViolation "running natural binding missing"))Right(M.lookup kind(jobNaturalSources j))
    deposit<-maybe(Left(InvariantViolation "running deposit missing"))Right(M.lookup source(invDeposits inventory))
    check(depositKind deposit==kind) "running deposit kind mismatch"
    check(M.lookup(depositResource deposit)(recipeOutputs snapshot)==Just quantity) "running extraction resource mismatch"
    pure(source,quantity))(M.toList(recipeNaturalSources snapshot))
  check(physical==recipeInputs snapshot) "running WIP differs from recipe snapshot"
  check(all((==jobOutput j).capacityOwner)capacities&&sum(map capacityWeight capacities)==expectedCapacity) "running output capacity differs from recipe snapshot"
  check(actualNatural==M.fromListWith(+)expectedNatural) "running natural reservation differs from recipe snapshot"
  check(all((/=jobId j).quantityJob)(M.elems(invQuantity inventory))) "running job retained input quantity reservation"
