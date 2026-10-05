{-# LANGUAGE DeriveGeneric #-}
-- | The sole loader for the versioned content package used by simulation and UI.
-- Maps are built only after duplicate-ID checks, and a Content is accepted only
-- after the reference, dependency, dimensional, range and extraction checks.
module Colony.Content
  ( Content(..), ResourceDef(..), Recipe(..), Building(..), NaturalSource(..)
  , Tech(..), Campaign(..), loadContent, decodeContent, validateContent
  , lookupResource, lookupRecipe, lookupBuilding, buildingPort
  ) where

import Colony.Units
import qualified Colony.JSON as J
import Control.DeepSeq (NFData, force)
import Control.Exception (IOException, evaluate, try)
import Control.Monad (unless, when, forM_)
import Data.Binary (Binary)
import qualified Data.ByteString as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Graph (SCC(..), stronglyConnComp)
import Data.List (group, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

data ResourceDef = ResourceDef
  { resourceId :: Resource
  , resourceLabel :: String
  , resourceUnit :: String
  , resourceLoad :: Integer
  , resourceShelfLife :: Maybe Integer
  } deriving (Eq, Show, Read, Generic)
instance NFData ResourceDef
instance Binary ResourceDef

data Recipe = Recipe
  { recipeId :: String
  , recipeLabel :: String
  , recipeBuilding :: String
  , recipeWorkTicks :: Integer
  , recipeInputs :: M.Map Resource Integer
  , recipeOutputs :: M.Map Resource Integer
  , recipeNaturalSources :: M.Map String Integer
  } deriving (Eq, Show, Read, Generic)
instance NFData Recipe
instance Binary Recipe

data Building = Building
  { buildingId :: String
  , buildingLabel :: String
  , buildingFootprint :: (Integer, Integer)
  , buildingBuildWorkTicks :: Integer
  , buildingWorkers :: Integer
  , buildingPower :: Integer
  , buildingCost :: M.Map Resource Integer
  , buildingMaintenancePeriod :: Integer
  , buildingMaintenanceWorkTicks :: Integer
  , buildingMaintenanceParts :: Integer
  , buildingUnlock :: String
  } deriving (Eq, Show, Read, Generic)
instance NFData Building
instance Binary Building

data NaturalSource = NaturalSource
  { naturalSourceId :: String
  , naturalSourceResource :: Resource
  , naturalSourceRegenerates :: Bool
  } deriving (Eq, Show, Read, Generic)
instance NFData NaturalSource
instance Binary NaturalSource

data Tech = Tech
  { techId :: String
  , techRequires :: [String]
  , techPoints :: Integer
  } deriving (Eq, Show, Read, Generic)
instance NFData Tech
instance Binary Tech

data Campaign = Campaign
  { campaignId :: String
  , campaignRequires :: [String]
  } deriving (Eq, Show, Read, Generic)
instance NFData Campaign
instance Binary Campaign

data Content = Content
  { contentVersion :: String
  , contentStatus :: String
  , contentTickHz :: Integer
  , contentGameSecondsPerTick :: Integer
  , contentTicksPerDay :: Integer
  , contentQuantityMax :: Integer
  , contentResources :: M.Map Resource ResourceDef
  , contentRecipes :: M.Map String Recipe
  , contentBuildings :: M.Map String Building
  , contentNaturalSources :: M.Map String NaturalSource
  , contentTechs :: M.Map String Tech
  , contentCampaign :: M.Map String Campaign
  } deriving (Eq, Show, Read, Generic)
instance NFData Content
instance Binary Content

loadContent :: FilePath -> IO (Either String Content)
loadContent path = do
  result <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
  case result of
    Left err -> pure (Left ("Content read failed: " ++ show err))
    Right bytes
      | BS.length bytes > 8*1024*1024 -> pure (Left "Content package exceeds 8 MiB limit")
      | otherwise -> case TE.decodeUtf8' bytes of
          Left err -> pure (Left ("Content is not valid UTF-8: " ++ show err))
          Right txt -> evaluate (force (decodeContent (T.unpack txt)))

decodeContent :: String -> Either String Content
decodeContent input = do
  json <- J.parseJSON input
  obj <- schema ["spec_version", "status", "tick_hz", "game_seconds_per_tick",
                 "ticks_per_game_day", "quantity_max", "resources", "recipes",
                 "buildings", "natural_sources", "techs", "campaign"] json
  rs <- rows "resources" parseResourceDef obj >>= uniqueMap "resource" resourceId
  recipes <- rows "recipes" parseRecipe obj >>= uniqueMap "recipe" recipeId
  bs <- rows "buildings" parseBuilding obj >>= uniqueMap "building" buildingId
  ns <- rows "natural_sources" parseNaturalSource obj >>= uniqueMap "natural source" naturalSourceId
  ts <- rows "techs" parseTech obj >>= uniqueMap "tech" techId
  cs <- rows "campaign" parseCampaign obj >>= uniqueMap "campaign" campaignId
  content <- Content <$> str "spec_version" obj <*> str "status" obj
    <*> num "tick_hz" obj <*> num "game_seconds_per_tick" obj
    <*> num "ticks_per_game_day" obj <*> num "quantity_max" obj
    <*> pure rs <*> pure recipes <*> pure bs <*> pure ns <*> pure ts <*> pure cs
  validateContent content
  pure content

schema :: [String] -> J.JSON -> Either String (M.Map String J.JSON)
schema keys json = do
  obj <- J.object json
  J.fieldsExactly keys obj
  pure obj
str :: String -> M.Map String J.JSON -> Either String String
str name obj = J.field name obj >>= J.string
num :: String -> M.Map String J.JSON -> Either String Integer
num name obj = J.field name obj >>= J.integer
rows :: String -> (J.JSON -> Either String a) -> M.Map String J.JSON -> Either String [a]
rows name parser obj = do
  xs <- J.field name obj >>= J.array
  mapM (context name . parser) xs
context :: String -> Either String a -> Either String a
context label = either (Left . ((label ++ ": ") ++)) Right

parseResourceDef :: J.JSON -> Either String ResourceDef
parseResourceDef json = do
  obj <- schema ["id", "label", "unit", "load_g_per_unit", "shelf_life_ticks"] json
  expiry <- J.field "shelf_life_ticks" obj >>= \j -> case j of
    J.JNull -> Right Nothing
    _ -> Just <$> J.integer j
  ResourceDef <$> (str "id" obj >>= parseResource) <*> str "label" obj
    <*> str "unit" obj <*> num "load_g_per_unit" obj <*> pure expiry

parseRecipe :: J.JSON -> Either String Recipe
parseRecipe json = do
  obj <- schema ["id", "label", "building", "work_ticks", "inputs", "outputs", "natural_sources"] json
  Recipe <$> str "id" obj <*> str "label" obj <*> str "building" obj
    <*> num "work_ticks" obj <*> resourceVector "inputs" obj <*> resourceVector "outputs" obj
    <*> numberVector "natural_sources" obj

parseBuilding :: J.JSON -> Either String Building
parseBuilding json = do
  obj <- schema ["id", "label", "footprint", "build_work_ticks", "workers", "power_w", "cost",
                 "maintenance_period_ticks", "maintenance_work_ticks", "maintenance_parts", "unlock"] json
  footprint <- J.field "footprint" obj >>= J.array >>= mapM J.integer
  size <- case footprint of
    [w,h] -> Right (w,h)
    _ -> Left "footprint must contain exactly two integer dimensions"
  Building <$> str "id" obj <*> str "label" obj <*> pure size
    <*> num "build_work_ticks" obj <*> num "workers" obj <*> num "power_w" obj
    <*> resourceVector "cost" obj <*> num "maintenance_period_ticks" obj
    <*> num "maintenance_work_ticks" obj <*> num "maintenance_parts" obj <*> str "unlock" obj

parseNaturalSource :: J.JSON -> Either String NaturalSource
parseNaturalSource json = do
  obj <- schema ["id", "resource", "regenerates"] json
  NaturalSource <$> str "id" obj <*> (str "resource" obj >>= parseResource)
    <*> (J.field "regenerates" obj >>= J.boolean)

parseTech :: J.JSON -> Either String Tech
parseTech json = do
  obj <- schema ["id", "requires", "points"] json
  Tech <$> str "id" obj <*> rows "requires" J.string obj <*> num "points" obj

parseCampaign :: J.JSON -> Either String Campaign
parseCampaign json = do
  obj <- schema ["id", "requires"] json
  Campaign <$> str "id" obj <*> rows "requires" J.string obj

numberVector :: String -> M.Map String J.JSON -> Either String (M.Map String Integer)
numberVector name obj = J.field name obj >>= J.object >>= mapM J.integer
resourceVector :: String -> M.Map String J.JSON -> Either String (M.Map Resource Integer)
resourceVector name obj = do
  xs <- numberVector name obj
  pairs <- mapM (\(key,n) -> (\r -> (r,n)) <$> parseResource key) (M.toList xs)
  pure (M.fromList pairs)

uniqueMap :: (Ord key, Show key) => String -> (a -> key) -> [a] -> Either String (M.Map key a)
uniqueMap label key xs = do
  let duplicates = [head g | g <- group (sort (map key xs)), length g > 1]
  unless (null duplicates) (Left ("Duplicate " ++ label ++ " IDs: " ++ show duplicates))
  pure (M.fromList [(key x,x) | x <- xs])

lookupResource :: Content -> Resource -> Either String ResourceDef
lookupResource content key = maybe (Left ("Unknown resource " ++ show key)) Right (M.lookup key (contentResources content))
lookupRecipe :: Content -> String -> Either String Recipe
lookupRecipe content key = maybe (Left ("Unknown recipe " ++ key)) Right (M.lookup key (contentRecipes content))
lookupBuilding :: Content -> String -> Either String Building
lookupBuilding content key = maybe (Left ("Unknown building " ++ key)) Right (M.lookup key (contentBuildings content))

-- | Southern edge, west-biased for even widths, before rotation. This is a
-- boundary tile offset, not a disconnected tile outside the footprint.
buildingPort :: Building -> (Integer, Integer)
buildingPort b = let (w,h) = buildingFootprint b in ((w-1) `div` 2,h-1)

validateContent :: Content -> Either String ()
validateContent c = do
  unless (contentVersion c == "1.0.0") (Left "Unsupported content spec_version")
  unless (not (null (contentStatus c))) (Left "Empty content status")
  positive "tick_hz" (contentTickHz c)
  positive "game_seconds_per_tick" (contentGameSecondsPerTick c)
  positive "ticks_per_game_day" (contentTicksPerDay c)
  unless (contentGameSecondsPerTick c * contentTicksPerDay c == 86400)
    (Left "Game time constants do not describe a 24-hour day")
  unless (contentQuantityMax c == quantityMax) (Left "quantity_max differs from checked Qty limit")
  unless (M.keysSet (contentResources c) == S.fromList allResources) (Left "Exactly all 16 resources are required")
  countIs "recipes" 18 (contentRecipes c)
  countIs "buildings" 28 (contentBuildings c)
  countIs "natural sources" 5 (contentNaturalSources c)
  keysAre "techs" ["T1","T2","T3","T4","T5","T6"] (contentTechs c)
  keysAre "campaign" ["C0","C1","C2","C3","C4","C5"] (contentCampaign c)
  keyed "resource" resourceId (contentResources c)
  keyed "recipe" recipeId (contentRecipes c)
  keyed "building" buildingId (contentBuildings c)
  keyed "natural source" naturalSourceId (contentNaturalSources c)
  keyed "tech" techId (contentTechs c)
  keyed "campaign" campaignId (contentCampaign c)
  forM_ (M.elems (contentResources c)) $ \r -> context ("resource " ++ show (resourceId r)) $ do
    nonempty "label" (resourceLabel r)
    unless (resourceUnit r == unitFor (resourceId r)) (Left "Unit does not match resource identity")
    positive "load_g_per_unit" (resourceLoad r)
    mapM_ (positive "shelf_life_ticks") (resourceShelfLife r)
    when (resourceId r `notElem` [Crops,Ration] && resourceShelfLife r /= Nothing)
      (Left "Only food resources may expire under v1 spoilage rules")
  validateNaturals c
  validateDependencies c
  forM_ (M.elems (contentRecipes c)) $ \r -> context ("recipe " ++ recipeId r) $ do
    identifier (recipeId r)
    nonempty "label" (recipeLabel r)
    _ <- lookupBuilding c (recipeBuilding r)
    work "work_ticks" (recipeWorkTicks r)
    checkResources c "inputs" (recipeInputs r)
    checkResources c "outputs" (recipeOutputs r)
    when (M.null (recipeOutputs r)) (Left "Recipe must have at least one output")
    forM_ (M.toList (recipeNaturalSources r)) $ \(key,n) -> do
      positive ("natural source quantity " ++ key) n
      unless (M.member key (contentNaturalSources c)) (Left ("Unknown natural source " ++ key))
    unless (M.null (recipeNaturalSources r)) $ do
      unless (M.null (recipeInputs r)) (Left "Extraction recipe cannot also consume process inputs")
      let extraction = M.fromListWith (+)
            [(naturalSourceResource source,n) | (key,n) <- M.toList (recipeNaturalSources r),
             Just source <- [M.lookup key (contentNaturalSources c)]]
      unless (extraction == recipeOutputs r) (Left "Extraction output must exactly match declared natural source withdrawal")
  forM_ (M.elems (contentBuildings c)) $ \b -> context ("building " ++ buildingId b) $ do
    identifier (buildingId b)
    nonempty "label" (buildingLabel b)
    let (w,h) = buildingFootprint b
        (px,py) = buildingPort b
    range "footprint width" 1 512 w
    range "footprint height" 1 512 h
    unless (px >= 0 && px < w && py == h-1) (Left "Building port is outside southern footprint boundary")
    work "build_work_ticks" (buildingBuildWorkTicks b)
    nonnegative "workers" (buildingWorkers b)
    nonnegative "power_w" (buildingPower b)
    checkResources c "cost" (buildingCost b)
    when (M.null (buildingCost b)) (Left "Building cost must not be empty")
    nonnegative "maintenance_period_ticks" (buildingMaintenancePeriod b)
    nonnegative "maintenance_work_ticks" (buildingMaintenanceWorkTicks b)
    nonnegative "maintenance_parts" (buildingMaintenanceParts b)
    if buildingMaintenancePeriod b == 0
      then unless (buildingMaintenanceWorkTicks b == 0 && buildingMaintenanceParts b == 0)
             (Left "Maintenance-disabled building must have zero maintenance work and parts")
      else do
        work "maintenance_work_ticks" (buildingMaintenanceWorkTicks b)
        positive "maintenance_parts" (buildingMaintenanceParts b)
    unless (M.member (buildingUnlock b) deps) (Left ("Unknown unlock " ++ buildingUnlock b))
  where
    deps = M.union (M.map techRequires (contentTechs c)) (M.map campaignRequires (contentCampaign c))

validateNaturals :: Content -> Either String ()
validateNaturals c = do
  -- Source identities are part of the v1 ruleset; amounts remain solely in JSON.
  let expected = M.fromList [("aquifer",Water),("brine_aquifer",Brine),("ore_deposit",Ore),
                            ("stone_deposit",Stone),("sand_deposit",Sand)]
  unless (M.map naturalSourceResource (contentNaturalSources c) == expected)
    (Left "Natural source identities/resources do not match the v1 ruleset")
  forM_ (M.elems (contentNaturalSources c)) $ \source -> do
    unless (M.member (naturalSourceResource source) (contentResources c)) (Left "Natural source resource is undefined")
    when (naturalSourceRegenerates source) (Left "V1 natural sources do not regenerate")

validateDependencies :: Content -> Either String ()
validateDependencies c = do
  let ts = M.map techRequires (contentTechs c)
      cs = M.map campaignRequires (contentCampaign c)
      deps = M.union ts cs
  unless (S.null (M.keysSet ts `S.intersection` M.keysSet cs)) (Left "Tech/campaign ID collision")
  forM_ (M.toList deps) $ \(key,rs) -> do
    identifier key
    unless (length rs == S.size (S.fromList rs)) (Left ("Duplicate dependency in " ++ key))
    forM_ rs $ \r -> unless (M.member r deps) (Left ("Undefined dependency " ++ r ++ " in " ++ key))
  forM_ (M.elems (contentTechs c)) $ \t -> nonnegative ("tech points " ++ techId t) (techPoints t)
  let cycles = [xs | CyclicSCC xs <- stronglyConnComp [(key,key,rs) | (key,rs) <- M.toList deps]]
  unless (null cycles) (Left ("Dependency cycle: " ++ show cycles))

unitFor :: Resource -> String
unitFor r | r `elem` [Water,Brine] = "ml"
          | r `elem` [Parts,Circuit,Tools] = "piece"
          | r == Medicine = "dose"
          | otherwise = "g"

checkResources :: Content -> String -> M.Map Resource Integer -> Either String ()
checkResources c label vector = do
  forM_ (M.toList vector) $ \(r,n) -> do
    unless (M.member r (contentResources c)) (Left (label ++ ": unknown resource " ++ show r))
    positive (label ++ " quantity of " ++ show r) n
  let load = sum [n * resourceLoad def | (r,n) <- M.toList vector,
                   Just def <- [M.lookup r (contentResources c)]]
  nonnegative (label ++ " total load") load

countIs :: String -> Integer -> M.Map k a -> Either String ()
countIs label expected xs = unless (toInteger (M.size xs) == expected)
  (Left ("Expected " ++ show expected ++ " " ++ label))
keysAre :: String -> [String] -> M.Map String a -> Either String ()
keysAre label expected xs = unless (M.keysSet xs == S.fromList expected)
  (Left ("Invalid " ++ label ++ " ID set"))
keyed :: (Ord k, Show k) => String -> (a -> k) -> M.Map k a -> Either String ()
keyed label field xs = forM_ (M.toList xs) $ \(k,v) -> unless (k == field v)
  (Left (label ++ " map key/record ID mismatch: " ++ show k))
identifier :: String -> Either String ()
identifier s = unless (not (null s) && all (\ch -> isAsciiLower ch || isAsciiUpper ch || isDigit ch || ch == '_') s)
  (Left ("Invalid ID " ++ show s))
nonempty :: String -> String -> Either String ()
nonempty label s = when (null s) (Left (label ++ " must not be empty"))
range :: String -> Integer -> Integer -> Integer -> Either String ()
range label lo hi n = unless (n >= lo && n <= hi)
  (Left (label ++ " out of range " ++ show (lo,hi) ++ ": " ++ show n))
positive, nonnegative, work :: String -> Integer -> Either String ()
positive label = range label 1 quantityMax
nonnegative label = range label 0 quantityMax
work label = range label 1 (quantityMax `div` 130)
