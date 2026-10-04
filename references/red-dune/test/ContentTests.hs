module ContentTests (contentTests) where

import Colony.Content
import Colony.Units
import Colony.RNG
import qualified Colony.JSON as J
import Control.Monad (forM_, unless)
import Data.Binary (decodeOrFail, encode)
import Data.Binary.Get (ByteOffset)
import Data.Bits (xor, shiftL, shiftR)
import Data.Word (Word64)
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft, isRight)
import Data.Int (Int64)
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Text.Read (readMaybe)

assert :: String -> Bool -> IO ()
assert name ok = unless ok (ioError (userError ("Content/Units assertion failed: " ++ name)))

contentTests :: Content -> IO ()
contentTests c = do
  assert "valid canonical content" (validateContent c == Right ())
  assert "16 resources" (M.size (contentResources c) == 16)
  assert "18 recipes" (M.size (contentRecipes c) == 18)
  assert "28 buildings" (M.size (contentBuildings c) == 28)
  assert "5 natural sources" (M.size (contentNaturalSources c) == 5)
  assert "6 technologies" (M.size (contentTechs c) == 6)
  assert "6 campaign stages" (M.size (contentCampaign c) == 6)
  assert "content values accessible by UI/kernel" (fmap (M.lookup Water . recipeOutputs) (lookupRecipe c "pump") == Right (Just 120000))
  assert "food expiry loaded" (fmap resourceShelfLife (lookupResource c Crops) == Right (Just 144000))
  assert "non-unit load loaded" (fmap resourceLoad (lookupResource c Tools) == Right 1000)
  assert "power/workforce loaded" (fmap (\b -> (buildingPower b,buildingWorkers b)) (lookupBuilding c "desalinator") == Right (20000,3))
  assert "even-width south port west-biased" (fmap buildingPort (lookupBuilding c "depot") == Right (1,3))
  assert "odd-width south port" (fmap buildingPort (lookupBuilding c "pantry") == Right (1,2))
  assert "lookup unknown recipe fails" (isLeft (lookupRecipe c "no_such_recipe"))
  assert "lookup unknown building fails" (isLeft (lookupBuilding c "no_such_building"))
  forM_ allResources $ \r -> assert ("resource roundtrip " ++ show r) (parseResource (resourceKey r) == Right r)
  assert "unknown resource rejected" (isLeft (parseResource "credits"))
  assert "resource IDs case-sensitive" (isLeft (parseResource "Water"))

  -- Each test changes one part of a known-good package; count/shape errors must
  -- never make malformed records disappear behind Map.fromList deduplication.
  let reject label bad = assert label (isLeft (validateContent bad))
      recipe k f = c { contentRecipes = M.adjust f k (contentRecipes c) }
      building k f = c { contentBuildings = M.adjust f k (contentBuildings c) }
      resource k f = c { contentResources = M.adjust f k (contentResources c) }
      tech k f = c { contentTechs = M.adjust f k (contentTechs c) }
      campaign k f = c { contentCampaign = M.adjust f k (contentCampaign c) }
      source k f = c { contentNaturalSources = M.adjust f k (contentNaturalSources c) }
  reject "content version" c { contentVersion = "9.0" }
  reject "missing status" c { contentStatus = "" }
  reject "zero tick rate" c { contentTickHz = 0 }
  reject "inconsistent game-day units" c { contentTicksPerDay = 28801 }
  reject "different quantity bound" c { contentQuantityMax = quantityMax + 1 }
  reject "resource removed" c { contentResources = M.delete Water (contentResources c) }
  reject "recipe removed" c { contentRecipes = M.delete "pump" (contentRecipes c) }
  reject "building removed" c { contentBuildings = M.delete "farm" (contentBuildings c) }
  reject "technology removed" c { contentTechs = M.delete "T2" (contentTechs c) }
  reject "stage removed" c { contentCampaign = M.delete "C2" (contentCampaign c) }
  reject "resource map-key mismatch" (resource Water (\r -> r { resourceId = Brine }))
  reject "resource wrong unit" (resource Water (\r -> r { resourceUnit = "g" }))
  reject "zero load" (resource Tools (\r -> r { resourceLoad = 0 }))
  reject "negative shelf life" (resource Crops (\r -> r { resourceShelfLife = Just (-1) }))
  reject "unexpected resource expiry" (resource Metal (\r -> r { resourceShelfLife = Just 100 }))
  reject "recipe map-key mismatch" (recipe "pump" (\r -> r { recipeId = "water_pump" }))
  reject "recipe undefined building" (recipe "pump" (\r -> r { recipeBuilding = "none" }))
  reject "zero recipe duration" (recipe "pump" (\r -> r { recipeWorkTicks = 0 }))
  reject "work credit multiplication bound" (recipe "pump" (\r -> r { recipeWorkTicks = quantityMax }))
  reject "negative input" (recipe "cook" (\r -> r { recipeInputs = M.singleton Water (-1) }))
  reject "zero input" (recipe "cook" (\r -> r { recipeInputs = M.singleton Water 0 }))
  reject "overflow input" (recipe "cook" (\r -> r { recipeInputs = M.singleton Water (quantityMax+1) }))
  reject "load multiplication overflow" (recipe "cook" (\r -> r { recipeInputs = M.singleton Tools quantityMax }))
  reject "empty output" (recipe "cook" (\r -> r { recipeOutputs = M.empty }))
  reject "undefined natural source" (recipe "pump" (\r -> r { recipeNaturalSources = M.singleton "spring" 120000 }))
  reject "negative natural-source amount" (recipe "pump" (\r -> r { recipeNaturalSources = M.singleton "aquifer" (-1) }))
  reject "extraction amount disagreement" (recipe "pump" (\r -> r { recipeOutputs = M.singleton Water 119999 }))
  reject "extraction wrong resource" (recipe "pump" (\r -> r { recipeOutputs = M.singleton Brine 120000 }))
  reject "extraction cannot consume process inputs" (recipe "pump" (\r -> r { recipeInputs = M.singleton Water 1 }))
  reject "natural source mismatch" (source "aquifer" (\n -> n { naturalSourceResource = Brine }))
  reject "regeneration unsupported" (source "aquifer" (\n -> n { naturalSourceRegenerates = True }))
  reject "zero footprint dimension" (building "depot" (\b -> b { buildingFootprint = (0,4) }))
  reject "outside-world footprint dimension" (building "depot" (\b -> b { buildingFootprint = (513,4) }))
  reject "negative workforce" (building "depot" (\b -> b { buildingWorkers = -1 }))
  reject "negative power" (building "depot" (\b -> b { buildingPower = -1 }))
  reject "zero construction work" (building "depot" (\b -> b { buildingBuildWorkTicks = 0 }))
  reject "empty construction cost" (building "depot" (\b -> b { buildingCost = M.empty }))
  reject "undefined unlock" (building "depot" (\b -> b { buildingUnlock = "C9" }))
  reject "maintenance disabled nonzero work" (building "depot" (\b -> b { buildingMaintenanceWorkTicks = 600 }))
  reject "maintenance required but zero work" (building "pump" (\b -> b { buildingMaintenanceWorkTicks = 0 }))
  reject "maintenance required but zero parts" (building "pump" (\b -> b { buildingMaintenanceParts = 0 }))
  reject "undefined technology dependency" (tech "T2" (\t -> t { techRequires = ["T9"] }))
  reject "duplicate technology dependency" (tech "T2" (\t -> t { techRequires = ["C1","C1"] }))
  reject "negative research points" (tech "T2" (\t -> t { techPoints = -1 }))
  reject "self-cycle" (tech "T2" (\t -> t { techRequires = ["T2"] }))
  reject "long technology cycle" (tech "T2" (\t -> t { techRequires = ["T6"] }))
  reject "campaign cycle" (campaign "C0" (\s -> s { campaignRequires = ["C5"] }))
  reject "cross tech/campaign cycle" (campaign "C0" (\s -> s { campaignRequires = ["T1"] }))

  qtyTests
  jsonTests c
  rngTests
  putStrLn "PASS Content/Units: canonical dataset, quantity boundaries, invalid schemas/references/ranges and dependency cycles"

