-- Real archived schema-3/4 checkpoints, imported through the public save API.
-- Active witnesses use ordinary commands and ticks, without grants or state edits.
module Main where

import Colony.Codec
import Colony.Construction qualified as C
import Colony.Fixture (fourColonyFixture)
import Colony.JSON qualified as J
import Colony.Jobs
import Colony.KnownCatalog (knownCatalogV1, knownCatalogV2)
import Colony.M1State
import Colony.Presentation (obj, str)
import Colony.S01Fixture
import Colony.Scheduler (pureStep)
import Colony.Space qualified as S
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as W
import Colony.World
import Control.Exception (bracket)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.GameSave
import RedDune.Policies
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openBinaryTempFile)

check :: String -> Bool -> IO ()
check label ok = unless ok (ioError (userError ("LEGACY IMPORT: " ++ label)))

must :: (Show e) => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

m1 :: World -> M1State
m1 = maybe (error "legacy test expected M1 state") id . worldM1

construction :: EntityId -> World -> C.ConstructionJob
construction ident world = C.constructionJobs (m1Construction (m1 world)) M.! ident

step :: Bool -> [Command] -> [ManagementEvent] -> World -> IO (World, ColonyOutput)
step advance commands management world = do
  let epoch = participantEpoch (worldParticipants world M.! 1)
      highest = M.findWithDefault 0 (1, epoch) (worldHighWater world)
      ordered = [OrderedCommand ordinal (CommandId (worldId world) 1 epoch (highest + ordinal + 1)) command | (ordinal, command) <- zip [0 ..] commands]
      header = BoundaryHeader (worldId world) (branchId world) (boundarySeq world) advance (worldAuthority world) (worldRuleset world)
      (next, out) = pureStep (Boundary header ordered management) world
  check ("kernel diagnostics " ++ show (outputDiagnostics out)) (null (outputDiagnostics out))
  check ("command admission " ++ show (outputReceipts out)) (all (\receipt -> case receiptOutcome receipt of Applied _ -> True; _ -> False) (outputReceipts out))
  must "valid committed legacy world" (validateWorld next)
  pure (next, out)

accept :: Bool -> [Command] -> [ManagementEvent] -> World -> IO World
accept advance commands management world = fst <$> step advance commands management world

plan :: S01Descriptor -> S.PlacementShape -> World -> IO (EntityId, World)
plan descriptor shape world = do
  (next, out) <- step False [PlaceConstructionPlan (s01Colony descriptor) shape 2 Nothing] [] world
  case [ident | receipt <- outputReceipts out, Applied (Just ident) <- [receiptOutcome receipt]] of
    [ident] -> pure (ident, next)
    _ -> ioError (userError "legacy plan did not return exactly one identity")

untilBound :: String -> Int -> (World -> Bool) -> World -> IO World
untilBound label remaining predicate world
  | predicate world = pure world
  | remaining == 0 = ioError (userError ("legacy witness timed out: " ++ label ++ " at " ++ show (simTick world)))
  | otherwise = accept True [] [] world >>= untilBound label (remaining - 1) predicate

checkPreview :: Bool -> World -> BS.ByteString -> IO ()
checkPreview compatible world bytes = do
  fields <- must "legacy preview" (previewLegacy bytes >>= J.object)
  check "preview status" (M.lookup "status" fields == Just (str "legacyPreview"))
  check "preview exact archived profile" (M.lookup "ruleset" fields == Just (str (worldRuleset world)))
  check "preview explicit compatibility" (M.lookup "canImport" fields == Just (J.JBool compatible))

