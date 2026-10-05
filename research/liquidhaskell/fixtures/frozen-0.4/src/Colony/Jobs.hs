{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module Colony.Jobs where

import Colony.Content
import Colony.Ruleset
import Colony.ContentCodec(contentIdentity, RecipeCatalogs, knownRecipeCatalogsForContent)
import qualified Data.ByteString as BS
import Colony.Inventory
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (forM_, when, unless, foldM)
import Control.Monad.State.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import Data.List (sortOn)
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
completeJob content tx tick j=do
  require (jobPhase j==Running && jobProgress j>=jobRequired j && not(terminal j)) AlreadyTerminal
  catalogs<-either(throwTx . InvariantViolation)pure(knownRecipeCatalogsForContent content)
  either throwTx pure(validateJobSnapshotCatalog catalogs j)
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

returnPhysical :: CancellationRounding -> TxId -> Job -> Integer -> Integer -> Bool -> InventoryTx ()
-- Profiles4/5 only extend old resource cancellation's capacity refusal. Running
-- the exact old transaction privately preserves every previously accepted lot
-- ID, ledger order and metadata; a failed attempt allocates no public IDs.
returnPhysical ResourceAggregateSplit tx j progress required forced=do
  before<-get
  case runStateT(returnPhysical ResourceAggregate tx j progress required forced)before of
    Right(_,after)->put after
    Left ReturnCapacityFull | not forced->returnSplitPhysical tx j progress required
    Left failure->throwTx failure
returnPhysical rounding tx j progress required forced=do
  lots<-gets(filter((==wipOwner j).lotOwner).M.elems.invLots)
  releaseJob(jobId j)
  case rounding of
    -- Frozen compatibility semantics: preserve both per-lot floor and the old
    -- interleaved loss/return order for existing ruleset0/1 replay hashes.
    LegacyPerLot->forM_ lots $ \l->do
      let q=qtyValue(lotQty l);loss=lost q
      lose l loss
      returnLot l(q-loss)
    _ ->forM_ (resourceLotGroups lots) $ \(resource,group)->do
      loseResourceGroup tx j progress required group
      -- Return actual survivors only, in FEFO order, with original lot metadata.
      survivors<-gets(sortOn fefo.filter(\l->lotOwner l==wipOwner j&&lotResource l==resource).M.elems.invLots)
      forM_ survivors $ \l->returnLot l(qtyValue(lotQty l))
  where
    lost=cancelLoss progress required
    lose=losePhysical tx j
    returnLot l back=when(back>0) $ do
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

-- Shared arithmetic for both whole-lot and split placement. Loss always uses
-- one Integer resource total, with physical consumption in FEFO order.
resourceLotGroups :: [Lot] -> [(Resource,[Lot])]
resourceLotGroups lots=M.toAscList(M.fromListWith(++)[(lotResource lot,[lot])|lot<-lots])

cancelLoss :: Integer -> Integer -> Integer -> Integer
cancelLoss progress required quantity=if required==0 then 0 else quantity*progress `div` required

losePhysical :: TxId -> Job -> Lot -> Integer -> InventoryTx ()
losePhysical tx job lot quantity=when(quantity>0)$do
  _<-removeFromLot(lotId lot)quantity
  record tx CancelledProcessLoss(Just(jobId job))(lotResource lot)quantity(Just(wipOwner job))Nothing

loseResourceGroup :: TxId -> Job -> Integer -> Integer -> [Lot] -> InventoryTx ()
loseResourceGroup tx job progress required lots=go loss(sortOn fefo lots)
  where
    loss=cancelLoss progress required(sum(map(qtyValue.lotQty)lots))
    go _ []=pure()
    go remaining(lot:rest)=do
      let quantity=min remaining(qtyValue(lotQty lot))
      losePhysical tx job lot quantity
      go(remaining-quantity)rest

-- Cached sufficient statistics for the shipped input load shapes: unit-weight
-- resources and at most one other unit weight h (currently Parts, h=250).
-- Typed stores are exclusive to their resource; unrestricted stores can accept
-- all resources. A heavy unit cannot straddle owners, even when total free
-- weight is sufficient. All counters here are Integer, including search bounds.
data ReturnSpace = ReturnSpace
  { returnFree :: !(M.Map Owner Integer)
  , returnTyped :: !(M.Map Resource Integer)
  , returnGeneralWeight :: !Integer
  , returnGeneralSlots :: !Integer
  } deriving(Eq,Show)

-- A resource-level plan is independent of physical lot fragmentation. For each
-- resource in ID order choose the maximum quantity at the earliest destination
-- that still permits a complete allocation. The compatibility fast path above
-- deliberately retains accepted legacy layouts, which can differ by partition.
planReturnPlacement :: Inventory -> [Owner] -> M.Map Resource Integer -> Either Failure [(Resource,Owner,Integer)]
planReturnPlacement inventory candidates demand=do
  unless(all(>=0)(M.elems demand)&&all(>0)(M.elems loads))
    (Left(InvariantViolation "invalid return quantity or resource load"))
  unless(S.size nonunit<=1)
    (Left(InvariantViolation "return allocator requires unit load and at most one non-unit load class"))
  unless(all(>=0)(M.elems(returnFree initial)))
    (Left(InvariantViolation "negative return capacity"))
  unless(feasible initial demand)(Left ReturnCapacityFull)
  (remaining,_,placements)<-foldM allocateResource(demand,initial,[])(M.keys demand)
  unless(all(==0)(M.elems remaining))(Left(InvariantViolation "feasible return plan was not exhausted"))
  pure(reverse placements)
  where
    loads=M.mapWithKey(\resource _->weightOf inventory resource 1)demand
    nonunit=S.fromList[load|(resource,load)<-M.toList loads,load>1,M.findWithDefault 0 resource demand>0]
    heavy=if S.null nonunit then 1 else S.findMin nonunit
    weight resource=M.findWithDefault 0 resource loads
    -- Preserve caller priority and safely ignore repeated candidate owners.
    unique _ []=[]
    unique seen(owner:rest)
      | S.member owner seen=unique seen rest
      | otherwise=owner:unique(S.insert owner seen)rest
    allowed owner@(Owner kind _)=M.member owner(invStorage inventory)&&kind/=NaturalDeposit&&kind/=RecoveryHold
    owners=filter allowed(unique S.empty candidates)
    typed owner=storageResource=<<M.lookup owner(invStorage inventory)
    free owner=freeWeight inventory owner
    initial=ReturnSpace(M.fromList[(owner,free owner)|owner<-owners])
      (M.fromListWith(+)[(resource,free owner `div` weight resource)|owner<-owners,Just resource<-[typed owner],M.member resource loads])
      (sum[free owner|owner<-owners,typed owner==Nothing])
      (sum[free owner `div` heavy|owner<-owners,typed owner==Nothing])
    residual space quantities=[(resource,max 0(quantity-M.findWithDefault 0 resource(returnTyped space)))|(resource,quantity)<-M.toAscList quantities]
    feasible space quantities=
      let needed=residual space quantities
          total=sum[quantity*weight resource|(resource,quantity)<-needed]
          slots=sum[quantity|(resource,quantity)<-needed,weight resource>1]
      in total<=returnGeneralWeight space&&slots<=returnGeneralSlots space
    place resource owner quantity space=
      let old=M.findWithDefault 0 owner(returnFree space)
          next=old-quantity*weight resource
          changed=space{returnFree=M.insert owner next(returnFree space)}
      in case typed owner of
        Just _->changed{returnTyped=M.adjust(subtract quantity)resource(returnTyped space)}
        Nothing->changed{returnGeneralWeight=returnGeneralWeight space-quantity*weight resource
          ,returnGeneralSlots=returnGeneralSlots space+next `div` heavy-old `div` heavy}
    -- Feasible assigned quantities form a prefix: committing more to a shared
    -- owner can only lose typed slack or heavy slots; a matching typed owner
    -- changes its demand and available quantity equally. This permits binary
    -- search rather than quantity enumeration or exponential owner backtracking.
    largest low high predicate
      | low>=high=low
      | predicate middle=largest middle high predicate
      | otherwise=largest low(middle-1)predicate
      where middle=(low+high+1) `div` 2
    allocateResource current resource=foldM(allocateOwner resource)current owners
    allocateOwner resource current@(quantities,space,placements) owner
      | quantity==0 || maybe False(/=resource)(typed owner)=Right current
      | otherwise=
          let upper=min quantity(M.findWithDefault 0 owner(returnFree space) `div` weight resource)
              fits n=feasible(place resource owner n space)(M.insert resource(quantity-n)quantities)
              amount=largest 0 upper fits
          in if amount==0 then Right current else Right(M.insert resource(quantity-amount)quantities,place resource owner amount space,(resource,owner,amount):placements)
      where quantity=M.findWithDefault 0 resource quantities

returnSplitPhysical :: TxId -> Job -> Integer -> Integer -> InventoryTx ()
returnSplitPhysical tx job progress required=do
  lots<-gets(filter((==wipOwner job).lotOwner).M.elems.invLots)
  releaseJob(jobId job)
  forM_(resourceLotGroups lots)$ \(_,group)->loseResourceGroup tx job progress required group
  inventory<-get
  let survivors=filter((==wipOwner job).lotOwner)(M.elems(invLots inventory))
      demand=M.fromListWith(+)[(lotResource lot,qtyValue(lotQty lot))|lot<-survivors]
  placements<-either throwTx pure(planReturnPlacement inventory(returnDestinations job inventory)demand)
  forM_(resourceLotGroups survivors)$ \(resource,group)->do
    let destinations=[(owner,quantity)|(r,owner,quantity)<-placements,r==resource]
        physical=[(lotId lot,qtyValue(lotQty lot))|lot<-sortOn fefo group]
    move destinations physical
  where
    move [] []=pure()
    move ((owner,needed):destinations)((ident,available):lots)=do
      let amount=min needed available
      transferSelected owner[(ident,amount)]
      move(if amount==needed then destinations else (owner,needed-amount):destinations)
          (if amount==available then lots else (ident,available-amount):lots)
    move _ _=throwTx(InvariantViolation "return plan and physical survivors disagree")

-- Every caller must select the saved world's profile. No implicit default may
-- reinterpret an old checkpoint using a newer cancellation algorithm.
cancelJob :: String -> TxId -> Job -> InventoryTx Job
cancelJob ruleset tx j=do
  (_,rounding)<-either(throwTx . InvalidReference)pure(rulesetProfile ruleset)
  require(not(terminal j))AlreadyTerminal
  if jobPhase j==Running then returnPhysical rounding tx j(jobProgress j)(jobRequired j)False else releaseJob(jobId j)
  pure j {jobPhase=Cancelled,jobBlocked=Nothing,jobTerminalCount=jobTerminalCount j+1}

failExpiredJob :: TxId -> Job -> InventoryTx Job
failExpiredJob tx j=do
  require(not(terminal j))AlreadyTerminal
  -- The expired lot was already transformed by P2; only surviving physical WIP is returned.
  returnPhysical LegacyPerLot tx j 0 1 True
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

-- Independent of the self-reported WIP/reservation vectors: a snapshot must be
-- the exact recipe identified by its content fingerprint in the shipped catalog.
validateJobSnapshotCatalog :: RecipeCatalogs -> Job -> Either Failure ()
validateJobSnapshotCatalog catalogs job=case(jobRecipeSnapshot job,jobSnapshotContentId job)of
  (Nothing,Nothing)->unless(jobPhase job/=Running)(Left(InvariantViolation "running job has no catalog-bound snapshot"))
  (Just snapshot,Just digest)->do
    recipes<-maybe(Left(InvariantViolation "snapshot content ID is unknown"))Right(M.lookup digest catalogs)
    expected<-maybe(Left(InvariantViolation "snapshot recipe ID is unknown"))Right(M.lookup(jobRecipe job)recipes)
    unless(snapshot==expected)(Left(InvariantViolation "snapshot recipe differs from known content catalog"))
  _->Left(InvariantViolation "snapshot and content ID must be present together")
