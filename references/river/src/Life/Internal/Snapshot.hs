{-# LANGUAGE OverloadedStrings #-}

module Life.Internal.Snapshot (encodeGame, decodeGame, invariantErrors) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Life.Internal.Core
import Text.Read (readMaybe)

-- Versioned raw transport representation.  Read exists ONLY for this private
-- DTO, never for Game.  Numeric enums allow rejecting unrecognized values.
data RawNight = RawNight !Integer !Integer !Integer ![(Integer, Integer, Integer, Integer, Bool)]
  deriving (Eq, Show, Read)

data RawSave = RawSave
  { rVersion :: !Integer,
    rX :: !Integer,
    rZ :: !Integer,
    rFX :: !Integer,
    rFZ :: !Integer,
    rDay :: !Integer,
    rTicks :: !Integer,
    rBeds :: ![(Integer, Integer, Integer, Bool)],
    rWood :: ![(Integer, Integer, Integer, Bool)],
    rRoofs :: ![(Integer, Integer)],
    rPaths :: ![(Integer, Integer)],
    rSeats :: ![(Integer, Integer)],
    rBuild :: !Integer,
    rTurnips :: !Integer,
    rDryWood :: !Integer,
    rDinner :: !Integer,
    rNight :: !(Maybe RawNight)
  }
  deriving (Eq, Show, Read)

rawGame :: Game -> RawSave
rawGame g =
  RawSave
    { rVersion = 1,
      rX = n (gPlayerX g),
      rZ = n (gPlayerZ g),
      rFX = n (gFacingX g),
      rFZ = n (gFacingZ g),
      rDay = n (gDay g),
      rTicks = n (gTicks g),
      rBeds = [(n x, n z, n (fromEnum s), w) | (Cell x z, Bed s w) <- Map.toAscList (gBeds g)],
      rWood = [(n x, n z, n amount, l) | (Cell x z, Bundle amount l) <- Map.toAscList (gWood g)],
      rRoofs = map pair (roofs g),
      rPaths = map pair (paths g),
      rSeats = map pair (seats g),
      rBuild = n (fromEnum (gBuild g)),
      rTurnips = n (gTurnips g),
      rDryWood = n (gDryWood g),
      rDinner = n (fromEnum (gDinner g)),
      rNight = fmap rawNight (gNight g)
    }
  where
    pair (Cell x z) = (n x, n z)
    rawNight (NightReport d grown rainCount changes) =
      RawNight
        (n d)
        (n grown)
        (n rainCount)
        [(n x, n z, n before, n after, covered) | (Cell x z, before, after, covered) <- changes]
    n = toInteger

-- | Versioned transport data, never a public 'Game' constructor.
encodeGame :: Game -> Text
encodeGame = Text.pack . show . rawGame

-- | Size-limit and parse an untrusted save; admit a restored state only after
-- its raw fields and player collision have passed validation.
decodeGame :: Text -> Either SaveError Game
decodeGame input
  | Text.length input > 65536 = Left SaveTooLarge
  | otherwise = case readMaybe (Text.unpack input) of
      Nothing -> Left SaveMalformed
      Just raw
        | rVersion raw /= 1 -> Left (SaveVersionUnsupported (rVersion raw))
        | otherwise -> case restoreRaw raw of
            Left problems -> Left (SaveInvalid problems)
            Right game -> Right game

-- Field errors precede collision/conversion errors even when both apply.
-- Keep that diagnostic contract while reconstructing the candidate only once.
restoreRaw :: RawSave -> Either [Text] Game
restoreRaw raw = case fromRaw raw of
  Nothing -> Left (rawFieldErrors raw ++ ["enum conversion"])
  Just game -> case rawFieldErrors raw ++ ["player collision" | not (positionClear (playerPosition game) game)] of
    [] -> Right game
    problems -> Left problems

-- Safe lookup rather than partial toEnum, even after validation.
enumValue :: (Bounded a, Enum a) => Integer -> Maybe a
enumValue n = lookup n [(toInteger (fromEnum x), x) | x <- [minBound .. maxBound]]

fromRaw :: RawSave -> Maybe Game
fromRaw r = do
  bs <- traverse bed (rBeds r)
  buildKind <- enumValue (rBuild r)
  dinner <- enumValue (rDinner r)
  pure $
    Game
      { gPlayerX = n (rX r),
        gPlayerZ = n (rZ r),
        gFacingX = n (rFX r),
        gFacingZ = n (rFZ r),
        gDay = n (rDay r),
        gTicks = n (rTicks r),
        gBeds = Map.fromList bs,
        gWood = Map.fromList [(Cell (n x) (n z), Bundle (n amount) l) | (x, z, amount, l) <- rWood r],
        gRoofs = cells (rRoofs r),
        gPaths = cells (rPaths r),
        gSeats = cells (rSeats r),
        gBuild = buildKind,
        gTurnips = n (rTurnips r),
        gDryWood = n (rDryWood r),
        gDinner = dinner,
        gNight = fmap restoreNight (rNight r)
      }
  where
    n = fromInteger
    restoreNight (RawNight d grown rainCount changes) =
      NightReport
        (n d)
        (n grown)
        (n rainCount)
        [(Cell (n x) (n z), n before, n after, covered) | (x, z, before, after, covered) <- changes]
    cells = Set.fromList . map (\(x, z) -> Cell (n x) (n z))
    bed (x, z, s, w) = do
      stage <- enumValue s
      pure (Cell (n x) (n z), Bed stage w)

rawFieldErrors :: RawSave -> [Text]
rawFieldErrors r =
  concat
    [ bad (rVersion r == 1) "version",
      bad
        ( rX r >= 22
            && rX r < toInteger (worldWidth * 100 - 22)
            && rZ r >= 22
            && rZ r < toInteger (worldDepth * 100 - 22)
        )
        "player range",
      bad
        ( rFX r >= -1
            && rFX r <= 1
            && rFZ r >= -1
            && rFZ r <= 1
            && (rFX r /= 0 || rFZ r /= 0)
        )
        "facing",
      bad (rDay r >= 1 && rDay r <= toInteger maxDay) "day range",
      bad (rTicks r >= 0 && rTicks r <= toInteger dayLengthTicks) "clock range",
      bad (sortOn id [(x, z) | (x, z, _, _) <- rBeds r] == sortOn id (map pair cropCells)) "crop identities/duplicates",
      bad (all (\(_, _, s, w) -> s >= 0 && s <= 3 && (s /= 0 || not w)) (rBeds r)) "crop state",
      bad (sortOn id [(x, z) | (x, z, _, _) <- rWood r] == sortOn id (map pair woodCells)) "wood identities/duplicates",
      bad (all (\(_, _, n, l) -> n >= 0 && n <= toInteger dryGoal && (l || n == 0)) (rWood r)) "wood state",
      checkCells "roofs" (rRoofs r) roofSiteAllowed,
      checkCells "paths" (rPaths r) groundSiteAllowed,
      checkCells "seats" (rSeats r) groundSiteAllowed,
      bad (Set.null (Set.intersection (Set.fromList (rPaths r)) (Set.fromList (rSeats r)))) "path/seat overlap",
      bad (rBuild r >= 0 && rBuild r <= 3) "build selection",
      bad
        ( rTurnips r >= 0
            && rTurnips r <= toInteger maxInventory
            && rDryWood r >= 0
            && rDryWood r <= toInteger maxInventory
        )
        "inventory range",
      bad (rDinner r >= 0 && rDinner r <= 3) "dinner state",
      validateNight (rDay r) (rNight r)
    ]
  where
    pair (Cell x z) = (toInteger x, toInteger z)
    bad good message = [message | not good]
    checkCells label xs allowed =
      bad
        ( length xs <= worldWidth * worldDepth
            && Set.size (Set.fromList xs) == length xs
            && all
              ( \(x, z) ->
                  x >= 0
                    && z >= 0
                    && x < toInteger worldWidth
                    && z < toInteger worldDepth
                    && allowed (Cell (fromInteger x) (fromInteger z))
              )
              xs
        )
        (label <> " range/duplicates")

validateNight :: Integer -> Maybe RawNight -> [Text]
validateNight currentDay night = ["last-night report" | not valid]
  where
    valid = case night of
      Nothing -> currentDay == 1
      Just (RawNight d grown rainCount changes) ->
        d >= 1
          && d <= toInteger maxDay
          && currentDay == min (toInteger maxDay) (d + 1)
          && grown >= 0
          && grown <= 3
          && rainCount >= 0
          && rainCount <= 3
          && (even d || rainCount == 0)
          && length changes <= 2
          && length changes == Set.size (Set.fromList [(x, z) | (x, z, _, _, _) <- changes])
          && all (validChange d) changes
    validChange d (x, z, before, after, covered) =
      (x, z) `elem` [(7, 9), (8, 9)]
        && before >= 0
        && before <= toInteger dryGoal
        && after == min (toInteger dryGoal) (before + amount)
      where
        amount = toInteger (overnightDryingAmount (weatherFor (fromInteger d)) covered)

invariantErrors :: Game -> [Text]
invariantErrors game = case restoreRaw (rawGame game) of
  Left problems -> problems
  Right _ -> []