checkImport :: String -> World -> IO GameState
checkImport label old = do
  let meta = CheckpointMeta 17 Nothing ("executed-live-legacy-" ++ label)
  bytes <- must "encode archived checkpoint" (encodeCheckpoint meta old)
  decoded <- must "decode original checkpoint" (decodeCheckpoint bytes)
  check "archived checkpoint exact round trip" (decoded == (meta, old))
  directory <- getTemporaryDirectory
  bracket
    (do (path, handle) <- openBinaryTempFile directory "red-dune-legacy.chk"; BS.hPut handle bytes; hClose handle; pure path)
    removeFile
    ( \path -> do
        source <- BS.readFile path
        checkPreview True old source
        imported <- must "import archived checkpoint" (importLegacy source)
        after <- BS.readFile path
        check "source checkpoint file remains byte-identical" (after == bytes && sha256 after == sha256 source)
        let world = gameWorld imported
            oldState = m1 old
            newState = m1 world
            oldJobs = C.constructionJobs (m1Construction oldState)
            newJobs = C.constructionJobs (m1Construction newState)
            scenario = packScenarios defaultPack M.! "settlement"
            expectedCampaign = (initialCampaign scenario world) {campaignImported = True}
        check "import is paused live sandbox" (worldMode world == Paused && worldRuleset world == C.liveConstructionRuleset)
        check "inventory including stock and reservations exactly preserved" (worldInventory world == worldInventory old)
        check "residents and needs exactly preserved" (worldNeeds world == worldNeeds old)
        check "sites exactly preserved" (worldSites world == worldSites old)
        check "production jobs exactly preserved" (worldJobs world == worldJobs old && worldJobSites world == worldJobSites old)
        check "transport routes, requests, cargo and vehicles exactly preserved" (worldTransport world == worldTransport old)
        check "construction identities unchanged" (M.keys newJobs == M.keys oldJobs)
        forM_ (M.toList oldJobs) $ \(ident, job) -> do
          snapshot <- must "explicit live snapshot conversion" (C.snapshotForRuleset C.liveConstructionRuleset (worldContent old) (C.constructionShape job))
          check "only construction snapshot changes" (M.lookup ident newJobs == Just job {C.constructionSnapshot = snapshot})
          let archived = C.constructionSnapshot job
          check "exact construction cost, work and crew preserved" (C.constructionCost snapshot == C.constructionCost archived && C.constructionRequired snapshot == C.constructionRequired archived && C.constructionCrewRequired snapshot == C.constructionCrewRequired archived)
          check "construction version explicitly upgraded" (C.constructionRuleVersion archived == 1 && C.constructionRuleVersion snapshot == 2)
        let expectedM1 = oldState {m1Scenario = C.liveConstructionRuleset, m1Construction = (m1Construction oldState) {C.constructionJobs = newJobs}}
            expectedWorld = old {worldRuleset = C.liveConstructionRuleset, worldMode = Paused, worldM1 = Just expectedM1, worldParticipants = M.insert 2 (Participant OperatorRole (Epoch (worldAuthority old) 1)) (worldParticipants old)}
        check "entire physical world differs only by documented import fields" (world == expectedWorld)
        check "no campaign evidence, stability, ending or progress invented" (gameCampaign imported == expectedCampaign)
        check "no automation history or construction queue invented" (gamePolicies imported == emptyPolicies && null (gameBuildQueue imported) && gameStagedPack imported == Nothing)
        saved <- must "encode imported live checkpoint" (encodeGame imported)
        loaded <- must "decode imported live checkpoint" (decodeGame saved)
        check "complete imported live checkpoint exact round trip" (loaded == imported)
        resumed <- fst <$> must "resume imported sandbox" (applyAction (obj [("op", str "resume")]) imported)
        resumedLoaded <- fst <$> must "resume loaded sandbox" (applyAction (obj [("op", str "resume")]) loaded)
        continued <- must "advance imported sandbox" (advanceGame 5 resumed)
        continuedLoaded <- must "advance loaded sandbox" (advanceGame 5 resumedLoaded)
        check "live reload resumes identical physical evolution" (continuedLoaded == continued && simTick (gameWorld continued) > simTick world)
        check "imported campaign remains disabled after real ticks" (gameCampaign continued == expectedCampaign)
        putStrLn ("LEGACY_IMPORT " ++ label ++ " PASS")
        pure imported
    )

