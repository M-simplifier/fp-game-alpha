{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternSynonyms #-}

module Colony.Needs where

import Colony.Inventory
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (foldM, forM_, unless, when)
import Control.Monad.State.Strict
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import GHC.Generics (Generic)

data ResidentStatus = Living | Incapacitated | Evacuated | InTransit deriving (Eq, Show, Read, Generic, NFData)

data Fraction = Fraction {fractionNumerator :: !Integer, fractionDenominator :: !Integer} deriving (Eq, Show, Read, Generic, NFData)

data Resident = Resident
  { residentId :: !EntityId,
    residentColony :: !EntityId,
    residentWaterRemainder :: !Integer,
    residentFoodRemainder :: !Integer,
    residentHourWaterDue :: !Integer,
    residentHourWaterServed :: !Integer,
    residentHourFoodDue :: !Integer,
    residentHourFoodServed :: !Integer,
    residentHealth :: !Integer,
    residentHealthRemainder :: !Fraction,
    residentFatigue :: !Integer,
    residentBed :: !Bool,
    residentShift :: !Integer,
    residentStatus :: !ResidentStatus,
    residentIncapacitatedSince :: !(Maybe SimTick)
  }
  deriving (Eq, Show, Read, Generic, NFData)

data MealRecord = MealRecord
  { mealOwner :: !Owner,
    mealTick :: !SimTick,
    mealQuantity :: !Integer
  }
  deriving (Eq, Show, Read, Generic, NFData)

data NeedsState = NeedsStateWithDining
  { needsResidents :: !(M.Map EntityId Resident),
    needsPantries :: !(M.Map EntityId [Owner]),
    needsDiningPreferences :: !(M.Map EntityId Owner),
    needsLastMeals :: !(M.Map EntityId MealRecord)
  }
  deriving (Eq, Show, Read, Generic, NFData)

-- Keep existing fixture construction source-compatible. Legacy records acquire
-- empty dining assignments and meal evidence through the explicit wire codec.
pattern NeedsState :: M.Map EntityId Resident -> M.Map EntityId [Owner] -> NeedsState
pattern NeedsState residents pantries <- NeedsStateWithDining residents pantries _ _
  where
    NeedsState residents pantries = NeedsStateWithDining residents pantries M.empty M.empty

{-# COMPLETE NeedsState #-}

data NeedResult = NeedResult {needWaterDue :: !Integer, needWaterServed :: !Integer, needFoodDue :: !Integer, needFoodServed :: !Integer, needEvacuated :: ![EntityId]}
  deriving (Eq, Show, Read, Generic, NFData)

newResident :: EntityId -> EntityId -> Resident
newResident ident@(EntityId n) colony = Resident ident colony 0 0 0 0 0 0 1000 (Fraction 0 1) 0 True (toInteger (n `mod` 3)) Living Nothing

validateNeeds :: NeedsState -> Inventory -> Either Failure ()
validateNeeds ns inv = do
  let check b msg = unless b (Left (InvariantViolation msg))
  forM_ (M.toList (needsResidents ns)) $ \(ident, r) -> do
    check (ident == residentId r) "resident ID mismatch"
    check (all (\n -> n >= 0 && n < 28800) [residentWaterRemainder r, residentFoodRemainder r]) "need remainder bounds"
    let Fraction n d = residentHealthRemainder r
    check (d > 0 && n >= 0 && n < d && gcd n d == 1) "health remainder bounds"
    check (residentHealth r >= 0 && residentHealth r <= 1000 && residentFatigue r >= 0 && residentFatigue r <= 1000) "resident meter bounds"
    check (residentHourWaterDue r >= residentHourWaterServed r && residentHourFoodDue r >= residentHourFoodServed r && residentHourWaterServed r >= 0 && residentHourFoodServed r >= 0) "resident consumption history"
    check (residentShift r >= 0 && residentShift r <= 2) "resident shift bounds"
  forM_ (M.toList (needsPantries ns)) $ \(colony, owners) -> forM_ owners $ \owner@(Owner kind _) -> do
    check (kind == Pantry) "needs service source is not Pantry"
    check (maybe False ((== colony) . storageColony) (M.lookup owner (invStorage inv))) "needs source outside colony"
  let checkDiningOwner ident owner@(Owner kind _) = do
        resident <- maybe (Left (InvariantViolation "dining references unknown resident")) Right (M.lookup ident (needsResidents ns))
        check (kind == Pantry) "dining source is not Pantry"
        check (maybe False ((== residentColony resident) . storageColony) (M.lookup owner (invStorage inv))) "dining source outside resident colony"
  forM_ (M.toList (needsDiningPreferences ns)) (uncurry checkDiningOwner)
  forM_ (M.toList (needsLastMeals ns)) $ \(ident, meal) -> do
    checkDiningOwner ident (mealOwner meal)
    let SimTick tick = mealTick meal
    check (tick `mod` 20 == 0 && mealQuantity meal > 0 && mealQuantity meal <= 3) "invalid actual meal record"

-- Max-min water filling with a rotating remainder, bounded by residents rather than quantities.
allocateFair :: Integer -> [(EntityId, Integer)] -> M.Map EntityId Integer
allocateFair available requests = M.fromList [(ident, base + if ident `elem` extras then 1 else 0) | (ident, due) <- requests, let base = min due level]
  where
    budget = max 0 (min available (sum (map snd requests)))
    maxDue = maximum (0 : map snd requests)
    cost n = sum [min n due | (_, due) <- requests]
    findLevel lo hi
      | lo >= hi = lo
      | otherwise = let mid = (lo + hi + 1) `div` 2 in if cost mid <= budget then findLevel mid hi else findLevel lo (mid - 1)
    level = findLevel 0 maxDue
    remainder = budget - cost level
    extras = take (fromInteger remainder) [ident | (ident, due) <- requests, due > level]

poolAvailable :: SimTick -> [Owner] -> Resource -> Inventory -> Integer
poolAvailable tick owners resource inv = sum [qtyValue (lotQty l) - lotReserved inv (lotId l) | l <- M.elems (invLots inv), lotOwner l `elem` owners, lotResource l == resource, usable tick l]

consumePool :: TxId -> SimTick -> [Owner] -> Resource -> Integer -> InventoryTx ()
consumePool tx tick owners resource amount = do
  inv <- get
  require (amount <= poolAvailable tick owners resource inv) MissingStock
  let candidates = sortOn fefo [l | l <- M.elems (invLots inv), lotOwner l `elem` owners, lotResource l == resource, usable tick l]
  consume amount candidates
  where
    consume 0 _ = pure ()
    consume _ [] = throwTx MissingStock
    consume remaining (l : rest) = do
      inv <- get
      let n = min remaining (qtyValue (lotQty l) - lotReserved inv (lotId l))
      when (n > 0) $ do
        _ <- removeFromLot (lotId l) n
        record tx LivingConsumed Nothing resource n (Just (lotOwner l)) Nothing
      consume (remaining - n) rest

stepNeeds :: TxId -> SimTick -> NeedsState -> InventoryTx (NeedsState, NeedResult)
stepNeeds = stepNeedsWithFatigue True

-- Schema4 accounts actual duty every elapsed tick in Workforce.
stepNeedsWithFatigue :: Bool -> TxId -> SimTick -> NeedsState -> InventoryTx (NeedsState, NeedResult)
stepNeedsWithFatigue legacyFatigue = stepNeedsForDining legacyFatigue S.empty

-- The scheduler supplies the people who did no duty this tick. Dining stock is
-- local: only their preferred, staffed pantry can serve them from that stock.
-- The base pantry still serves every unfilled need, including a missing meal.
stepNeedsForDining :: Bool -> S.Set EntityId -> TxId -> SimTick -> NeedsState -> InventoryTx (NeedsState, NeedResult)
stepNeedsForDining legacyFatigue freeResidents tx tick@(SimTick t) ns = do
  inv <- get
  either throwTx pure (validateNeeds ns inv)
  if t `mod` 20 /= 0
    then pure (ns, NeedResult 0 0 0 0 [])
    else do
      let colonies = M.keys (M.fromList [(residentColony r, ()) | r <- M.elems (needsResidents ns), residentStatus r `elem` [Living, Incapacitated]])
      (residents, meals, waterDue, waterServed, foodDue, foodServed) <- foldM distribute (needsResidents ns, needsLastMeals ns, 0, 0, 0, 0) colonies
      let refreshed = if t `mod` 1200 == 0 then M.map (\resident -> let updated = updateHealth tick resident in if legacyFatigue then updated else updated {residentFatigue = residentFatigue resident}) residents else residents
          evacuated = [residentId r | r <- M.elems refreshed, residentStatus r == Evacuated, maybe False ((/= Evacuated) . residentStatus) (M.lookup (residentId r) (needsResidents ns))]
          next = ns {needsResidents = refreshed, needsLastMeals = meals}
      current <- get
      either throwTx pure (validateNeeds next current)
      pure (next, NeedResult waterDue waterServed foodDue foodServed evacuated)
  where
    distribute (residents, meals, wd, ws, fd, fs) colony = do
      inv <- get
      let members = [r | r <- M.elems residents, residentColony r == colony, residentStatus r `elem` [Living, Incapacitated]]
          offset = if null members then 0 else fromIntegral ((t `div` 20) `mod` fromIntegral (length members))
          ordered = drop offset members ++ take offset members
          dueWater r = (residentWaterRemainder r + 6000 * 20) `div` 28800
          dueFood r = (residentFoodRemainder r + 3000 * 20) `div` 28800
          owners = S.toAscList (S.fromList (M.findWithDefault [] colony (needsPantries ns)))
          diningOwners = S.fromList (M.elems (needsDiningPreferences ns))
          ordinaryOwners = filter (`S.notMember` diningOwners) owners
          diningRequests owner = [(residentId r, dueFood r) | r <- ordered, residentStatus r == Living, S.member (residentId r) freeResidents, M.lookup (residentId r) (needsDiningPreferences ns) == Just owner]
          local = M.unions [allocateFair (poolAvailable tick [owner] Ration inv) (diningRequests owner) | owner <- owners, S.member owner diningOwners]
          water = allocateFair (poolAvailable tick owners Water inv) [(residentId r, dueWater r) | r <- ordered]
          ordinary = allocateAfterServed (poolAvailable tick ordinaryOwners Ration inv) [(residentId r, dueFood r) | r <- ordered] local
          food = M.unionWith (+) ordinary local
          waterTaken = sum (M.elems water)
          foodTaken = sum (M.elems food)
          update r =
            r
              { residentWaterRemainder = (residentWaterRemainder r + 6000 * 20) `mod` 28800,
                residentFoodRemainder = (residentFoodRemainder r + 3000 * 20) `mod` 28800,
                residentHourWaterDue = residentHourWaterDue r + dueWater r,
                residentHourWaterServed = residentHourWaterServed r + M.findWithDefault 0 (residentId r) water,
                residentHourFoodDue = residentHourFoodDue r + dueFood r,
                residentHourFoodServed = residentHourFoodServed r + M.findWithDefault 0 (residentId r) food
              }
      consumePool tx tick owners Water waterTaken
      ordinaryMeals <-
        if M.null (needsDiningPreferences ns)
          then consumePool tx tick ordinaryOwners Ration (sum (M.elems ordinary)) >> pure M.empty
          else consumeServings tx tick ordinaryOwners [(residentId r, M.findWithDefault 0 (residentId r) ordinary) | r <- ordered]
      localMeals <- foldM (\recorded owner -> do served <- consumeServings tx tick [owner] [(ident, M.findWithDefault 0 ident local) | (ident, _) <- diningRequests owner]; pure (M.union served recorded)) M.empty [owner | owner <- owners, S.member owner diningOwners]
      pure (foldr (\r -> M.insert (residentId r) (update r)) residents members, M.union localMeals (M.union ordinaryMeals meals), wd + sum (map dueWater members), ws + waterTaken, fd + sum (map dueFood members), fs + foodTaken)

-- Base food fills people who received less local food first. Its water-filling
-- budget counts existing servings, so local and fallback food cannot double a
-- person's due quantity or disadvantage others in a scarce shared pantry.
allocateAfterServed :: Integer -> [(EntityId, Integer)] -> M.Map EntityId Integer -> M.Map EntityId Integer
allocateAfterServed available requests served = M.fromList [(ident, base ident due + if ident `elem` extras then 1 else 0) | (ident, due) <- requests]
  where
    previous ident = M.findWithDefault 0 ident served
    remaining = sum [max 0 (due - previous ident) | (ident, due) <- requests]
    budget = max 0 (min available remaining)
    cost candidateLevel = sum [max 0 (min due candidateLevel - previous ident) | (ident, due) <- requests]
    search lo hi
      | lo >= hi = lo
      | otherwise = let mid = (lo + hi + 1) `div` 2 in if cost mid <= budget then search mid hi else search lo (mid - 1)
    level = search 0 (maximum (0 : map snd requests))
    base ident due = max 0 (min due level - previous ident)
    extras = take (fromInteger (budget - cost level)) [ident | (ident, due) <- requests, due > level, previous ident <= level]

-- Evidence is made only by removal from actual unreserved FEFO lots. If a
-- serving crosses sources, the record describes its last physical source and
-- the exact part of that serving removed there.
consumeServings :: TxId -> SimTick -> [Owner] -> [(EntityId, Integer)] -> InventoryTx (M.Map EntityId MealRecord)
consumeServings tx tick owners = foldM serve M.empty
  where
    serve records (_, 0) = pure records
    serve records (ident, amount) = do
      inv <- get
      require (amount >= 0 && amount <= poolAvailable tick owners Ration inv) MissingStock
      portions <- takeLots amount (sortOn fefo [lot | lot <- M.elems (invLots inv), lotOwner lot `elem` owners, lotResource lot == Ration, usable tick lot])
      case reverse portions of
        (owner, _) : _ -> pure (M.insert ident (MealRecord owner tick (sum [quantity | (source, quantity) <- portions, source == owner])) records)
        [] -> throwTx (InvariantViolation "positive meal has no consumed lot")
    takeLots 0 _ = pure []
    takeLots _ [] = throwTx MissingStock
    takeLots remaining (lot : rest) = do
      inv <- get
      let amount = min remaining (qtyValue (lotQty lot) - lotReserved inv (lotId lot))
      if amount <= 0
        then takeLots remaining rest
        else do
          _ <- removeFromLot (lotId lot) amount
          record tx LivingConsumed Nothing Ration amount (Just (lotOwner lot)) Nothing
          ((lotOwner lot, amount) :) <$> takeLots (remaining - amount) rest

fraction :: Integer -> Integer -> Fraction
fraction n d = let g = gcd n d in Fraction (n `div` g) (d `div` g)

plus :: Fraction -> Fraction -> Fraction
plus (Fraction n d) (Fraction n' d') = fraction (n * d' + n' * d) (d * d')

updateHealth :: SimTick -> Resident -> Resident
updateHealth tick@(SimTick t) r
  | residentStatus r `elem` [Evacuated, InTransit] = r
  | otherwise =
      r
        { residentHealth = health,
          residentHealthRemainder = remainder,
          residentFatigue = fatigue,
          residentStatus = status,
          residentIncapacitatedSince = since,
          residentHourWaterDue = 0,
          residentHourWaterServed = 0,
          residentHourFoodDue = 0,
          residentHourFoodServed = 0
        }
  where
    short due supplied rate = if due == 0 then Fraction 0 1 else fraction ((due - supplied) * rate) due
    Fraction lossN lossD = short (residentHourWaterDue r) (residentHourWaterServed r) 10 `plus` short (residentHourFoodDue r) (residentHourFoodServed r) 5
    healing = if residentBed r && residentHourWaterDue r == residentHourWaterServed r && residentHourFoodDue r == residentHourFoodServed r then 5 else 0
    Fraction totalN totalD = residentHealthRemainder r `plus` fraction (healing * lossD - lossN) lossD
    delta = totalN `div` totalD
    health = max 0 (min 1000 (residentHealth r + delta))
    remainder = if health == 1000 then Fraction 0 1 else fraction (totalN `mod` totalD) totalD
    working = toInteger ((t - 1) `mod` 28800 `div` 9600) == residentShift r && residentFatigue r < 900 && residentStatus r == Living
    fatigue = max 0 (min 1000 (residentFatigue r + if working then 60 else if residentBed r then -60 else -30))
    since = if health > 0 then Nothing else case residentIncapacitatedSince r of Nothing -> Just tick; old -> old
    status = if health > 0 then Living else case since of Just (SimTick start) | t >= start && t - start >= 57600 -> Evacuated; _ -> Incapacitated