qtyTests :: IO ()
qtyTests = do
  let q = mkQty :: Integer -> Either String (Qty StockUnit)
  assert "quantity zero" (fmap qtyValue (q 0) == Right 0)
  assert "quantity max" (fmap qtyValue (q quantityMax) == Right quantityMax)
  assert "quantity negative" (isLeft (q (-1)))
  assert "quantity max+1" (isLeft (q (quantityMax+1)))
  assert "quantity arbitrarily huge" (isLeft (q (10^(100 :: Integer))))
  forM_ [0,1,2,1000,quantityMax-1,quantityMax] $ \a -> do
    qa <- either (ioError . userError) pure (q a)
    assert "quantity Read/Show roundtrip" (readMaybe (show qa) == Just qa)
    let decoded = decodeOrFail (encode qa) :: Either (BL.ByteString,ByteOffset,String) (BL.ByteString,ByteOffset,Qty StockUnit)
    assert "quantity Binary roundtrip" (case decoded of Right (rest,_,v) -> BL.null rest && v == qa; _ -> False)
    forM_ [0,1,2,1000,quantityMax-1,quantityMax] $ \b -> do
      qb <- either (ioError . userError) pure (q b)
      assert "checked addition Integer oracle" (fmap qtyValue (addQty qa qb) == if a+b <= quantityMax then Right (a+b) else Left "QuantityOverflow")
      assert "checked subtraction Integer oracle" (fmap qtyValue (subQty qa qb) == if a >= b then Right (a-b) else Left "QuantityUnderflow")
  assert "zeroQty" (qtyValue (zeroQty :: Qty StockUnit) == 0)
  forM_ ["Qty (-1)", "Qty 9000000000001", "Qty 9223372036854775808"] $ \s ->
    assert "Read cannot bypass smart constructor" ((readMaybe s :: Maybe (Qty StockUnit)) == Nothing)
  forM_ [-1,fromInteger quantityMax+1,maxBound] $ \n -> do
    let decoded = decodeOrFail (encode (n :: Int64)) :: Either (BL.ByteString,ByteOffset,String) (BL.ByteString,ByteOffset,Qty StockUnit)
    assert "Binary cannot bypass smart constructor" (isLeft decoded)