otherProfiles :: IO ()
otherProfiles = forM_ [0, 1, 2, 3, 4, 5, 7 :: Int] $ \profile -> do
  let rules = "red-dune-reference-" ++ show profile
      content = if odd profile then knownCatalogV2 else knownCatalogV1
  world <-
    if profile == 7
      then snd <$> must "other S01 profile" (s01FixtureWithRuleset rules content)
      else do
        fixture <- must "other archived fixture" (fourColonyFixture content)
        pure fixture {worldRuleset = rules}
  bytes <- must "encode other archived profile" (encodeCheckpoint defaultCheckpointMeta world)
  checkPreview False world bytes
  check ("other profile has explicit import rejection: " ++ rules) (importLegacy bytes == Left "Only S01 profile 6 can enter the live legacy sandbox")

main :: IO ()
main = do
  (descriptor, original) <- must "original S01 fixture" (s01Fixture knownCatalogV1)
  _ <- checkImport "initial-S01" original
  staffed <- accept False (s01RosterCommands descriptor) [] original
  (pump, withPump) <- plan descriptor (S.BuildingShape "hand_pump" (S.Tile 64 60) S.R0) staffed
  (road, planned) <- plan descriptor (S.RoadShape (S.Tile 61 64)) withPump
  let builders = take 2 (drop 11 (s01ShiftResidents descriptor M.! 0))
      home = head (s01Warehouses descriptor)
  supplied <- accept False [AssignWorkers (W.ConstructSite road) 0 builders, RequestDelivery home (Owner MachineInput road) Stone 2000 2, OrderProduction (s01Pump descriptor)] [ResumeWorld] planned
  carrying <- untilBound "real loaded shipment" 500 (any ((== ShipmentCarrying) . shipmentStatus) . M.elems . transportShipments . worldTransport) supplied
  check "active production exists in archived save" (any ((== Running) . jobPhase) (M.elems (worldJobs carrying)))
  _ <- checkImport "in-transit-with-active-plans" carrying
  working <- untilBound "road actually starts" 500 ((== C.ConstructionRunning) . C.constructionPhase . construction road) carrying
  check "running road has nonzero partial progress" (C.constructionProgress (construction road working) > 0 && C.constructionProgress (construction road working) < C.constructionRequired (C.constructionSnapshot (construction road working)))
  imported <- checkImport "running-road-with-planned-pump" working
  let importedWorld = gameWorld imported
  check "hand pump kind upgrades explicitly" (C.constructionKind (C.constructionSnapshot (construction pump working)) == C.BuildHandPump && C.constructionKind (C.constructionSnapshot (construction pump importedWorld)) == C.BuildFacility "hand_pump")
  check "road kind retained" (C.constructionKind (C.constructionSnapshot (construction road importedWorld)) == C.BuildRoad)
  resumed <- fst <$> must "resume imported running road" (applyAction (obj [("op", str "resume")]) imported)
  finished <- must "finish imported road through live ticks" (advanceGame 30 resumed)
  let completedRoad = construction road (gameWorld finished)
      consumed world = M.findWithDefault 0 (Stone, ConstructionConsumed) (invLedger (worldInventory world))
  check "imported running road completes exactly once" (C.constructionPhase completedRoad == C.ConstructionCompleted && C.constructionTerminalCount completedRoad == 1)
  check "live completion consumes only the preserved exact road cost" (consumed (gameWorld finished) - consumed importedWorld == 2000)
  check "real imported completion still earns no campaign progress" (gameCampaign finished == gameCampaign imported)
  otherProfiles
  putStrLn "PASS: archived schemas 3/4; exact S01 import with production, loaded transport, running road, planned hand pump, source-byte integrity, live save/reload/resume and seven readable-but-rejected profiles"
