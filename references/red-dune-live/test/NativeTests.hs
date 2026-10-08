{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Colony.M1State (m1Space)
import Colony.S01Fixture (s01FixtureAt)
import Colony.Space qualified as Space
import Colony.Types
import Colony.Units (Resource (Ore), zeroQty)
import Colony.World
import Control.Exception (IOException, try)
import Control.Monad (foldM, replicateM_, unless)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Map.Strict qualified as M
import Data.Set qualified as Set
import RedDune.ContentPack
import RedDune.Game
import RedDune.GameSave
import RedDune.Native.Help qualified as Help
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.Policies qualified as Policies
import System.Directory
import System.Environment
import System.FilePath

must :: Either String a -> IO a
must = either (ioError . userError) pure

check :: String -> Bool -> IO ()
check label ok = unless ok (ioError (userError label))

main :: IO ()
main = do
  args <- getArgs
  root <- case args of [path] -> makeAbsolute path; _ -> ioError (userError "Pass a fresh test directory")
  exists <- doesPathExist root
  check "test directory must be fresh" (not exists)
  original <- must (startGame "settlement" defaultPack)
  village <- must (startVillageGame "settlement" defaultPack)
  let plan name x y rotation = decide (Plan (Space.BuildingShape name (Space.Tile x y) rotation)) village
  check "mine beside ore is constructible" (case plan "mine" 12 20 Space.R0 of Right _ -> True; _ -> False)
  check "quarry beside stone is constructible" (case plan "quarry" 20 100 Space.R0 of Right _ -> True; _ -> False)
  check "quarry beside sand is constructible" (case plan "quarry" 92 108 Space.R0 of Right _ -> True; _ -> False)
  check "mine entrance cannot cross the ore region" (case plan "mine" 12 20 Space.R180 of Left reason -> "SourceConflict" `isInfixOf` reason; _ -> False)
  check "mine away from ore is rejected" (case plan "mine" 40 40 Space.R0 of Left reason -> "NoCompatibleSource" `isInfixOf` reason; _ -> False)
  villageState <- maybe (ioError (userError "village map missing")) pure (worldM1 (gameWorld village))
  oreSource <- case [source | source <- M.elems (Space.spatialSources (m1Space villageState)), Space.sourceRegionResource source == Ore] of
    source : _ -> pure source
    [] -> ioError (userError "ore source missing")
  let oreId = Space.sourceRegionId oreSource
      inventory = worldInventory (gameWorld village)
      depletedInventory = inventory {invDeposits = M.adjust (\deposit -> deposit {depositQty = zeroQty}) oreId (invDeposits inventory)}
      depletedVillage = village {gameWorld = (gameWorld village) {worldInventory = depletedInventory}}
  check "adjacent exhausted ore reports depletion, not missing source" (case decide (Plan (Space.BuildingShape "mine" (Space.Tile 12 20) Space.R0)) depletedVillage of Left reason -> "SourceDepleted" `isInfixOf` reason; Right _ -> False)
  check "clear road still queues every stage" (case decide (RoadPath (Space.Tile 40 40) (Space.Tile 42 40)) village of Right planned -> length (gameBuildQueue planned) == 3; Left _ -> False)
  check "road crossing an aquifer fails before any plan is queued" (case decide (RoadPath (Space.Tile 58 53) (Space.Tile 67 51)) village of Left reason -> "SourceConflict" `isInfixOf` reason && null (gameBuildQueue village); Right _ -> False)
  warehousePlan <- must (plan "warehouse" 30 40 Space.R90)
  warehouseState <- maybe (ioError (userError "warehouse plan missing map")) pure (worldM1 (gameWorld warehousePlan))
  let warehouseIds = [Space.placementId placement | placement <- M.elems (Space.spatialPlacements (m1Space warehouseState)), Space.BuildingShape "warehouse" (Space.Tile 30 40) Space.R90 <- [Space.placementShape placement]]
  check "rotated warehouse worksite marks its actual external road connector" (case warehouseIds of [ident] -> worksiteRoadConnector warehousePlan ident == Just (Space.Tile 29 41); _ -> False)
  let sourceRoads = Set.fromList ([Space.Tile x 53 | x <- [13 .. 58]] ++ [Space.Tile 13 y | y <- [24 .. 53]])
      sourceFixture = s01FixtureAt "red-dune-live-1" "native-resource-delivery" villageLayouts (Set.union villageRoads sourceRoads)
  sourceGame <- must (startGameWith sourceFixture "settlement" defaultPack)
  sourceService <- must (decide (Commission ServiceWorks) sourceGame)
  sourcePlan <- must (decide (Plan (Space.BuildingShape "mine" (Space.Tile 12 20) Space.R0)) sourceService)
  plannedState <- maybe (ioError (userError "planned map missing")) pure (worldM1 (gameWorld sourcePlan))
  mineId <- case [Space.placementId placement | placement <- M.elems (Space.spatialPlacements (m1Space plannedState)), Space.BuildingShape name _ _ <- [Space.placementShape placement], name == "mine"] of
    ident : _ -> pure ident
    [] -> ioError (userError "mine plan missing")
  check "planned mine keeps its construction entrance" (case worksiteRoadConnector sourcePlan mineId of Just _ -> True; Nothing -> False)
  sourceWater <- must (decide (Commission WaterWorks) sourcePlan)
  sourceActive <- must (decide ToggleTime sourceWater)
  let waitForMine remaining game
        | M.member mineId (worldSites (gameWorld game)) = pure game
        | remaining <= 0 = ioError (userError "mine was not built through delivery and construction")
        | otherwise = must (advanceGame 1200 game) >>= waitForMine (remaining - 1)
  sourceBuilt <- waitForMine (12 :: Int) sourceActive
  check "built mine has no construction entrance marker" (worksiteRoadConnector sourceBuilt mineId == Nothing)
  sourceWorking <- must (decide (StartSite mineId) sourceBuilt)
  sourceHarvested <- must (advanceGame 1200 sourceWorking)
  check "real mine produces physical ore after road delivery, crews, and a production batch" (Policies.physical (gameWorld sourceHarvested) (Owner MachineOutput mineId) Ore > 0)
  setup <- foldM (\game dept -> must (decide (Commission dept) game)) original [WaterWorks, FoodWorks, ServiceWorks]
  check "commissioning does not create resources" (invLots (worldInventory (gameWorld original)) == invLots (worldInventory (gameWorld setup)))
  check "commissioning does not advance time" (simTick (gameWorld original) == simTick (gameWorld setup))
  active <- must (decide ToggleTime setup)
  played <- must (advanceGame 1200 active)
  Store.withStore root $ \store -> do
    collision <- try (Store.withStore root (const (pure ()))) :: IO (Either IOException ())
    check "exclusive process lock" (case collision of Left _ -> True; _ -> False)
    activated <- Store.activateGame store played
    check "fresh paused authority" (worldAuthority (gameWorld activated) /= worldAuthority (gameWorld played) && worldMode (gameWorld activated) == Paused)
    first <- Store.saveGame store activated
    preview <- Store.previewCheckpoint store first
    check "exact preview" (Store.previewGame preview == activated)
    restored <- Store.confirmCheckpoint store preview
    check "fresh branch on confirmation" (branchId (gameWorld restored) > branchId (gameWorld activated))
    source <- BS.readFile (root </> first)
    check "source survives confirmation" (decodeGame source == Right activated)
    a <- must (decide ToggleTime activated) >>= must . advanceGame 200
    b <- must (decide ToggleTime restored) >>= must . advanceGame 200
    let stockView world = M.map (\lot -> (lotOwner lot, lotResource lot, lotQty lot, lotBorn lot, lotExpires lot, lotProvenance lot)) (invLots (worldInventory world))
    check "restored physical suffix" (stockView (gameWorld a) == stockView (gameWorld b) && invLedger (worldInventory (gameWorld a)) == invLedger (worldInventory (gameWorld b)) && worldJobs (gameWorld a) == worldJobs (gameWorld b) && worldNeeds (gameWorld a) == worldNeeds (gameWorld b) && simTick (gameWorld a) == simTick (gameWorld b))
    originalBytes <- BS.readFile (root </> first)
    BS.writeFile (root </> first) (BS.take 80 originalBytes)
    rejected <- try (Store.confirmCheckpoint store preview) :: IO (Either IOException GameState)
    check "changed preview rejected" (case rejected of Left _ -> True; _ -> False)
    BS.writeFile (root </> first) originalBytes
    catalog <- Store.checkpoints store
    check "immutable saves listed" (length catalog >= 3)
    replicateM_ 12 (Store.saveGame store restored)
    ordered <- Store.checkpoints store
    check "numeric checkpoint order" (case ordered of latest : _ -> Store.checkpointBranch latest == branchId (gameWorld restored) && Store.checkpointSequence latest == 13; _ -> False)
    BS.writeFile (root </> "corrupted.rdlive") (BS.take 80 originalBytes)
    damaged <- Store.checkpointCatalog store
    check "a corrupt save does not hide healthy saves" (Store.catalogUnreadable damaged == 1 && length (Store.catalogEntries damaged) == length ordered)
    BS.writeFile (root </> "b-999-s-1.rdlive") (BS.take 80 originalBytes)
    latestHealthy <- Store.latestCheckpointCatalog store
    check "startup skips newest corrupt save" (Store.catalogUnreadable latestHealthy == 1 && take 1 ordered == Store.catalogEntries latestHealthy)
    pages <- mapM (Store.checkpointPage store) [0 .. (Store.catalogTotal latestHealthy - 1) `div` 7]
    check "every historic save remains accessible" (concatMap Store.catalogEntries pages == ordered && sum (map Store.catalogUnreadable pages) == 2)
    defaultUi <- Store.loadPreferences store
    check "missing UI settings use independent defaults" (defaultUi == (Help.defaultPreferences, Nothing))
    let preference = Help.Preferences False (Set.fromList [Help.WellHint, Help.RoadHint])
    Store.savePreferences store preference
    savedUi <- Store.loadPreferences store
    check "UI settings have exact flushed readback" (savedUi == (preference, Nothing))
    Store.savePreferences store Help.defaultPreferences
    replacedUi <- Store.loadPreferences store
    check "only UI settings can be replaced" (replacedUi == (Help.defaultPreferences, Nothing))
    unchangedSource <- BS.readFile (root </> first)
    check "preference replacement leaves checkpoint bytes unchanged" (unchangedSource == originalBytes)
    BS.writeFile (root </> "ui-preferences.rdui") (BS.replicate 1025 65)
    corruptUi <- Store.loadPreferences store
    check "oversized UI settings fall back without invalidating the world" (fst corruptUi == Help.defaultPreferences && snd corruptUi /= Nothing)
    healthyWorld <- Store.previewCheckpoint store first
    check "world preview survives UI corruption" (Store.previewGame healthyWorld == activated)
    BS.writeFile (root </> "ui-preferences-7.pending") (BS.pack [1, 2, 3])
    Store.savePreferences store preference
    recoveredUi <- Store.loadPreferences store
    check "stale unfinished UI write does not block a later commit" (recoveredUi == (preference, Nothing))
    traversal <- try (Store.previewCheckpoint store "../escape.rdlive") :: IO (Either IOException Store.Preview)
    check "traversal rejected" (case traversal of Left _ -> True; _ -> False)
    renamed <- try (renameDirectory root (root ++ "-moved")) :: IO (Either IOException ())
    check "directory identity pinned" (case renamed of Left _ -> True; _ -> False)
  -- A process restart reacquires the lock and reads already committed saves.
  Store.withStore root $ \store -> do
    Store.checkpoints store >>= check "restart catalog" . (>= 3) . length
    preferences <- Store.loadPreferences store
    check "guide OFF and seen IDs survive process restart" (fst preferences == Help.Preferences False (Set.fromList [Help.WellHint, Help.RoadHint]) && snd preferences == Nothing)
  Store.withStore (root </> "日本語") $ \store -> do
    saved <- Store.activateGame store original
    name <- Store.saveGame store saved
    preview <- Store.previewCheckpoint store name
    check "Unicode save directory" (Store.previewGame preview == saved)
  putStrLn "PASS native: source placement/depletion, road rejection, physical mine delivery/construction/ore output, commissioning, paused activation, exact readback, immutable branch restore, stale-preview rejection, locking, traversal, directory pinning, restart"
