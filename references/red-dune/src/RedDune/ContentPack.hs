{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module RedDune.ContentPack where

import Colony.Codec.SHA256 (sha256)
import Colony.Content
import Colony.ContentCodec (contentIdentity)
import Colony.JSON qualified as J
import Colony.KnownCatalog (knownCatalogV1)
import Colony.Presentation (encodeJSON)
import Colony.S01Fixture (s01FixtureWithRuleset)
import Colony.Units (quantityMax)
import Control.DeepSeq (NFData)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric (showHex)

data Scenario = Scenario
  { scenarioId :: !String,
    scenarioTitle :: !String,
    scenarioBrief :: !String,
    scenarioHours :: !Integer,
    scenarioStableHours :: !Integer,
    scenarioRationPercent :: !Integer,
    scenarioDisruptionHour :: !Integer,
    scenarioStartsBroken :: !Bool,
    scenarioFreshFood :: !Integer
  }
  deriving (Eq, Show, Read, Generic, NFData)

data ContentPack = ContentPack
  { packRevision :: !Word64,
    packTitle :: !String,
    packEconomy :: !Content,
    packScenarios :: !(M.Map String Scenario)
  }
  deriving (Eq, Show, Read, Generic, NFData)

hex :: BS.ByteString -> String
hex = concatMap (\b -> let s = showHex b "" in replicate (2 - length s) '0' ++ s) . BS.unpack

packIdentity :: ContentPack -> String
packIdentity = hex . sha256 . TE.encodeUtf8 . T.pack . show

defaultPack :: ContentPack
defaultPack =
  ContentPack
    1
    "Red Dune: A Settlement That Lasts"
    knownCatalogV1
    ( M.fromList
        [ (scenarioId s, s)
        | s <-
            [ Scenario "settlement" "A Settlement That Lasts" "Forty settlers have three days of runway. Staff every shift, grow food, route physical supplies, build useful capacity and recover from an announced kitchen failure. Then hold a full day of reliable service." 66 24 100 24 False 10000,
              Scenario "recovery" "The Broken Supply Line" "The reserve ration shipment never arrived and the kitchen is broken. Twelve hours of pantry food remain. Restore it, bring the farm online, build a reserve store and hold eighteen hours of recovery." 42 18 25 0 True 10000
            ]
        ]
    )

validatePack :: ContentPack -> Either String ()
validatePack pack = do
  unless (packRevision pack > 0) (Left "Pack revision must be positive")
  unless (not (null (packTitle pack)) && length (packTitle pack) <= 160) (Left "Pack title must contain 1..160 characters")
  validateContent (packEconomy pack)
  -- A staged pack must actually initialize the authored spatial scenario,
  -- not merely pass a JSON schema before failing on the next restart.
  _ <- either (Left . ("Pack cannot initialize scenario: " ++) . show) Right (s01FixtureWithRuleset "red-dune-live-1" (packEconomy pack))
  _ <- contentIdentity (packEconomy pack)
  unless (M.keysSet (packScenarios pack) == M.keysSet (packScenarios defaultPack)) (Left "Pack must author settlement and recovery scenarios")
  forM_ (M.toList (packScenarios pack)) $ \(key, s) -> do
    unless (key == scenarioId s && not (null (scenarioTitle s)) && length (scenarioBrief s) <= 2000) (Left "Invalid scenario identity/title/brief")
    unless (scenarioHours s >= 24 && scenarioHours s <= 240 && scenarioStableHours s >= 6 && scenarioStableHours s <= scenarioHours s) (Left "Scenario duration/stability bounds")
    unless (scenarioRationPercent s >= 10 && scenarioRationPercent s <= 100 && scenarioDisruptionHour s >= 0 && scenarioDisruptionHour s < scenarioHours s) (Left "Scenario supply/disruption bounds")
    unless (scenarioFreshFood s >= 1000 && scenarioFreshFood s <= 100000) (Left "Fresh food objective outside 1000..100000")
  -- Initial fixed layout and 40 named residents constrain geometry/workforce.
  -- Recipe amounts/work, economic costs, labels and maintenance periods remain editable.
  forM_ (M.toList (contentBuildings knownCatalogV1)) $ \(key, b) -> do
    actual <- lookupBuilding (packEconomy pack) key
    unless (buildingFootprint actual == buildingFootprint b && buildingWorkers actual == buildingWorkers b) (Left "Live layout pins building footprints and worker counts")
  forM_ ["warehouse", "pantry", "tank", "housing"] $ \key -> do
    b <- lookupBuilding (packEconomy pack) key
    unless (buildingPower b == 0 && buildingMaintenancePeriod b == 0) (Left "Passive storage/housing must remain unpowered and maintenance-free")
  kitchen <- lookupBuilding (packEconomy pack) "kitchen"
  unless (buildingMaintenancePeriod kitchen > 0) (Left "The authored kitchen disruption requires a maintainable kitchen")
  unless (buildingMaintenancePeriod kitchen <= quantityMax `div` 2) (Left "Kitchen disruption age would exceed the facility limit")
  forM_ [("hand_water", "hand_pump"), ("grow", "farm"), ("cook", "kitchen")] $ \(recipeName, buildingName) -> do
    r <- lookupRecipe (packEconomy pack) recipeName
    unless (recipeBuilding r == buildingName) (Left "Essential recipe/building binding is pinned by the campaign")
  forM_ (M.elems (contentRecipes (packEconomy pack))) $ \r -> do
    unless (recipeWorkTicks r >= 20 && recipeWorkTicks r <= 28800) (Left "Recipe work must be 20..28800 ticks")
    let load vector = sum [q * resourceLoad def | (res, q) <- M.toList vector, Just def <- [M.lookup res (contentResources (packEconomy pack))]]
    unless (load (recipeInputs r) <= 400000 && load (recipeOutputs r) <= 400000) (Left "Recipe exceeds physical machine capacity")

decodePack :: String -> Either String ContentPack
decodePack source = do
  unless (length source <= 8 * 1024 * 1024) (Left "Pack exceeds 8 MiB")
  root <- J.parseJSON source >>= J.object
  J.fieldsExactly ["schema", "revision", "title", "economy", "scenarios"] root
  schema <- J.field "schema" root >>= J.string
  unless (schema == "red-dune-pack-1") (Left "Unsupported pack schema")
  n <- J.field "revision" root >>= J.integer
  unless (n > 0 && n <= toInteger (maxBound :: Word64)) (Left "Pack revision outside Word64")
  title <- J.field "title" root >>= J.string
  economy <- J.field "economy" root >>= decodeContent . encodeJSON
  entries <- J.field "scenarios" root >>= J.array >>= mapM decodeScenario
  unless (length entries == M.size (M.fromList [(scenarioId s, s) | s <- entries])) (Left "Duplicate scenario ID")
  let pack = ContentPack (fromInteger n) title economy (M.fromList [(scenarioId s, s) | s <- entries])
  validatePack pack
  pure pack
  where
    decodeScenario value = do
      o <- J.object value
      J.fieldsExactly ["id", "title", "brief", "hours", "stableHours", "rationPercent", "disruptionHour", "startsBroken", "freshFood"] o
      let text k = J.field k o >>= J.string; number k = J.field k o >>= J.integer
      Scenario <$> text "id" <*> text "title" <*> text "brief" <*> number "hours" <*> number "stableHours" <*> number "rationPercent" <*> number "disruptionHour" <*> (J.field "startsBroken" o >>= J.boolean) <*> number "freshFood"
