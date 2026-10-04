-- The catalog is separate from live Worlds: staging cannot rewrite an attempt.
module Paper.Tuning (Catalog, TuningError (..), initialCatalog, stage, start, revision) where

import Paper.Game
import Text.Read (readMaybe)

newtype Revision = Revision Integer deriving (Eq, Ord, Show)

data Catalog = Catalog Revision Level deriving (Eq, Show)

data TuningError = TooLong | InvalidRecord | InvalidRevision | InvalidLevel LevelError | StaleRevision deriving (Eq, Show)

initialCatalog :: Catalog
initialCatalog = Catalog (Revision 0) defaultLevel

revision :: Catalog -> Integer
revision (Catalog (Revision number) _) = number

start :: Catalog -> World
start (Catalog _ config) = initialWith config

-- Fixed small record. No code evaluation, general JSON, or Int parsing.
-- Failure returns no replacement; callers retain their complete old catalog.
stage :: String -> Catalog -> Either TuningError Catalog
stage input old
  | length (take 129 input) > 128 = Left TooLong
  | otherwise = case words input of
      ["revision", r, "moveBudget", b, "inletRotation", s] -> do
        next <- decimal r
        budget <- decimal b
        spin <- decimal s
        if next < 1 || next > 1000000000 then Left InvalidRevision else pure ()
        if next <= revision old then Left StaleRevision else pure ()
        config <- either (Left . InvalidLevel) Right (level budget spin)
        pure (Catalog (Revision next) config)
      _ -> Left InvalidRecord
  where
    decimal raw
      | not (null raw) && all (\c -> c >= '0' && c <= '9') raw = maybe (Left InvalidRecord) Right (readMaybe raw :: Maybe Integer)
      | otherwise = Left InvalidRecord