jsonTests :: Content -> IO ()
jsonTests c = do
  assert "JSON escaped Unicode/surrogate pair" (J.parseJSON "[\"\\u6c34\",\"\\ud83d\\ude80\"]" == Right (J.JArray [J.JString "水",J.JString "🚀"]))
  assert "JSON control escapes" (J.parseJSON "\"a\\n\\t\\r\\b\\f\\\\\\/\\\"\"" == Right (J.JString "a\n\t\r\b\f\\/\""))
  forM_ ["{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}", "1.5", "1e3", "01", "-01", "+1", "[1,]",
         "{\"x\":1,}", "null garbage", "\"\\ud800\"", "\"\\udfff\"", "\"\\ud800\\u0041\"", "\"\n\"", replicate 66 '[' ++ "0" ++ replicate 66 ']'] $ \s ->
    assert ("strict JSON rejects " ++ take 40 s) (isLeft (J.parseJSON s))
  forM_ ["null","true","false","-123","[0,1]","{}","\"清水\""] $ \s ->
    assert "valid JSON accepted" (isRight (J.parseJSON s))
  let base = contentJSON c
  assert "content JSON roundtrip" (decodeContent (renderJSON base) == Right c)
  let reject name j = assert name (isLeft (decodeContent (renderJSON j)))
      mutate name f = case base of
        J.JObject o -> J.JObject (M.adjust f name o)
        _ -> base
      duplicate name = mutate name (\v -> case v of J.JArray (x:xs) -> J.JArray (x:x:xs); _ -> v)
      unknownField = case base of J.JObject o -> J.JObject (M.insert "typo" J.JNull o); _ -> base
      missingField = case base of J.JObject o -> J.JObject (M.delete "resources" o); _ -> base
  forM_ ["resources","recipes","buildings","natural_sources","techs","campaign"] $ \name ->
    reject ("duplicate array IDs " ++ name) (duplicate name)
  reject "unknown mandatory/schema field" unknownField
  reject "missing mandatory field" missingField
  reject "wrong JSON type" (mutate "quantity_max" (const (J.JString "9000000000000")))
  reject "undefined resource string" (mutate "resources" (\v -> case v of J.JArray (J.JObject row:xs) -> J.JArray (J.JObject (M.insert "id" (J.JString "unobtainium") row):xs); _ -> v))

