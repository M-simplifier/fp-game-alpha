module Main where

import Colony.Codec (sha256)
import Colony.Codec.CBOR (CBOR (..), CodecError, encodeCanonical)
import Colony.Codec.Value (ValueCodec (..))
import Colony.Construction qualified as C
import Colony.Content (Building (..), Content (..), Recipe (..))
import Colony.Inventory
import Colony.JSON qualified as J
import Colony.M1State
import Colony.Needs
import Colony.Presentation (obj, str)
import Colony.S01Fixture
import Colony.Space qualified as Space
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import RedDune.ContentPack
import RedDune.Game
import RedDune.GameSave
import RedDune.Native.Play (startVillageGame)
import RedDune.Policies
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError ("DINING: " ++ label)))

must :: (Show e) => Either e a -> IO a
must = either (ioError . userError . show) pure

isLeft :: Either a b -> Bool
isLeft Left {} = True
isLeft _ = False

-- Shorter work keeps this a focused mechanical test; every material cost,
-- footprint, vehicle trip, resource amount and workforce requirement is real.
testPack :: ContentPack
testPack = defaultPack {packEconomy = economy {contentBuildings = M.map (\building -> building {buildingBuildWorkTicks = 2}) (contentBuildings economy), contentRecipes = M.map (\recipe -> recipe {recipeWorkTicks = 20}) (contentRecipes economy)}}
  where
    economy = packEconomy defaultPack

setup :: IO GameState
setup = do
  initial <- must (startVillageGame "settlement" testPack)
  fst <$> must (applyAction (jsonAction [("op", "configure"), ("preset", "survival")]) initial)

-- Keep test commands in the same public request boundary as the client.
jsonAction :: [(String, String)] -> J.JSON
jsonAction fields = obj [(key, str value) | (key, value) <- fields]

resume :: GameState -> IO GameState
resume game = fst <$> must (applyAction (jsonAction [("op", "resume")]) game)

playUntilMeal :: Int -> GameState -> IO GameState
playUntilMeal remaining game
  | any (not . null . diningMeals) (diningStatuses game) = pure game
  | remaining <= 0 = ioError (userError ("Dining did not serve: " ++ show (simTick (gameWorld game), diningStatuses game, gameBuildQueue game)))
  | otherwise = do
      if remaining `mod` 2000 == 0 then putStrLn ("Dining progress: " ++ show (simTick (gameWorld game), diningStatuses game, length (gameBuildQueue game))) else pure ()
      must (advanceGame 20 game) >>= playUntilMeal (remaining - 20)

grantLedger :: GameState -> M.Map (Resource, Reason) Integer
grantLedger = M.filterWithKey (\(_, reason) _ -> reason == InitialGrant) . invLedger . worldInventory . gameWorld

legacyBytes :: GameState -> IO BS.ByteString
legacyBytes game = do
  value <- must (toCBOR game)
  case value of
    CMap [(0, CInteger 0), (1, CMap fields)] -> do
      payload <- must (encodeCanonical (CMap [(0, CInteger 0), (1, CMap (take 9 fields))]))
      pure (BC.pack "RDLIVE1\n" <> sha256 payload <> payload)
    _ -> ioError (userError "Unexpected test GameState wire shape")

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  original <- must (startGame "settlement" defaultPack)
  previous <- legacyBytes original
  check "strict V1 migration preserves world and defaults both new maps" (decodeGame previous == Right original)
  check "V1 checksum rejects changed payload" (isLeft (decodeGame (BS.take 60 previous <> BC.pack "changed")))
  needsValue <- must (toCBOR (worldNeeds (gameWorld original)))
  case needsValue of
    CMap [(0, CInteger 0), (1, CMap fields)] -> do
      check "empty NeedsState keeps legacy canonical fields" (map fst fields == [0, 1])
      check "future NeedsState field rejected" (isLeft (fromCBOR (CMap [(0, CInteger 0), (1, CMap (fields ++ [(2, CArray []), (3, CArray []), (4, CArray [])]))]) :: Either CodecError NeedsState))
    _ -> ioError (userError "Unexpected needs wire shape")
  check "shared scarcity tops up unserved residents first" (allocateAfterServed 2 [(EntityId 1, 2), (EntityId 2, 2)] (M.singleton (EntityId 1) 2) == M.fromList [(EntityId 1, 0), (EntityId 2, 2)])
  configured <- setup
  forM_ [(Space.Tile 60 64, Space.R180), (Space.Tile 80 64, Space.R270)] $ \(tile, rotation) -> do
    planned <- must (planDining tile rotation configured)
    check "placement and orientation retained" (gameDiningPlaces planned == M.singleton tile rotation)
    check "queued dining footprint remains clear of furniture" (isLeft (validatePlace planned (tile, (PlaceBench, Space.R0))))
    check "planning grants no inventory or finished building" (invLots (worldInventory (gameWorld planned)) == invLots (worldInventory (gameWorld configured)) && not (any diningBuilt (diningStatuses planned)))
    savedPlan <- must (encodeGame planned)
    check "chosen location and route survive save" (decodeGame savedPlan == Right planned)
    playing <- resume planned
    served <- playUntilMeal 36000 playing
    check "initial grants unchanged through roads, carts and meals" (grantLedger served == grantLedger configured)
    must (validateGame served)
    case diningStatuses served of
      [status] -> do
        owner <- maybe (ioError (userError "Dining has no built pantry")) pure (diningOwner status)
        check "actual local stock has arrived" (diningBuilt status && diningStock status > 0)
        let world = gameWorld served
            needs = worldNeeds world
            state = maybe (error "test missing M1") id (worldM1 world)
            roster = W.workforceRosters (m1Workforce state)
            Owner _ ident = owner
            actualMeals = diningMeals status
            claims = W.workforceClaims (m1Workforce state)
        check "six existing people have a local dining assignment" (M.size (needsDiningPreferences needs) == 6 && all (`M.member` needsResidents needs) (diningResidents status))
        check "actual free resident meal evidence" (not (null actualMeals) && all (\(resident, meal) -> resident `elem` diningResidents status && mealOwner meal == owner && mealQuantity meal > 0 && M.notMember resident claims) actualMeals)
        check "one real server in every shift" (all (\shift -> length (M.findWithDefault [] (W.OperateFacility ident, shift) roster) == 1) [0 .. 2])
        check "dining food source is only the existing kitchen" (any (\route -> policyDestination route == owner && policyResource route == Ration && policySources route == [Owner MachineOutput (s01Kitchen (gameDescriptor served))]) (deliveryPolicies (gamePolicies served)))
        check "building cost really consumed" (M.findWithDefault 0 (Stone, ConstructionConsumed) (invLedger (worldInventory world)) > 0 && all C.constructionTerminal (M.elems (C.constructionJobs (m1Construction state))))
        consumptionChecks owner served
        bytes <- must (encodeGame served)
        restored <- must (decodeGame bytes)
        a <- must (advanceGame 80 served)
        b <- must (advanceGame 80 restored)
        check "complete restored suffix including meal evidence" (a == b)
        putStrLn ("Dining accepted: " ++ show (tile, rotation, simTick world, owner, actualMeals))
      _ -> ioError (userError "Expected one dining place")
  check "negative outside-map placement" (isLeft (planDining (Space.Tile (-1) 20) Space.R0 configured))
  check "negative existing building overlap" (isLeft (planDining (Space.Tile 50 58) Space.R0 configured))
  check "negative existing road overlap" (isLeft (planDining (Space.Tile 60 63) Space.R0 configured))
  check "negative real source overlap" (isLeft (planDining (Space.Tile 60 52) Space.R0 configured))
  putStrLn "PASS: local dining consumption, physical construction/haul, fairness, fallback, save migration and exact suffix"

