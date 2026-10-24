{-# LANGUAGE TupleSections #-}

module Colony.Inventory where

import Colony.Content
import Colony.Types
import Colony.Units
import Control.Monad (forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Maybe (isJust)

type InventoryTx a = StateT Inventory (Either Failure) a

throwTx :: Failure -> InventoryTx a
throwTx = lift . Left

checked :: Integer -> InventoryTx (Qty StockUnit)
checked = either (const (throwTx InvalidQuantity)) pure . mkQty

require :: Bool -> Failure -> InventoryTx ()
require b f = unless b (throwTx f)

emptyInventory :: Content -> Inventory
emptyInventory c =
  Inventory
    1
    M.empty
    M.empty
    M.empty
    M.empty
    M.empty
    M.empty
    M.empty
    []
    (M.map resourceLoad (contentResources c))
    (M.map (fmap fromInteger . resourceShelfLife) (contentResources c))

-- The StateT runs against a private value; neither intermediate deltas nor events escape.
runInventory :: InventoryTx a -> Inventory -> Either Failure (a, Inventory)
runInventory action before = do
  (a, after) <- runStateT action before
  validateInventory after
  pure (a, after)

freshId :: InventoryTx EntityId
freshId = do
  n <- gets invNextId
  require (n < maxBound) CounterOverflow
  modify' $ \s -> s {invNextId = n + 1}
  pure (EntityId n)

addStorage :: Owner -> Storage -> InventoryTx ()
addStorage owner storage = do
  require (storageCapacity storage >= 0 && storageCapacity storage <= quantityMax) InvalidQuantity
  exists <- gets (M.member owner . invStorage)
  require (not exists) (InvalidReference "duplicate storage")
  s <- get
  let Owner _ ownerEntity@(EntityId ownerId) = owner
      EntityId colonyId = storageColony storage
  require (ownerEntity `notElem` inventoryAssetIds s) (InvalidReference "storage ID collides with asset/reservation/deposit")
  require (ownerId /= colonyId) (InvalidReference "storage ID collides with colony")
  require (max ownerId colonyId < maxBound) CounterOverflow
  modify' $ \next -> next {invStorage = M.insert owner storage (invStorage next), invNextId = max (invNextId next) (max ownerId colonyId + 1)}

weightOf :: Inventory -> Resource -> Integer -> Integer
weightOf s r q = q * M.findWithDefault 0 r (invLoad s)

heldWeight :: Inventory -> Owner -> Integer
heldWeight s owner = sum [weightOf s (lotResource l) (qtyValue (lotQty l)) | l <- M.elems (invLots s), lotOwner l == owner]

reservedWeight :: Inventory -> Owner -> Integer
reservedWeight s owner = sum [capacityWeight r | r <- M.elems (invCapacity s), capacityOwner r == owner]

freeWeight :: Inventory -> Owner -> Integer
freeWeight s owner = maybe 0 (\st -> storageCapacity st - heldWeight s owner - reservedWeight s owner) (M.lookup owner (invStorage s))

ensureSpace :: Owner -> Resource -> Integer -> InventoryTx ()
ensureSpace = ensureSpaceWith False

-- True is reserved for forced expiry/disaster recovery; ordinary calls cannot enter RecoveryHold.
ensureSpaceWith :: Bool -> Owner -> Resource -> Integer -> InventoryTx ()
ensureSpaceWith forced owner@(Owner kind _) resource q = do
  s <- get
  st <- maybe (throwTx MissingOwner) pure (M.lookup owner (invStorage s))
  require (maybe True (== resource) (storageResource st)) ResourceMismatch
  require (kind /= NaturalDeposit) ResourceMismatch
  require (kind /= RecoveryHold || forced) (InvalidReference "RecoveryHold admits forced recovery only")
  require (kind == RecoveryHold || freeWeight s owner >= weightOf s resource q) NoCapacity

record :: TxId -> Reason -> Maybe EntityId -> Resource -> Integer -> Maybe Owner -> Maybe Owner -> InventoryTx ()
record tx reason = recordDetailed tx reason Nothing

recordDetailed :: TxId -> Reason -> Maybe LedgerSubreason -> Maybe EntityId -> Resource -> Integer -> Maybe Owner -> Maybe Owner -> InventoryTx ()
recordDetailed tx reason detail job resource q from to = do
  _ <- checked q
  s <- get
  let total = M.findWithDefault 0 (resource, reason) (invLedger s) + q
  _ <- checked total
  put
    s
      { invLedger = M.insert (resource, reason) total (invLedger s),
        invRecentLedger = take 256 (LedgerEntry tx resource reason q from to job detail : invRecentLedger s)
      }

mintLot :: TxId -> Reason -> Maybe EntityId -> Resource -> Integer -> Owner -> SimTick -> Maybe SimTick -> String -> InventoryTx EntityId
mintLot = mintLotWith False

mintLotWith :: Bool -> TxId -> Reason -> Maybe EntityId -> Resource -> Integer -> Owner -> SimTick -> Maybe SimTick -> String -> InventoryTx EntityId
mintLotWith forced tx reason job resource q owner born expires provenance = do
  require (sourceReason reason && q > 0) InvalidQuantity
  ensureSpaceWith forced owner resource q
  quantity <- checked q
  ident <- freshId
  let lot = Lot ident resource quantity owner born expires provenance
  modify' $ \s -> s {invLots = M.insert ident lot (invLots s)}
  record tx reason job resource q Nothing (Just owner)
  pure ident

lotReserved :: Inventory -> EntityId -> Integer
lotReserved s ident = sum [qtyValue (quantityAmount r) | r <- M.elems (invQuantity s), quantityLot r == ident]

usable :: SimTick -> Lot -> Bool
usable tick l = maybe True (> tick) (lotExpires l)

fefo :: Lot -> (Bool, Maybe SimTick, SimTick, EntityId)
fefo l = (not (isJust (lotExpires l)), lotExpires l, lotBorn l, lotId l)

selectFree :: SimTick -> Owner -> Resource -> Integer -> InventoryTx [(EntityId, Integer)]
selectFree tick owner resource q = do
  _ <- checked q
  s <- get
  let candidates = sortOn fefo [l | l <- M.elems (invLots s), lotOwner l == owner, lotResource l == resource, usable tick l]
      pick need [] = if need == 0 then Right [] else Left MissingStock
      pick need (l : ls)
        | need == 0 = Right []
        | otherwise =
            let n = min need (qtyValue (lotQty l) - lotReserved s (lotId l))
             in ((if n == 0 then [] else [(lotId l, n)]) ++) <$> pick (need - n) ls
  either throwTx pure (pick q candidates)

reserveQuantity :: SimTick -> EntityId -> Owner -> Resource -> Integer -> InventoryTx ()
reserveQuantity tick job owner resource q = do
  require (q > 0) InvalidQuantity
  selected <- selectFree tick owner resource q
  forM_ selected $ \(ident, n) -> do
    rid <- freshId
    amount <- checked n
    modify' $ \s -> s {invQuantity = M.insert rid (QuantityReservation rid job ident amount) (invQuantity s)}

reserveCapacity :: EntityId -> Owner -> Resource -> Integer -> InventoryTx ()
reserveCapacity job owner resource q = do
  require (q > 0) InvalidQuantity
  ensureSpace owner resource q
  s <- get
  ident <- freshId
  modify' $ \t -> t {invCapacity = M.insert ident (CapacityReservation ident job owner (weightOf s resource q)) (invCapacity t)}

reserveDelivery :: SimTick -> EntityId -> Owner -> Owner -> Resource -> Integer -> InventoryTx ()
reserveDelivery tick job src dst resource q = do
  reserveQuantity tick job src resource q
  reserveCapacity job dst resource q

releaseJob :: EntityId -> InventoryTx ()
releaseJob job = modify' $ \s ->
  s
    { invQuantity = M.filter ((/= job) . quantityJob) (invQuantity s),
      invCapacity = M.filter ((/= job) . capacityJob) (invCapacity s),
      invNatural = M.filter ((/= job) . naturalJob) (invNatural s)
    }

removeFromLot :: EntityId -> Integer -> InventoryTx Lot
removeFromLot ident q = do
  s <- get
  lot <- maybe (throwTx MissingLot) pure (M.lookup ident (invLots s))
  require (q > 0 && q <= qtyValue (lotQty lot)) InvalidQuantity
  remaining <- checked (qtyValue (lotQty lot) - q)
  let lots = if qtyValue remaining == 0 then M.delete ident (invLots s) else M.insert ident (lot {lotQty = remaining}) (invLots s)
  put s {invLots = lots}
  pure lot

-- Physical transfer preserves age, expiry and provenance, and has no source/sink entry.
transferSelected :: Owner -> [(EntityId, Integer)] -> InventoryTx ()
transferSelected = transferSelectedWith False

transferRecovered :: Owner -> [(EntityId, Integer)] -> InventoryTx ()
transferRecovered destination@(Owner kind _) selected = do
  require (kind == RecoveryHold) (InvalidReference "forced recovery destination must be RecoveryHold")
  transferSelectedWith True destination selected

transferSelectedWith :: Bool -> Owner -> [(EntityId, Integer)] -> InventoryTx ()
transferSelectedWith forced destination selected = forM_ selected $ \(ident, q) -> do
  s <- get
  lot <- maybe (throwTx MissingLot) pure (M.lookup ident (invLots s))
  require (q <= qtyValue (lotQty lot) - lotReserved s ident) MissingStock
  ensureSpaceWith forced destination (lotResource lot) q
  original <- removeFromLot ident q
  amount <- checked q
  movedId <- freshId
  modify' $ \t -> t {invLots = M.insert movedId (original {lotId = movedId, lotQty = amount, lotOwner = destination}) (invLots t)}

moveFree :: SimTick -> Owner -> Owner -> Resource -> Integer -> InventoryTx ()
moveFree tick src dst resource q = selectFree tick src resource q >>= transferSelected dst

moveReserved :: EntityId -> Owner -> Owner -> InventoryTx ()
moveReserved job src dst = do
  s <- get
  let rs = [r | r <- M.elems (invQuantity s), quantityJob r == job, maybe False ((== src) . lotOwner) (M.lookup (quantityLot r) (invLots s))]
  require (not (null rs)) MissingReservation
  let ids = map quantityReservationId rs
  modify' $ \t -> t {invQuantity = foldr M.delete (invQuantity t) ids, invCapacity = M.filter (\r -> capacityJob r /= job || capacityOwner r /= dst) (invCapacity t)}
  transferSelected dst [(quantityLot r, qtyValue (quantityAmount r)) | r <- rs]

consumeFree :: TxId -> Reason -> Maybe EntityId -> SimTick -> Owner -> Resource -> Integer -> InventoryTx ()
consumeFree tx reason = consumeFreeDetailed tx reason Nothing

consumeFreeDetailed :: TxId -> Reason -> Maybe LedgerSubreason -> Maybe EntityId -> SimTick -> Owner -> Resource -> Integer -> InventoryTx ()
consumeFreeDetailed tx reason detail job tick owner resource q = do
  require (not (sourceReason reason)) InvalidQuantity
  selected <- selectFree tick owner resource q
  forM_ selected $ \(ident, n) -> removeFromLot ident n >> pure ()
  recordDetailed tx reason detail job resource q (Just owner) Nothing

consumeAllAt :: TxId -> Reason -> EntityId -> Owner -> InventoryTx ()
consumeAllAt tx reason job owner = do
  lots <- gets (filter ((== owner) . lotOwner) . M.elems . invLots)
  forM_ lots $ \l -> do
    _ <- removeFromLot (lotId l) (qtyValue (lotQty l))
    record tx reason (Just job) (lotResource l) (qtyValue (lotQty l)) (Just owner) Nothing

addDeposit :: String -> Resource -> Integer -> InventoryTx EntityId
addDeposit kind resource q = do
  amount <- checked q
  ident <- freshId
  modify' $ \s -> s {invDeposits = M.insert ident (Deposit ident kind resource amount) (invDeposits s)}
  pure ident

reserveNatural :: EntityId -> EntityId -> Integer -> InventoryTx ()
reserveNatural job source q = do
  require (q > 0) InvalidQuantity
  s <- get
  dep <- maybe (throwTx TargetGone) pure (M.lookup source (invDeposits s))
  let reserved = sum [qtyValue (naturalAmount r) | r <- M.elems (invNatural s), naturalSource r == source]
  require (q <= qtyValue (depositQty dep) - reserved) MissingStock
  amount <- checked q
  ident <- freshId
  modify' $ \t -> t {invNatural = M.insert ident (NaturalReservation ident job source amount) (invNatural t)}

extractReserved :: TxId -> EntityId -> Owner -> SimTick -> InventoryTx ()
extractReserved tx job dst tick = do
  s <- get
  let rs = [r | r <- M.elems (invNatural s), naturalJob r == job]
  require (not (null rs)) MissingReservation
  modify' $ \t -> t {invCapacity = M.filter ((/= job) . capacityJob) (invCapacity t)}
  forM_ rs $ \r -> do
    dep <- gets (M.lookup (naturalSource r) . invDeposits) >>= maybe (throwTx TargetGone) pure
    remaining <- checked (qtyValue (depositQty dep) - qtyValue (naturalAmount r))
    modify' $ \t -> t {invDeposits = M.insert (depositId dep) (dep {depositQty = remaining}) (invDeposits t), invNatural = M.delete (naturalReservationId r) (invNatural t)}
    _ <- mintLot tx Extraction (Just job) (depositResource dep) (qtyValue (naturalAmount r)) dst tick Nothing ("extraction:" ++ show job)
    pure ()

expireInventory :: TxId -> SimTick -> InventoryTx [EntityId]
expireInventory tx tick = do
  expired <- gets (sortOn lotId . filter (not . usable tick) . M.elems . invLots)
  affected <- gets (\s -> [quantityJob r | r <- M.elems (invQuantity s), quantityLot r `elem` map lotId expired])
  forM_ expired $ \l -> do
    modify' $ \s -> s {invQuantity = M.filter ((/= lotId l) . quantityLot) (invQuantity s)}
    _ <- removeFromLot (lotId l) (qtyValue (lotQty l))
    record tx SpoilageInput Nothing (lotResource l) (qtyValue (lotQty l)) (Just (lotOwner l)) Nothing
    s <- get
    let waste = weightOf s (lotResource l) (qtyValue (lotQty l))
        fit = if maybe True (\st -> maybe False (/= Waste) (storageResource st)) (M.lookup (lotOwner l) (invStorage s)) then 0 else max 0 (min waste (freeWeight s (lotOwner l)))
    _ <- checked waste
    when (fit > 0) $ mintLotWith True tx SpoilageOutput Nothing Waste fit (lotOwner l) tick Nothing "spoilage" >> pure ()
    when (waste > fit) $ do
      record tx SpoilageOutput Nothing Waste (waste - fit) Nothing (Just (lotOwner l))
      record tx SpoilageDisposal Nothing Waste (waste - fit) (Just (lotOwner l)) Nothing
  pure affected

validateInventory :: Inventory -> Either Failure ()
validateInventory s = do
  let check b msg = unless b (Left (InvariantViolation msg))
      within n = n >= 0 && n <= quantityMax
  check (invNextId s > 0) "ID counter is zero"
  let assets = inventoryAssetIds s
      owners = [ident | Owner _ ident <- M.keys (invStorage s)]
      colonies = map storageColony (M.elems (invStorage s))
      allocated = assets ++ owners ++ colonies
  check (length assets == M.size (M.fromList [(ident, ()) | ident <- assets])) "duplicate asset/reservation/deposit ID"
  check (null [ident | ident <- owners, ident `elem` assets]) "storage ID collides with asset/reservation/deposit"
  check (null [ident | ident <- colonies, ident `elem` assets || ident `elem` owners]) "colony ID collision"
  check (all (\(EntityId ident) -> ident < invNextId s) allocated) "ID counter would reuse allocated ID"
  check (M.keys (invLoad s) == allResources && all (\n -> n > 0 && within n) (M.elems (invLoad s))) "invalid resource load metadata"
  check (M.keys (invShelf s) == allResources) "invalid shelf-life metadata"
  forM_ (M.toList (invLots s)) $ \(ident, l) -> do
    check (ident == lotId l) "lot key mismatch"
    check (qtyValue (lotQty l) > 0 && within (qtyValue (lotQty l))) "invalid lot quantity"
    check (M.member (lotOwner l) (invStorage s)) "dangling lot owner"
    check (lotReserved s ident <= qtyValue (lotQty l)) "quantity overreservation"
    check (maybe True (\st -> maybe True (== lotResource l) (storageResource st)) (M.lookup (lotOwner l) (invStorage s))) "storage resource mismatch"
  forM_ (M.toList (invStorage s)) $ \(owner@(Owner kind _), st) -> do
    check (within (storageCapacity st)) "invalid capacity"
    check (kind == RecoveryHold || heldWeight s owner + reservedWeight s owner <= storageCapacity st) "capacity overreservation"
  forM_ (M.toList (invQuantity s)) $ \(ident, r) -> do
    check (ident == quantityReservationId r && M.member (quantityLot r) (invLots s)) "dangling quantity reservation"
    check (qtyValue (quantityAmount r) > 0) "zero quantity reservation"
  forM_ (M.toList (invCapacity s)) $ \(ident, r) ->
    check (ident == capacityReservationId r && M.member (capacityOwner r) (invStorage s) && capacityWeight r > 0 && within (capacityWeight r)) "invalid capacity reservation"
  forM_ (M.toList (invNatural s)) $ \(ident, r) -> check (ident == naturalReservationId r && M.member (naturalSource r) (invDeposits s) && qtyValue (naturalAmount r) > 0) "dangling natural reservation"
  forM_ (M.toList (invDeposits s)) $ \(ident, d) -> do
    check (ident == depositId d) "deposit key mismatch"
    check (sum [qtyValue (naturalAmount r) | r <- M.elems (invNatural s), naturalSource r == depositId d] <= qtyValue (depositQty d)) "natural overreservation"
  forM_ (M.toList (invLedger s)) $ \((resource, reason), n) -> do
    check (within n) "ledger overflow"
    check (reasonAllowed resource reason) "invalid resource ledger reason"
  forM_ allResources $ \resource -> do
    let actual = sum [qtyValue (lotQty l) | l <- M.elems (invLots s), lotResource l == resource]
        ledger = sum [if sourceReason reason then n else -n | ((r, reason), n) <- M.toList (invLedger s), r == resource]
    check (actual == ledger) ("resource conservation: " ++ show resource ++ " actual=" ++ show actual ++ " ledger=" ++ show ledger)
    check (within actual) "aggregate quantity overflow"
  forM_ (invRecentLedger s) $ \entry -> check (subreasonAllowed entry) "invalid ledger subreason"
  check (length (invRecentLedger s) <= 256) "unbounded ledger history"

reasonAllowed :: Resource -> Reason -> Bool
reasonAllowed resource reason = case reason of
  Extraction -> resource `elem` [Water, Brine, Ore, Stone, Sand]
  LivingConsumed -> resource `elem` [Water, Ration, Medicine]
  FuelBurned -> resource == Fuel
  RescueFuelConsumed -> resource == Fuel
  SpoilageInput -> resource `elem` [Crops, Ration]
  SpoilageOutput -> resource == Waste
  SpoilageDisposal -> resource == Waste
  ResearchConsumed -> resource `elem` [Ration, Parts]
  _ -> True

inventoryAssetIds :: Inventory -> [EntityId]
inventoryAssetIds s = M.keys (invLots s) ++ M.keys (invQuantity s) ++ M.keys (invCapacity s) ++ M.keys (invNatural s) ++ M.keys (invDeposits s)

subreasonAllowed :: LedgerEntry -> Bool
subreasonAllowed entry = case ledgerSubreason entry of
  Nothing -> True
  Just VehicleEdge -> ledgerReason entry == FuelBurned && ledgerResource entry == Fuel
  Just Maintenance -> ledgerReason entry == RecipeInput && ledgerResource entry == Parts
  Just Repair -> ledgerReason entry == RecipeInput && ledgerResource entry == Parts
