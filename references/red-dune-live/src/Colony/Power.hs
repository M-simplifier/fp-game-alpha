{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Colony.Power where

import Colony.Inventory
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad (foldM, forM_, unless)
import Control.Monad.State.Strict
import Data.List (sortOn)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import GHC.Generics (Generic)

data Weather = Clear | Haze | Sandstorm deriving (Eq, Show, Read, Generic, NFData)

data Solar = Solar {solarId :: !EntityId, solarMaintenancePct :: !Integer} deriving (Eq, Show, Read, Generic, NFData)

data Generator = Generator {generatorId :: !EntityId, generatorFuel :: !Owner, generatorEnabled :: !Bool, generatorMaintenancePct :: !Integer} deriving (Eq, Show, Read, Generic, NFData)

data Battery = Battery {batteryId :: !EntityId, batteryStoredJ :: !Integer, batteryChargeRemainder :: !Integer, batteryMaintenancePct :: !Integer} deriving (Eq, Show, Read, Generic, NFData)

data EnergyReason = InitialEnergy | SolarGenerated | FuelGenerated | ConsumerServed | HeatLoss | Curtailment deriving (Eq, Ord, Show, Read, Generic, NFData)

data PowerGrid = PowerGrid {gridId :: !EntityId, gridSolar :: ![Solar], gridGenerators :: ![Generator], gridBatteries :: ![Battery], gridEnergyLedger :: !(M.Map EnergyReason Integer)} deriving (Eq, Show, Read, Generic, NFData)

data PowerDemand = PowerDemand {demandId :: !EntityId, demandPriority :: !Integer, demandWatts :: !Integer} deriving (Eq, Show, Read, Generic, NFData)

data PowerResult = PowerResult {poweredConsumers :: !(S.Set EntityId), generatedJ :: !Integer, servedJ :: !Integer, chargedInputJ :: !Integer, dischargedJ :: !Integer, heatLossJ :: !Integer, curtailedJ :: !Integer, operatingPowerDevices :: !(S.Set EntityId)} deriving (Eq, Show, Read, Generic, NFData)

batteryCapacityJ :: Integer
batteryCapacityJ = 720000000

batteryLimitJ :: Integer
batteryLimitJ = 60000

validatePowerGrid :: PowerGrid -> Either Failure ()
validatePowerGrid grid = do
  let check b reason = unless b (Left (InvariantViolation reason))
      batteries = gridBatteries grid
      source = sum [M.findWithDefault 0 r (gridEnergyLedger grid) | r <- [InitialEnergy, SolarGenerated, FuelGenerated]]
      sink = sum [M.findWithDefault 0 r (gridEnergyLedger grid) | r <- [ConsumerServed, HeatLoss, Curtailment]]
  check (all (\n -> n >= 0 && n <= quantityMax) (M.elems (gridEnergyLedger grid))) "energy ledger bounds"
  forM_ batteries $ \b -> check (batteryStoredJ b >= 0 && batteryStoredJ b <= batteryCapacityJ && batteryChargeRemainder b >= 0 && batteryChargeRemainder b < 10 && batteryMaintenancePct b `elem` [0, 70, 100]) "battery bounds"
  check (all (\s -> solarMaintenancePct s `elem` [0, 70, 100]) (gridSolar grid)) "solar maintenance"
  check (all (\g -> generatorMaintenancePct g `elem` [0, 70, 100]) (gridGenerators grid)) "generator maintenance"
  check (source - sink == sum (map batteryStoredJ batteries)) "energy conservation"
  check (length (map batteryId batteries) == S.size (S.fromList (map batteryId batteries))) "duplicate battery"

solarEnergy :: SimTick -> Weather -> Solar -> Integer
solarEnergy (SimTick tick) weather solar = 40000 * 3 * light * weatherPct * solarMaintenancePct solar `div` 1000000
  where
    hour = toInteger (tick `mod` 28800) `div` 1200
    light | hour >= 6 && hour < 9 = 50 | hour >= 9 && hour < 15 = 100 | hour >= 15 && hour < 18 = 50 | otherwise = 0
    weatherPct = case weather of Clear -> 100; Haze -> 60; Sandstorm -> 10

-- Refined capacity input bound accounts for the saved sub-joule charging remainder.
chargeInputRoom :: Battery -> Integer
chargeInputRoom b
  | batteryStoredJ b >= batteryCapacityJ = 0
  | otherwise = min (batteryLimitJ * batteryMaintenancePct b `div` 100) (max 0 (((batteryCapacityJ - batteryStoredJ b) * 10 + 9 - batteryChargeRemainder b) `div` 9))

stepPower :: TxId -> SimTick -> Weather -> [PowerDemand] -> PowerGrid -> InventoryTx (PowerGrid, PowerResult)
stepPower tx tick weather demands grid = do
  either throwTx pure (validatePowerGrid grid)
  require (all (\d -> demandWatts d >= 0 && demandWatts d <= quantityMax `div` 3 && demandPriority d >= 0 && demandPriority d <= 3) demands) InvalidQuantity
  require (length demands == S.size (S.fromList (map demandId demands))) (InvalidReference "duplicate power demand")
  let solar = sum (map (solarEnergy tick weather) (gridSolar grid))
      demandTotal = sum (map ((3 *) . demandWatts) demands)
      room = sum (map chargeInputRoom (gridBatteries grid))
  (generated, generatorOperating) <- foldM (generate (demandTotal + room)) (solar, S.empty) (sortOn generatorId (gridGenerators grid))
  let dischargeAvailable = sum [min (batteryStoredJ b) (batteryLimitJ * batteryMaintenancePct b `div` 100) | b <- gridBatteries grid]
      allocate (available, chosen, total) d =
        let need = demandWatts d * 3
         in if need <= available then (available - need, S.insert (demandId d) chosen, total + need) else (available, chosen, total)
      (_, accepted, used) = foldl allocate (generated + dischargeAvailable, S.empty, 0) (sortOn (\d -> (demandPriority d, demandId d)) demands)
      requiredDischarge = max 0 (used - generated)
      (remainingDischarge, dischargedBatteries) = mapAccum discharge requiredDischarge (sortOn batteryId (gridBatteries grid))
      surplus = max 0 (generated - used)
      ((unused, chargeIn, heat), batteries) = mapAccum charge (surplus, 0, 0) dischargedBatteries
      deltas = [(SolarGenerated, solar), (FuelGenerated, generated - solar), (ConsumerServed, used), (HeatLoss, heat), (Curtailment, unused)]
      ledger = foldl (\m (r, n) -> M.insertWith (+) r n m) (gridEnergyLedger grid) deltas
      next = grid {gridBatteries = batteries, gridEnergyLedger = ledger}
      solarOperating = S.fromList [solarId panel | panel <- gridSolar grid, solarEnergy tick weather panel > 0]
      batteryOperating = S.fromList [batteryId battery | battery <- batteries, Just before <- [lookup (batteryId battery) [(batteryId old, old) | old <- gridBatteries grid]], batteryStoredJ battery /= batteryStoredJ before || batteryChargeRemainder battery /= batteryChargeRemainder before]
      result = PowerResult accepted generated used chargeIn requiredDischarge heat unused (S.unions [generatorOperating, solarOperating, batteryOperating])
  require (remainingDischarge == 0) (InvariantViolation "discharge accounting")
  either throwTx pure (validatePowerGrid next)
  pure (next, result)
  where
    generate target (available, operated) generator
      | available >= target || not (generatorEnabled generator) || generatorMaintenancePct generator == 0 = pure (available, operated)
      | otherwise = do
          inv <- get
          case runInventory (consumeFree tx FuelBurned Nothing tick (generatorFuel generator) Fuel 20) inv of
            Left MissingStock -> pure (available, operated)
            Left failure -> throwTx failure
            Right (_, next) -> put next >> pure (available + 120000 * generatorMaintenancePct generator `div` 100, S.insert (generatorId generator) operated)
    discharge need b =
      let amount = min need (min (batteryStoredJ b) (batteryLimitJ * batteryMaintenancePct b `div` 100))
       in (need - amount, b {batteryStoredJ = batteryStoredJ b - amount})
    charge (available, total, heat) b =
      let amount = min available (chargeInputRoom b)
          numerator = amount * 9 + batteryChargeRemainder b
          stored = numerator `div` 10
          lost = amount - stored
       in ((available - amount, total + amount, heat + lost), b {batteryStoredJ = batteryStoredJ b + stored, batteryChargeRemainder = numerator `mod` 10})

mapAccum :: (s -> a -> (s, b)) -> s -> [a] -> (s, [b])
mapAccum _ s [] = (s, [])
mapAccum f s (a : as) = let (s1, b) = f s a; (s2, bs) = mapAccum f s1 as in (s2, b : bs)
