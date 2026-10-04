{-# LANGUAGE BangPatterns #-}
-- Base-only test harness (plus the libraries already used by the application).
-- This model deliberately does not call Inventory's selection, weight, ledger,
-- reservation, expiry, or validation helpers. All reference arithmetic is Integer.
module InventoryTests (inventoryTests) where

import Colony.Content
import qualified Colony.Inventory as I
import Colony.Types
import Colony.Units
import Control.Monad (foldM, forM_, unless, void)
import qualified Data.Map.Strict as M
import Data.List (sortOn)
import Data.Word (Word64)
import System.CPUTime (getCPUTime)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

assert :: String -> Bool -> IO ()
assert label good = unless good (ioError (userError ("Inventory assertion failed: " ++ label)))

must :: Show e => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

eid :: Integer -> EntityId
eid = EntityId . fromInteger
untick :: SimTick -> Integer
untick (SimTick n) = toInteger n
unid :: EntityId -> Integer
unid (EntityId n) = toInteger n
at :: Integer -> SimTick
at = SimTick . fromInteger
transaction :: Integer -> TxId
transaction n = TxId 71 29 (BoundarySeq (fromInteger n)) P2 0

ownerA, ownerB, ownerZero, ownerWater :: Owner
ownerA = Owner Warehouse (eid 90001)
ownerB = Owner Pantry (eid 90002)
ownerZero = Owner MachineOutput (eid 90003)
ownerWater = Owner Tank (eid 90004)

storages :: M.Map Owner Storage
storages = M.fromList [(ownerA, Storage 6000 Nothing (eid 1)),
                      (ownerB, Storage 2000 Nothing (eid 1)),
                      (ownerZero, Storage 0 Nothing (eid 1)),
                      (ownerWater, Storage 1000 (Just Water) (eid 1))]

-- Distinct test-owned representation. Quantity, tick and ID calculations do not
-- use Qty, Word64, Int64, or any production arithmetic/selection helper.
data OLot = OLot !Resource !Integer !Owner !Integer !(Maybe Integer) !String
  deriving (Eq, Show)
data Oracle = Oracle
  { oNext :: !Integer, oLots :: !(M.Map Integer OLot)
  , oQuantity :: !(M.Map Integer (Integer,Integer,Integer))
  , oCapacity :: !(M.Map Integer (Integer,Owner,Integer))
  , oNatural :: !(M.Map Integer (Integer,Integer,Integer))
  , oDeposits :: !(M.Map Integer (String,Resource,Integer))
  , oLedger :: !(M.Map (Resource,Reason) Integer), oEntries :: !Integer
  } deriving (Eq, Show)

emptyOracle :: Oracle
emptyOracle = Oracle initialNext M.empty M.empty M.empty M.empty M.empty M.empty 0

initialNext :: Integer
initialNext = 1 + maximum [unid ident | Owner _ ident <- M.keys storages]
sourceIdent :: Integer
sourceIdent = initialNext + toInteger(length initialLots)

loads :: Content -> Resource -> Integer
loads c r = maybe (error "test content missing resource") resourceLoad (M.lookup r (contentResources c))

oracleSources :: [Reason]
oracleSources = [InitialGrant,Extraction,RecipeOutput,DemolitionRecovered,TradeReceived,AidReceived,Immigration,SpoilageOutput]

ledgerAdd :: Reason -> Resource -> Integer -> Oracle -> Oracle
ledgerAdd why r n o = o {oLedger=M.insertWith (+) (r,why) n (oLedger o),oEntries=oEntries o+1}

newLot :: Reason -> Resource -> Integer -> Owner -> Integer -> Maybe Integer -> String -> Oracle -> Oracle
newLot why r n owner born expiry provenance o =
  ledgerAdd why r n o {oNext=oNext o+1,oLots=M.insert (oNext o) (OLot r n owner born expiry provenance) (oLots o)}

stockWeight :: Content -> Owner -> Oracle -> Integer
stockWeight c owner o = sum [n * loads c r | OLot r n own _ _ _ <- M.elems (oLots o), own==owner]
capWeight :: Owner -> Oracle -> Integer
capWeight owner o = sum [n | (_,own,n) <- M.elems (oCapacity o), own==owner]
space :: Content -> Owner -> Oracle -> Integer
space c owner o = maybe 0 storageCapacity (M.lookup owner storages) - stockWeight c owner o - capWeight owner o
allows :: Content -> Owner -> Resource -> Integer -> Oracle -> Bool
allows c owner r n o = case M.lookup owner storages of
  Nothing -> False
  Just st -> maybe True (==r) (storageResource st) && n * loads c r <= space c owner o
reserved :: Integer -> Oracle -> Integer
reserved lid o = sum [n | (_,l,n) <- M.elems (oQuantity o), l==lid]

-- Construct a declarative feasible allocation from sorted, eligible stock.
allocation :: Integer -> Owner -> Resource -> Integer -> Oracle -> Maybe [(Integer,Integer)]
allocation tick owner r demand o
  | demand < 0 || demand > quantityMax = Nothing
  | sum (map snd eligible) < demand = Nothing
  | otherwise = Just (takeDemand demand eligible)
  where
    eligible = [(lid,n-reserved lid o) | (lid,OLot _ n _ _ _ _) <- ordered]
    ordered = sortOn order [(lid,l) | (lid,l@(OLot res _ own _ expiry _)) <- M.toList (oLots o),
                                     res==r, own==owner, maybe True (>tick) expiry]
    order :: (Integer,OLot) -> ((Integer,Integer),Integer,Integer)
    order (lid,OLot _ _ _ born expiry _) = (maybe (1,0) (\e -> (0,e)) expiry,born,lid)
    takeDemand _ [] = []
    takeDemand need ((lid,n):xs)
      | need<=0 = []
      | n<=0 = takeDemand need xs
      | otherwise = (lid,min n need) : takeDemand (need-min n need) xs

subtractLots :: [(Integer,Integer)] -> Oracle -> Oracle
subtractLots selected o = o {oLots=foldl reduce (oLots o) selected}
  where
    reduce lots (lid,n) = M.update (\(OLot r q own born expi p) ->
      if q==n then Nothing else Just (OLot r (q-n) own born expi p)) lid lots

moveLots :: Owner -> [(Integer,Integer)] -> Oracle -> Oracle
moveLots destination selected o = foldl move (subtractLots selected o) selected
  where
    move state (lid,n) = case M.lookup lid (oLots o) of
      Just (OLot r _ _ born expiry provenance) -> state {oNext=oNext state+1,
        oLots=M.insert (oNext state) (OLot r n destination born expiry provenance) (oLots state)}
      Nothing -> error "oracle move references absent lot"

quantityAdd :: Integer -> [(Integer,Integer)] -> Oracle -> Oracle
quantityAdd job selected o0 = foldl addOne o0 selected
  where
    addOne o (lid,n) = o {oNext=oNext o+1,oQuantity=M.insert (oNext o) (job,lid,n) (oQuantity o)}
capacityAdd :: Content -> Integer -> Owner -> Resource -> Integer -> Oracle -> Oracle
capacityAdd c job owner r n o = o {oNext=oNext o+1,
  oCapacity=M.insert (oNext o) (job,owner,n*loads c r) (oCapacity o)}
release :: Integer -> Oracle -> Oracle
release job o = o {oQuantity=M.filter (\(j,_,_)->j/=job) (oQuantity o),
  oCapacity=M.filter (\(j,_,_)->j/=job) (oCapacity o),oNatural=M.filter (\(j,_,_)->j/=job) (oNatural o)}

initialLots :: [(Resource,Integer,Owner,Integer,Maybe Integer,String)]
initialLots = [(Crops,30,ownerA,0,Just 7,"early crops"),
               (Crops,40,ownerA,1,Just 23,"late crops"),
               (Ration,50,ownerA,0,Just 60,"ration"),
               (Water,500,ownerA,0,Nothing,"water"),
               (Parts,3,ownerA,0,Nothing,"parts"),
               (Metal,70,ownerB,0,Nothing,"metal"),
               (Crops,25,ownerB,2,Just 160,"pantry crops")]

initialState :: Content -> IO (Inventory,Oracle)
initialState c = do
  let setup = do
        forM_ (M.toList storages) (uncurry I.addStorage)
        forM_ initialLots $ \(r,n,own,born,expiry,p) ->
          void (I.mintLot (transaction 0) InitialGrant Nothing r n own (at born) (fmap at expiry) p)
        void (I.addDeposit "test aquifer" Water 10000)
      seeded = foldl (\o (r,n,own,born,e,p) -> newLot InitialGrant r n own born e p o) emptyOracle initialLots
      reference = seeded {oNext=oNext seeded+1,oDeposits=M.singleton (oNext seeded) ("test aquifer",Water,10000)}
  (_,actual) <- must "inventory fixture" (I.runInventory setup (I.emptyInventory c))
  pure (actual,reference)

data Action
  = Mint Owner Resource Integer (Maybe Integer)
  | ReserveQ Integer Owner Resource Integer
  | ReserveC Integer Owner Resource Integer
  | Delivery Integer Owner Owner Resource Integer
  | Release Integer
  | Move Owner Owner Resource Integer
  | MoveReserved Integer Owner Owner
  | Consume Owner Resource Integer
  | Expire
  | ReserveN Integer Integer
  | Extract Integer Owner
  | RollbackMint Owner Resource Integer
  | RollbackReserve Integer Owner Resource Integer
  deriving (Eq,Show)

kind :: Action -> String
kind a = case a of
  Mint{} -> "mint"; ReserveQ{} -> "quantity"; ReserveC{} -> "capacity"
  Delivery{} -> "delivery"; Release{} -> "release"; Move{} -> "move"
  MoveReserved{} -> "move_reserved"; Consume{} -> "consume"; Expire -> "expire"
  ReserveN{} -> "natural_reserve"; Extract{} -> "extract"
  RollbackMint{} -> "rollback_mint"; RollbackReserve{} -> "rollback_reserve"

actualAction :: Integer -> Action -> I.InventoryTx ()
actualAction tick action = case action of
  Mint owner r n expiry -> void (I.mintLot tx InitialGrant Nothing r n owner (at tick) (fmap at expiry) "generated")
  ReserveQ job owner r n -> I.reserveQuantity (at tick) (eid job) owner r n
  ReserveC job owner r n -> I.reserveCapacity (eid job) owner r n
  Delivery job src dst r n -> I.reserveDelivery (at tick) (eid job) src dst r n
  Release job -> I.releaseJob (eid job)
  Move src dst r n -> I.moveFree (at tick) src dst r n
  MoveReserved job src dst -> I.moveReserved (eid job) src dst
  Consume owner r n -> I.consumeFree tx RecipeInput Nothing (at tick) owner r n
  Expire -> void (I.expireInventory tx (at tick))
  ReserveN job n -> I.reserveNatural (eid job) (eid sourceIdent) n
  Extract job dst -> I.extractReserved tx (eid job) dst (at tick)
  RollbackMint owner r n -> do
    void (I.mintLot tx AidReceived Nothing r n owner (at tick) Nothing "rollback")
    I.throwTx TargetGone
  RollbackReserve job owner r n -> do
    I.reserveQuantity (at tick) (eid job) owner r n
    I.throwTx TargetGone
  where tx=transaction tick

oracleAction :: Content -> Integer -> Action -> Oracle -> Maybe Oracle
oracleAction c tick action o = case action of
  Mint own r n e | allows c own r n o -> Just (newLot InitialGrant r n own tick e "generated" o)
                | otherwise -> Nothing
  ReserveQ job own r n -> quantityAdd job <$> allocation tick own r n o <*> pure o
  ReserveC job own r n | allows c own r n o -> Just (capacityAdd c job own r n o)
                      | otherwise -> Nothing
  Delivery job src dst r n | allows c dst r n o -> do
    selected <- allocation tick src r n o
    pure (capacityAdd c job dst r n (quantityAdd job selected o))
                          | otherwise -> Nothing
  Release job -> Just (release job o)
  Move src dst r n | allows c dst r n o -> do
    selected <- allocation tick src r n o
    pure (moveLots dst selected o)
                  | otherwise -> Nothing
  MoveReserved job src dst -> do
    let selected = [(lid,n) | (j,lid,n) <- M.elems (oQuantity o), j==job,
                     Just (OLot _ _ owner _ _ _) <- [M.lookup lid (oLots o)], owner==src]
        ids = [rid | (rid,(j,lid,_)) <- M.toList (oQuantity o),j==job,lid `elem` map fst selected]
        without = o {oQuantity=foldr M.delete (oQuantity o) ids,
          oCapacity=M.filter (\(j,own,_)->j/=job || own/=dst) (oCapacity o)}
        weights = [(r,n) | (lid,n)<-selected, Just (OLot r _ _ _ _ _) <- [M.lookup lid (oLots o)]]
        st = M.lookup dst storages
        fits = maybe False (\s -> all (\(r,_)->maybe True (==r) (storageResource s)) weights &&
                              sum [n*loads c r | (r,n)<-weights] <= space c dst without) st
    if null selected || not fits then Nothing else Just (moveLots dst selected without)
  Consume own r n -> do
    selected <- allocation tick own r n o
    pure (ledgerAdd RecipeInput r n (subtractLots selected o))
  Expire -> Just (foldl spoil o [(lid,l) | (lid,l@(OLot _ _ _ _ expiry _))<-M.toList (oLots o),maybe False (<=tick) expiry])
  ReserveN job n -> case M.lookup sourceIdent (oDeposits o) of
    Just (_,_,available) | n + sum [v | (_,source,v)<-M.elems(oNatural o),source==sourceIdent] <= available ->
      Just o {oNext=oNext o+1,oNatural=M.insert (oNext o) (job,sourceIdent,n) (oNatural o)}
    _ -> Nothing
  Extract job dst -> do
    let refs=[(rid,source,n) | (rid,(j,source,n))<-M.toList(oNatural o),j==job]
        without=o {oCapacity=M.filter (\(j,_,_)->j/=job) (oCapacity o)}
        amount=sum [n | (_,_,n)<-refs]
    if null refs || not (allows c dst Water amount without) then Nothing else pure (foldl extract without refs)
    where
      extract state (rid,source,n) = case M.lookup source (oDeposits state) of
        Just (k,r,remaining) -> newLot Extraction r n dst tick Nothing ("extraction:"++show (eid job))
          state {oDeposits=M.insert source (k,r,remaining-n) (oDeposits state),oNatural=M.delete rid (oNatural state)}
        Nothing -> error "oracle natural source absent"
  RollbackMint{} -> Nothing
  RollbackReserve{} -> Nothing
  where
    spoil state (lid,OLot r n own _ _ _) =
      let removed = ledgerAdd SpoilageInput r n state {oLots=M.delete lid (oLots state),
            oQuantity=M.filter (\(_,ref,_)->ref/=lid) (oQuantity state)}
          waste = n * loads c r
          allowedWaste = maybe False (\s -> maybe True (==Waste) (storageResource s)) (M.lookup own storages)
          fit = if allowedWaste then max 0 (min waste (space c own removed `div` loads c Waste)) else 0
          stored = if fit==0 then removed else newLot SpoilageOutput Waste fit own tick Nothing "spoilage" removed
      in if fit==waste then stored else ledgerAdd SpoilageDisposal Waste (waste-fit) (ledgerAdd SpoilageOutput Waste (waste-fit) stored)

-- Projection is observation only; it is never used to advance the oracle.
projection :: Inventory -> Oracle
projection s = Oracle (toInteger (invNextId s))
  (M.fromList [(unid k,OLot (lotResource l) (qtyValue(lotQty l)) (lotOwner l) (untick(lotBorn l)) (fmap untick(lotExpires l)) (lotProvenance l)) | (k,l)<-M.toList(invLots s)])
  (M.fromList [(unid k,(unid(quantityJob r),unid(quantityLot r),qtyValue(quantityAmount r))) | (k,r)<-M.toList(invQuantity s)])
  (M.fromList [(unid k,(unid(capacityJob r),capacityOwner r,capacityWeight r)) | (k,r)<-M.toList(invCapacity s)])
  (M.fromList [(unid k,(unid(naturalJob r),unid(naturalSource r),qtyValue(naturalAmount r))) | (k,r)<-M.toList(invNatural s)])
  (M.fromList [(unid k,(depositKind d,depositResource d,qtyValue(depositQty d))) | (k,d)<-M.toList(invDeposits s)])
  (invLedger s) (toInteger(length(invRecentLedger s)))

checkState :: Content -> String -> Inventory -> Oracle -> IO ()
checkState c context s o = do
  let observed=projection s
  assert (context++" exact Integer oracle state\nexpected="++show o++"\nactual="++show observed)
    (observed == o {oEntries=min 256 (oEntries o)})
  assert (context++" storages unchanged") (invStorage s==storages)
  assert (context++" ledger bounded") (length(invRecentLedger s)<=256)
  forM_ allResources $ \r -> do
    let actual=sum [qtyValue(lotQty l) | l<-M.elems(invLots s),lotResource l==r]
        declared=sum [if why `elem` oracleSources then n else -n | ((res,why),n)<-M.toList(invLedger s),res==r]
    assert (context++" independent conservation "++show r) (actual==declared && actual>=0 && actual<=quantityMax)
  forM_ (M.toList storages) $ \(owner,st) -> do
    let held=sum [qtyValue(lotQty l)*loads c (lotResource l) | l<-M.elems(invLots s),lotOwner l==owner]
        promised=sum [capacityWeight r | r<-M.elems(invCapacity s),capacityOwner r==owner]
    assert (context++" independent owner capacity "++show owner) (held+promised<=storageCapacity st)
  forM_ (M.toList(invLots s)) $ \(lid,l) -> do
    let reservedAmount=sum [qtyValue(quantityAmount r) | r<-M.elems(invQuantity s),quantityLot r==lid]
    assert (context++" independent quantity overreservation") (reservedAmount<=qtyValue(lotQty l))
  assert (context++" no dangling quantity reference") (all (\r->M.member(quantityLot r)(invLots s)) (M.elems(invQuantity s)))

-- Park-Miller generator uses Integer, so replay does not depend on machine width.
nextRandom :: Integer -> Integer
nextRandom x = (48271*x) `mod` 2147483647
choose :: Integer -> [a] -> a
choose n xs = xs !! fromInteger (n `mod` toInteger(length xs))

generate :: Integer -> Integer -> Oracle -> (Integer,Action)
generate seed tick o = (last rs,action)
  where
    rs=take 8 (tail(iterate nextRandom seed))
    a=rs!!0; b=rs!!1; d=rs!!2; e=rs!!3; f=rs!!4; g=rs!!5
    own=choose b [ownerA,ownerA,ownerB,ownerWater,ownerZero]
    dst=choose d (filter (/=own) [ownerA,ownerB,ownerWater,ownerZero])
    resource=choose e [Crops,Ration,Water,Metal,Parts,Waste]
    n=1+f `mod` 50
    job=100000+g `mod` 8
    qjobs=[(j,owner) | (j,lid,_)<-M.elems(oQuantity o),Just (OLot _ _ owner _ _ _)<-[M.lookup lid(oLots o)]]
    (activeJob,activeOwner)=if null qjobs then (job,own) else choose b qjobs
    activeNatural=if M.null(oNatural o) then job else let (j,_,_)=choose b (M.elems(oNatural o)) in j
    expiry=if resource `elem` [Crops,Ration] then Just(tick+1+d `mod` 40) else Nothing
    action=case a `mod` 16 of
      0 -> Mint own resource n expiry
      1 -> Mint ownerA resource n expiry
      2 -> ReserveQ job own resource n
      3 -> ReserveC job own resource n
      4 -> Delivery job own dst resource n
      5 -> Release activeJob
      6 -> Move own dst resource n
      7 -> MoveReserved activeJob activeOwner (choose d (filter (/=activeOwner) [ownerA,ownerB,ownerWater,ownerZero]))
      8 -> Consume own resource n
      9 -> Expire
      10 -> ReserveN job n
      11 -> Extract activeNatural dst
      12 -> RollbackMint own resource n
      13 -> RollbackReserve job own resource n
      14 -> ReserveQ job ownerA Water n
      _ -> Delivery job ownerA ownerB Water n

data Stats = Stats !Integer !Integer !(M.Map String (Integer,Integer)) deriving Show
addStat :: Bool -> Action -> Stats -> Stats
addStat success action (Stats yes no counts) = Stats (yes+if success then 1 else 0) (no+if success then 0 else 1)
  (M.insertWith (\(a,b) (x,y)->(a+x,b+y)) (kind action) (if success then (1,0) else (0,1)) counts)
combine :: Stats -> Stats -> Stats
combine (Stats a b xs) (Stats c d ys) = Stats (a+c) (b+d) (M.unionWith (\(w,x)(y,z)->(w+y,x+z)) xs ys)

traceOnce :: Content -> Integer -> Integer -> (Inventory,Oracle) -> IO (Inventory,[Action],Stats)
traceOnce c seed count (initial,reference) = loop 1 seed initial reference [] (Stats 0 0 M.empty)
  where
    loop !index !random !state !model !history !stats
      | index>count = pure (state,reverse history,stats)
      | otherwise = do
          let (random',action)=generate random index model
              expected=oracleAction c index action model
              actual=I.runInventory (actualAction index action) state
              context="seed="++show seed++" step="++show index++" action="++show action
              failedWhy=case actual of Left why -> show why; Right _ -> "accepted"
          (nextState,nextModel,accepted) <- case (expected,actual) of
            (Nothing,Left _) -> do
              -- runInventory exposes no replacement state on Left. Subsequent
              -- operations use the identical checkpoint, including IDs/history.
              assert (context++" failed retry differs") (I.runInventory (actualAction index action) state==actual)
              pure (state,model,False)
            (Just expectedState,Right (_,actualState)) -> pure (actualState,expectedState,True)
            _ -> ioError (userError (context++" model acceptance mismatch: "++failedWhy++"\nreplay prefix="++show(reverse(action:history))))
          checkState c context nextState nextModel
          loop (index+1) random' nextState nextModel (action:history) (addStat accepted action stats)

replay :: Inventory -> [Action] -> Inventory
replay = go 1
  where
    go _ s [] = s
    go tick s (a:as) = go (tick+1) (case I.runInventory (actualAction tick a) s of Left _ -> s; Right (_,after)->after) as

parameter :: String -> Integer -> IO Integer
parameter key fallback = do
  value <- lookupEnv key
  case value of
    Nothing -> pure fallback
    Just raw -> case readMaybe raw of
      Just n | n>0 -> pure n
      _ -> ioError(userError(key++" must be a positive Integer"))

inventoryTests :: Content -> IO ()
inventoryTests c = do
  directedTests c
  sequenceCount <- parameter "INVENTORY_TEST_SEQUENCES" 10000
  steps <- parameter "INVENTORY_TEST_STEPS" 120
  startSeed <- parameter "INVENTORY_TEST_SEED" 1
  fixture <- initialState c
  checkState c "initial" (fst fixture) (snd fixture)
  before <- getCPUTime
  let run !total sequenceIndex = do
        let seed=1+(startSeed+sequenceIndex-2) `mod` 2147483646
        (end,actions,stats) <- traceOnce c seed steps fixture
        assert ("deterministic exact-state replay seed="++show seed) (replay (fst fixture) actions==end)
        pure (combine total stats)
  Stats succeeded rejected counts <- foldM run (Stats 0 0 M.empty) [1..sequenceCount]
  after <- getCPUTime
  putStrLn ("inventory_property_stats sequences="++show sequenceCount++" steps_per_sequence="++show steps++
    " attempted="++show(sequenceCount*steps)++" replayed="++show(sequenceCount*steps)++
    " succeeded="++show succeeded++" rejected="++show rejected++" start_seed="++show startSeed++
    " cpu_picoseconds="++show(after-before))
  forM_ (M.toList counts) $ \(name,(yes,no))->putStrLn("inventory_action_stats action="++name++" success="++show yes++" rejected="++show no)
  putStrLn "PASS Inventory: directed adversarial fixtures and independent Integer state-machine traces with exact replay"

-- Focused counterexamples are retained even when generated traces also hit them.
directedTests :: Content -> IO ()
directedTests c = do
  let tx=transaction 0; job1=eid 7001; job2=eid 7002
      empty=I.emptyInventory c
      run label action state = must label (I.runInventory action state)
      reject label failure action state = do
        assert (label++" exact failure") (I.runInventory action state==Left failure)
        -- No (result,newState) escapes failure; explicit commit-or-retain policy
        -- must retain every field, rather than only total resource quantities.
        let committed=case I.runInventory action state of Left _ -> state;Right(_,after)->after
        assert (label++" exact checkpoint retention") (committed==state)
      stock r n expiry = do
        I.addStorage ownerA (Storage quantityMax Nothing (eid 1))
        I.addStorage ownerB (Storage quantityMax Nothing (eid 1))
        I.addStorage ownerZero (Storage 0 Nothing (eid 1))
        I.mintLot tx InitialGrant Nothing r n ownerA (at 3) (fmap at expiry) "fixture"
  (lid,water) <- run "single-stock fixture" (stock Water 100 Nothing) empty
  (_,oneReservation) <- run "first same-stock reservation" (I.reserveQuantity (at 4) job1 ownerA Water 60) water
  reject "competing 60+60 cannot reserve stock100" MissingStock (I.reserveQuantity (at 4) job2 ownerA Water 60) oneReservation
  (_,fullyReserved) <- run "exact remaining stock40" (I.reserveQuantity (at 4) job2 ownerA Water 40) oneReservation
  assert "reservations do not create or move stock" (invLots fullyReserved==invLots water && invLedger fullyReserved==invLedger water)
  assert "quantity rights have no capacity footprint" (M.null(invCapacity fullyReserved) && I.heldWeight fullyReserved ownerA==100)
  reject "reserved stock cannot be consumed free" MissingStock (I.consumeFree tx LivingConsumed Nothing (at 4) ownerA Water 1) fullyReserved
  (_,released) <- run "release one job" (I.releaseJob job1) fullyReserved
  assert "release only selected job" (all ((==job2).quantityJob) (M.elems(invQuantity released)))
  reject "failed destination undoes prior quantity reservation and ID" NoCapacity (I.reserveDelivery (at 4) job1 ownerA ownerZero Water 50) water
  (_,capacityOnly) <- run "capacity only" (I.reserveCapacity job1 ownerB Water 100) water
  assert "capacity is not quantity or physical stock" (invLots capacityOnly==invLots water && M.null(invQuantity capacityOnly) && invLedger capacityOnly==invLedger water)
  assert "capacity consumes exact weight" (I.freeWeight capacityOnly ownerB==quantityMax-100)
  (_,promised) <- run "delivery reservation" (I.reserveDelivery (at 4) job1 ownerA ownerB Water 75) water
  (_,delivered) <- run "atomic reserved delivery" (I.moveReserved job1 ownerA ownerB) promised
  assert "delivery clears its quantity and target-capacity rights" (M.null(invQuantity delivered) && M.null(invCapacity delivered))
  assert "delivery source/sink ledger unchanged" (invLedger delivered==invLedger water && invRecentLedger delivered==invRecentLedger water)
  assert "delivery preserves full lot identity metadata except ID owner quantity"
    (all (\l->lotBorn l==at 3 && lotExpires l==Nothing && lotProvenance l=="fixture") (M.elems(invLots delivered)))
  assert "delivery exact distribution" (I.heldWeight delivered ownerA==25 && I.heldWeight delivered ownerB==75)
  reject "completion cannot repeat" MissingReservation (I.moveReserved job1 ownerA ownerB) delivered

  let recovery=Owner RecoveryHold(eid 777)
      recoveryDenied=InvalidReference "RecoveryHold admits forced recovery only"
  (_,withRecovery) <- run "recovery hold fixture" (I.addStorage recovery(Storage 0 Nothing(eid 1))) water
  reject "ordinary mint cannot enter RecoveryHold" recoveryDenied
    (void(I.mintLot tx AidReceived Nothing Water 1 recovery(at 4)Nothing"ordinary")) withRecovery
  reject "ordinary transfer cannot enter RecoveryHold" recoveryDenied (I.moveFree(at 4)ownerA recovery Water 1) withRecovery
  reject "ordinary capacity cannot reserve RecoveryHold" recoveryDenied (I.reserveCapacity job1 recovery Water 1) withRecovery
  (_,forcedRecovery) <- run "forced recovery explicit path" (I.transferRecovered recovery [(lid,60)]) withRecovery
  assert "forced recovery preserves authoritative stock without capacity fiction"
    (I.heldWeight forcedRecovery recovery==60 && invLedger forcedRecovery==invLedger water)
  assert "forced recovery keeps lot age and provenance" (all (\l->lotBorn l==at 3 && lotProvenance l=="fixture") (M.elems(invLots forcedRecovery)))
  (_,recoveredOut) <- run "recovery output allowed" (I.moveFree(at 4)recovery ownerB Water 60) forcedRecovery
  assert "recovery output moves existing assets" (I.heldWeight recoveredOut recovery==0 && I.heldWeight recoveredOut ownerB==60 && invLedger recoveredOut==invLedger water)

  ((early,late,noExpiry,olderTie,newerTie),fefoState) <- run "FEFO fixture" (do
    I.addStorage ownerA (Storage 1000 Nothing (eid 1))
    I.addStorage ownerB (Storage 1000 Nothing (eid 1))
    a<-I.mintLot tx InitialGrant Nothing Crops 10 ownerA (at 5) (Just(at 10)) "early"
    b<-I.mintLot tx InitialGrant Nothing Crops 10 ownerA (at 1) (Just(at 20)) "late"
    z<-I.mintLot tx InitialGrant Nothing Crops 10 ownerA (at 0) Nothing "no expiry"
    d<-I.mintLot tx InitialGrant Nothing Crops 10 ownerA (at 2) (Just(at 20)) "tie older ID"
    e<-I.mintLot tx InitialGrant Nothing Crops 10 ownerA (at 2) (Just(at 20)) "tie newer ID"
    pure(a,b,z,d,e)) empty
  (selected,_) <- run "FEFO select" (I.selectFree (at 9) ownerA Crops 45) fefoState
  assert "FEFO expiry then born then ID; no expiry last" (selected==[(early,10),(late,10),(olderTie,10),(newerTie,10),(noExpiry,5)])
  (expiryBoundary,_) <- run "expiry exact boundary" (I.selectFree (at 10) ownerA Crops 10) fefoState
  assert "expiresAt <= tick unusable before expiry mutation" (expiryBoundary==[(late,10)])
  (_,movedFood) <- run "food transfer" (I.moveFree (at 9) ownerA ownerB Crops 7) fefoState
  assert "transfer retains food age expiry provenance" ([(lotBorn l,lotExpires l,lotProvenance l,qtyValue(lotQty l)) | l<-M.elems(invLots movedFood),lotOwner l==ownerB]==[(at 5,Just(at 10),"early",7)])
  assert "split original keeps remainder metadata" (fmap (\l->(qtyValue(lotQty l),lotBorn l,lotExpires l,lotProvenance l)) (M.lookup early(invLots movedFood))==Just(3,at 5,Just(at 10),"early"))

  (foodId,food) <- run "expiry reserved fixture" (stock Crops 100 (Just 10)) empty
  (_,reservedFood) <- run "reserve expiring food" (do
    I.reserveDelivery (at 9) job1 ownerA ownerB Crops 80
    source <- I.addDeposit "expiry cleanup source" Water 50
    I.reserveNatural job1 source 10) food
  (affected,expired) <- run "expire exact tick" (I.expireInventory tx (at 10)) reservedFood
  assert "expiry returns affected job" (job1 `elem` affected)
  assert "expiry removes food and dangling quantity refs" (M.notMember foodId(invLots expired) && M.null(invQuantity expired))
  assert "expiry counts each side once" (M.lookup (Crops,SpoilageInput)(invLedger expired)==Just 100 && M.lookup(Waste,SpoilageOutput)(invLedger expired)==Just 100)
  assert "expiry conserves transformed food weight" (sum[qtyValue(lotQty l)|l<-M.elems(invLots expired),lotResource l==Waste]==100*loads c Crops)
  (again,expiredAgain) <- run "expiry is idempotent" (I.expireInventory tx (at 10)) expired
  assert "second expiry changes nothing" (null again && expiredAgain==expired)
  (_,cleaned) <- run "caller performs affected job cleanup" (mapM_ I.releaseJob affected) expired
  assert "job cleanup clears remaining capacity refs" (M.null(invQuantity cleaned) && M.null(invCapacity cleaned) && M.null(invNatural cleaned))
  let typed=Owner Pantry(eid 999)
  (_,typedFood) <- run "typed food owner fixture" (do
    I.addStorage typed(Storage 100 (Just Crops)(eid 1))
    void(I.mintLot tx InitialGrant Nothing Crops 20 typed(at 0)(Just(at 2))"typed food")) empty
  (_,typedExpired) <- run "typed owner cannot hold Waste; disposal succeeds" (I.expireInventory tx(at 2)) typedFood
  assert "typed-store spoilage generates and disposes exactly once" (M.null(invLots typedExpired) && M.lookup(Waste,SpoilageOutput)(invLedger typedExpired)==Just 20 && M.lookup(Waste,SpoilageDisposal)(invLedger typedExpired)==Just 20)

  (deposit,natural) <- run "natural source fixture" (do
    I.addStorage ownerA(Storage 1000 Nothing(eid 1))
    I.addStorage ownerZero(Storage 0 Nothing(eid 1))
    I.addDeposit "aquifer" Water 100) empty
  (_,naturalReserved) <- run "natural reservation" (I.reserveNatural job1 deposit 75) natural
  assert "natural rights not stock or extraction" (M.null(invLots naturalReserved) && M.null(invLedger naturalReserved))
  reject "natural same-source competition" MissingStock (I.reserveNatural job2 deposit 26) naturalReserved
  reject "failed extraction restores natural source and reservation" NoCapacity (I.extractReserved tx job1 ownerZero(at 4)) naturalReserved
  (_,extracted) <- run "extract reserved source" (I.extractReserved tx job1 ownerA(at 4)) naturalReserved
  assert "natural output exactly once" (fmap (qtyValue.depositQty)(M.lookup deposit(invDeposits extracted))==Just 25 && M.lookup(Water,Extraction)(invLedger extracted)==Just 75 && M.null(invNatural extracted))
  reject "natural completion cannot repeat" MissingReservation (I.extractReserved tx job1 ownerA(at 4)) extracted

  reject "multi-stage rollback includes source ledger IDs reservations" TargetGone (do
    I.reserveQuantity (at 4) job1 ownerA Water 10
    I.reserveCapacity job1 ownerB Water 10
    void(I.addDeposit "temporary" Ore 55)
    void(I.mintLot tx AidReceived Nothing Metal 10 ownerB(at 4)Nothing"temporary")
    I.throwTx TargetGone :: I.InventoryTx ()) water
  forM_ [-1,0] $ \bad ->
    reject ("bad mint quantity "++show bad) InvalidQuantity (void(I.mintLot tx InitialGrant Nothing Water bad ownerA(at 0)Nothing"bad")) water
  assert "quantity above maximum rejected" (case I.runInventory (void(I.mintLot tx InitialGrant Nothing Water (quantityMax+1) ownerA(at 0)Nothing"bad")) water of Left _ -> True;_ -> False)
  forM_ [-1,0] $ \bad -> do
    reject "nonpositive quantity reservation" InvalidQuantity (I.reserveQuantity (at 4) job1 ownerA Water bad) water
    reject "nonpositive capacity reservation" InvalidQuantity (I.reserveCapacity job1 ownerB Water bad) water
  reject "sink cannot mint" InvalidQuantity (void(I.mintLot tx LivingConsumed Nothing Water 1 ownerA(at 0)Nothing"bad")) water
  reject "source cannot consume" InvalidQuantity (I.consumeFree tx InitialGrant Nothing(at 4)ownerA Water 1) water
  reject "nonunit load multiplication has no machine-integer wrap" NoCapacity (void(I.mintLot tx AidReceived Nothing Tools quantityMax ownerB(at 0)Nothing"huge weight")) water

  (_,maxState) <- run "quantity upper bound fixture" (stock Water quantityMax Nothing) empty
  (_,lessPhysical) <- run "consume frees one but not cumulative counter" (I.consumeFree tx LivingConsumed Nothing(at 4)ownerA Water 1) maxState
  reject "cumulative source bound cannot wrap" InvalidQuantity (void(I.mintLot tx InitialGrant Nothing Water 1 ownerA(at 4)Nothing"overflow")) lessPhysical
  assert "ledger still upper bound after rejection" (M.lookup(Water,InitialGrant)(invLedger lessPhysical)==Just quantityMax)
  assert "aggregate resource bound across reasons" (case I.runInventory (void(I.mintLot tx AidReceived Nothing Water 1 ownerB(at 4)Nothing"aggregate overflow")) maxState of Left(InvariantViolation _)->True;_->False)
  let lastCounter=water {invNextId=maxBound :: Word64}
  reject "ID cannot wrap" CounterOverflow (I.reserveCapacity job1 ownerB Water 1) lastCounter
  let penultimate=water {invNextId=maxBound-1 :: Word64}
  (_,lastAllocated) <- run "last available ID" (I.reserveCapacity job1 ownerB Water 1) penultimate
  assert "last counter allocated without wrap" (invNextId lastAllocated==maxBound)
  reject "subsequent allocation at limit" CounterOverflow (I.reserveCapacity job2 ownerB Water 1) lastAllocated

  (_,historyStart) <- run "history fixture" (I.addStorage ownerA(Storage 1 Nothing(eid 1))) empty
  historyEnd <- foldM (\s n -> snd <$> run "bounded ledger cycle" (do
    void(I.mintLot(transaction n)InitialGrant Nothing Water 1 ownerA(at n)Nothing"history")
    I.consumeFree(transaction n)LivingConsumed Nothing(at n)ownerA Water 1) s) historyStart [1..600]
  assert "history exactly capped256 after1200 entries" (length(invRecentLedger historyEnd)==256)
  assert "bounded history retains complete cumulative ledger" (invLedger historyEnd==M.fromList[((Water,InitialGrant),600),((Water,LivingConsumed),600)] && M.null(invLots historyEnd))
  assert "recent history newest first" (case invRecentLedger historyEnd of e:_->ledgerTx e==transaction 600 && ledgerReason e==LivingConsumed;_->False)
  let invalid label state = assert ("validator rejects "++label)
        (case I.validateInventory state of Left _ -> True; Right _ -> False)
  invalid "counter below allocated identifiers" water {invNextId=1}
  invalid "missing load metadata" water {invLoad=M.delete Water(invLoad water)}
  forM_ [0,-1,quantityMax+1] $ \bad ->
    invalid "invalid load metadata" water {invLoad=M.insert Water bad(invLoad water)}
  invalid "missing shelf metadata" water {invShelf=M.delete Water(invShelf water)}
  invalid "lot record/key mismatch" water {invLots=M.adjust (\l->l {lotId=eid 1}) lid(invLots water)}
  invalid "zero physical lot" water {invLots=M.adjust (\l->l {lotQty=zeroQty}) lid(invLots water)}
  invalid "dangling owner" water {invStorage=M.delete ownerA(invStorage water)}
  invalid "owner resource restriction" water {invStorage=M.adjust (\st->st {storageResource=Just Metal}) ownerA(invStorage water)}
  invalid "owner overcapacity" water {invStorage=M.adjust (\st->st {storageCapacity=99}) ownerA(invStorage water)}
  tooMuch <- must "overreservation quantity" (mkQty 101)
  invalid "quantity overreservation" oneReservation {invQuantity=M.map (\r->r {quantityAmount=tooMuch}) (invQuantity oneReservation)}
  invalid "quantity dangling reference" oneReservation {invQuantity=M.map (\r->r {quantityLot=eid 1}) (invQuantity oneReservation)}
  invalid "negative capacity reservation" capacityOnly {invCapacity=M.map (\r->r {capacityWeight=(-1)}) (invCapacity capacityOnly)}
  invalid "natural record/key mismatch" naturalReserved {invNatural=M.map (\r->r {naturalReservationId=eid 1}) (invNatural naturalReserved)}
  invalid "natural source key mismatch" natural {invDeposits=M.map (\d->d {depositId=eid 1}) (invDeposits natural)}
  invalid "natural overreservation" naturalReserved {invNatural=M.map (\r->r {naturalAmount=tooMuch}) (invNatural naturalReserved)}
  invalid "ledger quantity overflow" water {invLedger=M.insert (Water,InitialGrant)(quantityMax+1)(invLedger water)}
  invalid "conservation discrepancy" water {invLedger=M.insert (Water,InitialGrant)101(invLedger water)}
  invalid "resource-specific reason" water {invLedger=M.insert (Crops,LivingConsumed)0(invLedger water)}
  invalid "uncapped ledger history" water {invRecentLedger=replicate 257(head(invRecentLedger water))}
  assert "fixture source lot used" (M.member lid(invLots water))
  putStrLn "inventory_directed_stats competing_reservations=pass rollback=pass transfer_age=pass expiry=pass typed_spoilage_disposal=pass natural_exactly_once=pass arithmetic_bounds=pass history_entries_generated=1200 history_retained=256"