consumptionChecks :: Owner -> GameState -> IO ()
consumptionChecks owner game = do
  let world = gameWorld game
      before = worldInventory world
      needs = (worldNeeds world) {needsLastMeals = M.empty}
      people = diningResidents (case diningStatuses game of status : _ -> status; [] -> error "test missing dining")
      tick = let SimTick t = simTick world; rounded = t + 20 - t `mod` 20 in SimTick (if rounded `mod` 1200 == 0 then rounded + 20 else rounded)
      tx = TxId (worldId world) (branchId world) (boundarySeq world) P8 99
      localQuantity inventory = poolAvailable tick [owner] Ration inventory
      totalFood inventory = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inventory), lotResource lot == Ration]
  ((afterNeeds, result), after) <- must (runInventory (stepNeedsForDining False (S.fromList people) tx tick needs) before)
  let meals = [meal | meal <- M.elems (needsLastMeals afterNeeds), mealOwner meal == owner]
  check "local loss equals actual local recorded servings" (localQuantity before - localQuantity after == sum (map mealQuantity meals) && not (null meals))
  check "all food mass loss equals exactly once nutrition" (totalFood before - totalFood after == needFoodServed result && needFoodServed result <= needFoodDue result)
  check "stock ledger equals once-only consumed mass" (M.findWithDefault 0 (Ration, LivingConsumed) (invLedger after) - M.findWithDefault 0 (Ration, LivingConsumed) (invLedger before) == needFoodServed result)
  let repeatedPantries = needs {needsPantries = M.map (\owners -> owners ++ owners) (needsPantries needs)}
  ((repeatedNeeds, repeatedResult), repeatedInventory) <- must (runInventory (stepNeedsForDining False (S.fromList people) tx tick repeatedPantries) before)
  check "repeated service owners cannot double consumption" (repeatedInventory == after && repeatedResult == result && needsResidents repeatedNeeds == needsResidents afterNeeds && needsLastMeals repeatedNeeds == needsLastMeals afterNeeds)
  ((busyNeeds, busyResult), busyInventory) <- must (runInventory (stepNeedsForDining False S.empty tx tick needs) before)
  check "working residents cannot consume the local table" (localQuantity busyInventory == localQuantity before && all ((/= owner) . mealOwner) (M.elems (needsLastMeals busyNeeds)))
  check "busy people still receive ordinary pantry nutrition" (needFoodServed busyResult == needFoodDue busyResult)
  (_, emptyLocal) <- must (runInventory (consumePool tx tick [owner] Ration (localQuantity before)) before)
  ((fallbackNeeds, fallbackResult), _) <- must (runInventory (stepNeedsForDining False (S.fromList people) tx tick needs) emptyLocal)
  check "empty dining inventory falls back without fictitious meals" (needFoodServed fallbackResult == needFoodDue fallbackResult && all ((/= owner) . mealOwner) (M.elems (needsLastMeals fallbackNeeds)))
