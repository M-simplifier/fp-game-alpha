-- | Versioned data, not an IO operation. Malformed input never makes a World.
module Game.Save (encodeWorld, decodeWorld, SaveError (..), SaveField (..)) where

import Data.List.NonEmpty (NonEmpty)
import Game.Model
import Text.Read (readMaybe)

data SaveField = SavedColumn | SavedRow | SavedTurn | SavedProgress deriving (Eq, Show)

data SaveError
  = SaveTooLarge
  | UnsupportedFormat
  | MalformedValue SaveField
  | InvalidWorld (NonEmpty InvariantViolation)
  deriving (Eq, Show)

encodeWorld :: World -> String
encodeWorld world =
  let (column, row) = coordinates (position world)
   in unwords ["FP-GAME-SAVE", "1", show column, show row, show (turnCount world), show (isWon world)] ++ "\n"

decodeWorld :: String -> Either SaveError World
decodeWorld input
  | length input > 4096 = Left SaveTooLarge
  | otherwise = case words input of
      ["FP-GAME-SAVE", "1", column, row, turns, won] -> do
        x <- parse SavedColumn column
        y <- parse SavedRow row
        turn <- parse SavedTurn turns
        finished <- parse SavedProgress won
        either (Left . InvalidWorld) Right (restoreWorld x y turn finished)
      _ -> Left UnsupportedFormat
  where
    parse :: (Read value) => SaveField -> String -> Either SaveError value
    parse field value = maybe (Left (MalformedValue field)) Right (readMaybe value)
