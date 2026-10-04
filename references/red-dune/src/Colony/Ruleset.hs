-- Ruleset IDs select simulation semantics independently of recipe content IDs.
-- Old traces retain their original cancellation behavior; migration is explicit.
module Colony.Ruleset where

data CancellationRounding = LegacyPerLot | ResourceAggregate | ResourceAggregateSplit deriving(Eq,Show)
data CatalogVersion = CatalogV1 | CatalogV2 deriving(Eq,Show)

rulesetProfile :: String -> Either String (CatalogVersion,CancellationRounding)
rulesetProfile name=case name of
  "red-dune-reference-0"->Right(CatalogV1,LegacyPerLot)
  "red-dune-reference-1"->Right(CatalogV2,LegacyPerLot)
  "red-dune-reference-2"->Right(CatalogV1,ResourceAggregate)
  "red-dune-reference-3"->Right(CatalogV2,ResourceAggregate)
  "red-dune-reference-4"->Right(CatalogV1,ResourceAggregateSplit)
  "red-dune-reference-5"->Right(CatalogV2,ResourceAggregateSplit)
  "red-dune-reference-6"->Right(CatalogV1,ResourceAggregateSplit)
  "red-dune-reference-7"->Right(CatalogV2,ResourceAggregateSplit)
  _->Left "UnsupportedRuleset"

allRulesets :: [String]
allRulesets=map ("red-dune-reference-"++) ["0","1","2","3","4","5","6","7"]
currentV1Ruleset :: String
currentV1Ruleset="red-dune-reference-4"

correctedCancellationProfile :: String -> Either String String
correctedCancellationProfile old=case old of
  "red-dune-reference-0"->Right "red-dune-reference-2"
  "red-dune-reference-1"->Right "red-dune-reference-3"
  _->Left "Cancellation correction requires a legacy profile (0 or 1)"

balancedProfile :: String -> Either String String
balancedProfile old=case old of
  "red-dune-reference-0"->Right "red-dune-reference-1"
  "red-dune-reference-2"->Right "red-dune-reference-3"
  "red-dune-reference-4"->Right "red-dune-reference-5"
  "red-dune-reference-6"->Right "red-dune-reference-7"
  _->Left "Balance update requires content-v1 profile (0, 2, 4 or 6)"

-- Keep the resource-floor correction distinct: an old profile first opts into
-- resource loss (0->2 or 1->3), then into split placement on another branch.
correctedReturnPlacementProfile :: String -> Either String String
correctedReturnPlacementProfile old=case old of
  "red-dune-reference-2"->Right "red-dune-reference-4"
  "red-dune-reference-3"->Right "red-dune-reference-5"
  _->Left "Return-placement correction requires profile 2 or 3"

-- A semantic split, never inferred from missing data or save age.
isM1Ruleset :: String -> Bool
isM1Ruleset name=name `elem` ["red-dune-reference-6","red-dune-reference-7"]
