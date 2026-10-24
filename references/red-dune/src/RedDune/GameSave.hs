{-# OPTIONS_GHC -Wno-orphans #-}

module RedDune.GameSave where

import Colony.Codec
import Colony.Codec.CBOR (CBOR (..), decodeCanonical)
import Colony.Codec.Value
import Colony.Construction qualified as C
import Colony.JSON qualified as J
import Colony.M1State
import Colony.Presentation (arr, num, obj, str)
import Colony.S01Fixture
import Colony.Types
import Colony.World
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as M
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game
import RedDune.Policies

instance ValueCodec Scenario

instance ValueCodec ContentPack

instance ValueCodec DeliveryPolicy

instance ValueCodec Policies

instance ValueCodec Ending

instance ValueCodec CampaignState

instance ValueCodec S01Descriptor

instance ValueCodec GameState

instance ValueCodec PlaceKind

magic :: BS.ByteString
magic = BC.pack "RDLIVE2\n"

previousMagic :: BS.ByteString
previousMagic = BC.pack "RDLIVE1\n"

encodeGame :: GameState -> Either String BS.ByteString
encodeGame game = do
  validateGame game
  payload <- mapFailure (encodeValue game)
  unless (BS.length payload <= 32 * 1024 * 1024) (Left "Live save exceeds 32 MiB")
  pure (magic <> sha256 payload <> payload)

decodeGame :: BS.ByteString -> Either String GameState
decodeGame bytes = do
  unless (BS.length bytes <= 32 * 1024 * 1024 + 40 && BS.length bytes >= 40) (Left "Invalid live save size")
  let version = BS.take 8 bytes
  unless (version == magic || version == previousMagic) (Left "Unsupported live save version; use legacy preview for archived checkpoints")
  let checksum = BS.take 32 (BS.drop 8 bytes); payload = BS.drop 40 bytes
  unless (checksum == sha256 payload) (Left "Live save checksum mismatch")
  game <- if version == previousMagic then decodePrevious payload else mapFailure (decodeValue payload)
  validateGame game
  pure game

-- V1 has exactly nine mandatory fields and the original two-field NeedsState.
-- Append empty scenery/dining collections; never guess a future wire schema.
decodePrevious :: BS.ByteString -> Either String GameState
decodePrevious payload = do
  value <- mapFailure (decodeCanonical payload)
  case value of
    CMap [(0, CInteger 0), (1, CMap fields)] | map fst fields == [0 .. 8] -> do
      case lookup 0 fields of
        Just (CMap [(0, CInteger 4), (1, CMap [(0, CMap [(0, CInteger 0), (1, CMap common)]), (1, _)])]) ->
          case lookup 22 common of
            Just (CMap [(0, CInteger 0), (1, CMap [(0, _), (1, _)])]) -> pure ()
            _ -> Left "Invalid live V1 needs record"
        _ -> Left "Invalid live V1 world record"
      mapFailure (fromCBOR (CMap [(0, CInteger 0), (1, CMap (fields ++ [(9, CArray []), (10, CArray [])]))]))
    _ -> Left "Invalid live V1 record"

previewLegacy :: BS.ByteString -> Either String J.JSON
previewLegacy bytes = do
  (meta, world) <- mapFailure (decodeCheckpoint bytes)
  let compatible = worldRuleset world == "red-dune-reference-6" && worldM1 world /= Nothing
  pure
    ( obj
        [ ("status", str "legacyPreview"),
          ("ruleset", str (worldRuleset world)),
          ("world", num (worldId world)),
          ("branch", num (branchId world)),
          ("tick", let SimTick t = simTick world in num t),
          ("metadata", str (show meta)),
          ("canImport", J.JBool compatible),
          ("preserved", arr (map str ["Source checkpoint bytes remain untouched", "Physical stock, jobs, residents and transport are validated by the archived decoder", "No campaign achievements, policy history or stability credit are invented"])),
          ("changes", arr (map str (if compatible then ["Import as a paused legacy sandbox under the live profile", "Explicitly update pump/road construction snapshot versions; keep their exact cost/progress", "Campaign objectives remain disabled for imported saves"] else ["Readable archive; continuation remains in the 0.6 executable because its fixture/profile is outside the live import scope"])))
        ]
    )

-- Deliberately scoped: S01 profile 6 uses the known fixed descriptor. Other
-- historical schemas are readable/previewable, never guessed into a campaign.
importLegacy :: BS.ByteString -> Either String GameState
importLegacy bytes = do
  (_, old) <- mapFailure (decodeCheckpoint bytes)
  unless (worldRuleset old == "red-dune-reference-6") (Left "Only S01 profile 6 can enter the live legacy sandbox")
  (d, original) <- mapFailure (s01Fixture (worldContent old))
  unless (all (`M.member` worldSites old) (M.keys (worldSites original))) (Left "Legacy S01 physical descriptor differs")
  converted <- case worldM1 old of
    Nothing -> Left "Legacy S01 lacks physical state"
    Just state -> do
      jobs <- mapM (\job -> do snapshot <- mapFailure (C.snapshotForRuleset "red-dune-live-1" (worldContent old) (C.constructionShape job)); pure job {C.constructionSnapshot = snapshot}) (C.constructionJobs (m1Construction state))
      pure state {m1Scenario = "red-dune-live-1", m1Construction = (m1Construction state) {C.constructionJobs = jobs}}
  let pack = defaultPack {packEconomy = worldContent old}
      world =
        old
          { worldRuleset = "red-dune-live-1",
            worldMode = Paused,
            worldM1 = Just converted,
            worldParticipants = M.insert 2 (Participant OperatorRole (Epoch (worldAuthority old) 1)) (worldParticipants old)
          }
      scenario = packScenarios pack M.! "settlement"
      campaign = (initialCampaign scenario world) {campaignImported = True}
      game = GameState world d pack Nothing campaign emptyPolicies 1 [] ["Legacy sandbox: physical state preserved; campaign achievements are intentionally unavailable"] M.empty M.empty
  validateGame game
  pure game