-- Test-only serialization provides parser/validator mutations without a second
-- runtime dataset. All values are obtained from the supplied canonical Content.
contentJSON :: Content -> J.JSON
contentJSON c = obj
  [ ("spec_version",str (contentVersion c)), ("status",str (contentStatus c))
  , ("tick_hz",num (contentTickHz c)), ("game_seconds_per_tick",num (contentGameSecondsPerTick c))
  , ("ticks_per_game_day",num (contentTicksPerDay c)), ("quantity_max",num (contentQuantityMax c))
  , ("resources",list resource (M.elems (contentResources c)))
  , ("recipes",list recipe (M.elems (contentRecipes c)))
  , ("buildings",list building (M.elems (contentBuildings c)))
  , ("natural_sources",list source (M.elems (contentNaturalSources c)))
  , ("techs",list tech (M.elems (contentTechs c)))
  , ("campaign",list campaign (M.elems (contentCampaign c))) ]
  where
    obj = J.JObject . M.fromList; str = J.JString; num = J.JInteger
    list f = J.JArray . map f
    vector = obj . map (\(r,n) -> (resourceKey r,num n)) . M.toList
    resource r = obj [("id",str (resourceKey (resourceId r))),("label",str (resourceLabel r)),("unit",str (resourceUnit r)),("load_g_per_unit",num (resourceLoad r)),("shelf_life_ticks",maybe J.JNull num (resourceShelfLife r))]
    recipe r = obj [("id",str (recipeId r)),("label",str (recipeLabel r)),("building",str (recipeBuilding r)),("work_ticks",num (recipeWorkTicks r)),("inputs",vector (recipeInputs r)),("outputs",vector (recipeOutputs r)),("natural_sources",J.JObject (M.map num (recipeNaturalSources r)))]
    building b = obj [("id",str (buildingId b)),("label",str (buildingLabel b)),("footprint",J.JArray [num (fst (buildingFootprint b)),num (snd (buildingFootprint b))]),("build_work_ticks",num (buildingBuildWorkTicks b)),("workers",num (buildingWorkers b)),("power_w",num (buildingPower b)),("cost",vector (buildingCost b)),("maintenance_period_ticks",num (buildingMaintenancePeriod b)),("maintenance_work_ticks",num (buildingMaintenanceWorkTicks b)),("maintenance_parts",num (buildingMaintenanceParts b)),("unlock",str (buildingUnlock b))]
    source s = obj [("id",str (naturalSourceId s)),("resource",str (resourceKey (naturalSourceResource s))),("regenerates",J.JBool (naturalSourceRegenerates s))]
    tech t = obj [("id",str (techId t)),("requires",list str (techRequires t)),("points",num (techPoints t))]
    campaign s = obj [("id",str (campaignId s)),("requires",list str (campaignRequires s))]

renderJSON :: J.JSON -> String
renderJSON j = case j of
  J.JObject o -> "{" ++ intercalate "," [quoted k ++ ":" ++ renderJSON v | (k,v) <- M.toList o] ++ "}"
  J.JArray xs -> "[" ++ intercalate "," (map renderJSON xs) ++ "]"
  J.JString s -> quoted s
  J.JInteger n -> show n
  J.JBool b -> if b then "true" else "false"
  J.JNull -> "null"
  where
    quoted s = "\"" ++ concatMap escape s ++ "\""
    escape ch = case ch of
      '"' -> "\\\""; '\\' -> "\\\\"; '\n' -> "\\n"; '\r' -> "\\r"; '\t' -> "\\t"
      '\b' -> "\\b"; '\f' -> "\\f"; _ -> [ch]


rngTests :: IO ()
rngTests = do
  goldenText <- readFile "data/numeric-golden.json"
  root <- expectRight (J.parseJSON goldenText >>= J.object)
  name <- expectRight (J.field "prng" root >>= J.string)
  assert "golden oracle names RDF-RNG-1" (name == "RDF-RNG-1")
  vectors <- expectRight (J.field "vectors" root >>= J.array)
  assert "all three PRNG oracle vectors" (length vectors == 3)
  forM_ vectors $ \value -> do
    vector <- expectRight (J.object value)
    seed <- expectRight (J.field "state" vector >>= decimalWord)
    draws <- expectRight (J.field "draws" vector >>= J.array)
    assert "each vector has eight draws" (length draws == 8)
    let check _ [] = pure ()
        check old (record:rest) = do
          expected <- expectRight (J.object record)
          state <- expectRight (J.field "next_state" expected >>= decimalWord)
          output <- expectRight (J.field "output" expected >>= decimalWord)
          (actual,next) <- expectRight (nextWord old)
          assert "PRNG golden output" (actual == output)
          assert "PRNG golden next state" (rngState next == state)
          assert "PRNG count increments once" (rngDrawCount next == rngDrawCount old + 1)
          check next rest
    check (Rng seed 0) draws

  let zeroSeed = initialRng 0
      oneSeed = initialRng 1
  assert "zero seed marker/original/normalized persisted" (rngSeedWasZero zeroSeed && rngOriginalSeed zeroSeed == 0 && rngNormalizedSeed zeroSeed == 1)
  assert "nonzero seed marker" (not (rngSeedWasZero oneSeed))
  assert "zero seed draws equal normalized seed draws" (weatherRng zeroSeed == weatherRng oneSeed && immigrationRng zeroSeed == immigrationRng oneSeed && decorationRng zeroSeed == decorationRng oneSeed)
  assert "weather seed salt" (rngState (weatherRng oneSeed) == (1 `xor` 0x9E3779B97F4A7C15))
  assert "immigration seed salt" (rngState (immigrationRng oneSeed) == (1 `xor` 0xD1B54A32D192ED03))
  assert "decoration seed salt" (rngState (decorationRng oneSeed) == (1 `xor` 0x94D049BB133111EB))
  assert "zero xor weather stream normalized" (rngState (weatherRng (initialRng 0x9E3779B97F4A7C15)) == 1)
  assert "zero xor immigration stream normalized" (rngState (immigrationRng (initialRng 0xD1B54A32D192ED03)) == 1)
  assert "zero xor decoration stream normalized" (rngState (decorationRng (initialRng 0x94D049BB133111EB)) == 1)
  assert "zero PRNG state rejected" (isLeft (nextWord (Rng 0 0)))
  assert "draw counter exhaustion rejected" (isLeft (nextWord (Rng 1 maxBound)))
  (_,lastDraw) <- expectRight (nextWord (Rng 1 (maxBound-1)))
  assert "last safe draw reaches max without wrap" (rngDrawCount lastDraw == maxBound)
  assert "range zero rejected" (isLeft (drawBelow 0 (Rng 1 0)))
  (singleton,afterSingleton) <- expectRight (drawBelow 1 (Rng 1 0))
  assert "range one consumes exactly one draw" (singleton == Drawn 0 && rngDrawCount afterSingleton == 1)
  (_,weatherChanged) <- expectRight (drawFromStream 6 WeatherStream oneSeed)
  assert "weather draw changes only weather stream" (weatherRng weatherChanged /= weatherRng oneSeed && immigrationRng weatherChanged == immigrationRng oneSeed && decorationRng weatherChanged == decorationRng oneSeed)
  (_,immigrationChanged) <- expectRight (drawFromStream 6 ImmigrationStream oneSeed)
  assert "immigration draw changes only immigration stream" (weatherRng immigrationChanged == weatherRng oneSeed && immigrationRng immigrationChanged /= immigrationRng oneSeed && decorationRng immigrationChanged == decorationRng oneSeed)
  (_,decorationChanged) <- expectRight (drawFromStream 6 MapDecorationStream oneSeed)
  assert "decoration draw changes only decoration stream" (weatherRng decorationChanged == weatherRng oneSeed && immigrationRng decorationChanged == immigrationRng oneSeed && decorationRng decorationChanged /= decorationRng oneSeed)
  assert "seed marker validation" (isLeft (validateRngStreams oneSeed { rngSeedWasZero = True }))
  assert "seed normalization validation" (isLeft (validateRngStreams oneSeed { rngNormalizedSeed = 2 }))
  assert "bad stream validation" (isLeft (validateRngStreams oneSeed { weatherRng = Rng 0 0 }))

  -- A scripted rejection tape exercises the exact production sampler without
  -- searching billions of random seeds for 32 consecutive rejections.
  let bound = 9223372036854775809 :: Word64
      alwaysRejected count = Right (maxBound,count+1) :: Either String (Word64,Word64)
  (suspended,after32) <- expectRight (drawBelowWith alwaysRejected bound 0)
  assert "rejection budget exactly 32, no 33rd draw" (suspended == Pending bound && after32 == 32)
  (suspendedAgain,after64) <- expectRight (drawBelowWith alwaysRejected bound after32)
  assert "rejection continuation consumes next 32 draws" (suspendedAgain == Pending bound && after64 == 64)
  let acceptsAfter32 count = Right (if count < 32 then maxBound else 17,count+1) :: Either String (Word64,Word64)
  (pending,position) <- expectRight (drawBelowWith acceptsAfter32 bound 0)
  (resumed,position') <- expectRight (drawBelowWith acceptsAfter32 bound position)
  assert "resumed sample does not rewind rejection state" (pending == Pending bound && resumed == Drawn 17 && position' == 33)
  let atLimit _ = Right (maxBound,1 :: Word64)
      belowLimit _ = Right (maxBound-1,1 :: Word64)
  assert "output equal to limit rejects" (fmap fst (drawBelowWith atLimit maxBound (0 :: Word64)) == Right (Pending maxBound))
  assert "output below limit accepted" (fmap fst (drawBelowWith belowLimit maxBound (0 :: Word64)) == Right (Drawn (maxBound-1)))
  let continuation = PendingRandomDraw 6 ImmigrationStream ("immigrant-skill",123 :: Word64)
  assert "pending typed continuation roundtrip" (readMaybe (show continuation) == Just continuation)
  assert "stream snapshot roundtrip" (readMaybe (show oneSeed) == Just oneSeed)
  resumedReal <- expectRight (resumeRandomDraw continuation oneSeed)
  directReal <- expectRight (drawFromStream 6 ImmigrationStream oneSeed)
  assert "typed pending resumes saved stream and bound" (resumedReal == directReal)

  forM_ [1,2,3,7,42,123456789,maxBound] $ \seed -> do
    let checkOracle 0 _ = pure ()
        checkOracle remaining old = do
          (word,next) <- expectRight (nextWord old)
          let (expectedWord,expectedState) = rngIntegerOracle (toInteger (rngState old))
          assert "Word64 PRNG matches explicit-Integer wrap oracle" (toInteger word == expectedWord && toInteger (rngState next) == expectedState)
          checkOracle (remaining-1) next
    checkOracle (256 :: Word64) (Rng seed 0)
    forM_ [1,2,3,6,10,256,65535,9223372036854775809,maxBound] $ \n -> do
      let checkRange 0 _ = pure ()
          checkRange remaining old = do
            (result,next) <- expectRight (drawBelow n old)
            assert "bounded draw advances within 32 draws" (rngDrawCount next > rngDrawCount old && rngDrawCount next - rngDrawCount old <= 32)
            assert "bounded draw result lies in range" (case result of Drawn x -> x < n; Pending k -> k == n)
            checkRange (remaining-1) next
      checkRange (64 :: Word64) (Rng seed 0)
  putStrLn "PASS RDF-RNG-1: 24 checked-in golden draws, 1792 Integer-oracle steps, bounded ranges, rejection suspension/resumption and independent streams"
  where
    expectRight :: Either String a -> IO a
    expectRight = either (ioError . userError) pure
    decimalWord j = do
      text <- J.string j
      n <- maybe (Left "Expected decimal Word64 string") Right (readMaybe text :: Maybe Integer)
      if n < 0 || n > toInteger (maxBound :: Word64) then Left "Golden Word64 out of range" else Right (fromInteger n)

rngIntegerOracle :: Integer -> (Integer,Integer)
rngIntegerOracle state =
  let modulus = 18446744073709551616
      x1 = state `xor` (state `shiftR` 12)
      x2 = x1 `xor` ((x1 `shiftL` 25) `mod` modulus)
      x3 = x2 `xor` (x2 `shiftR` 27)
  in ((x3 * 2685821657736338717) `mod` modulus,x3)
