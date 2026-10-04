module Tapline.View (RenderModel (..), Token (..), project, outcomeLabel) where

import Data.List.NonEmpty qualified as NE
import Tapline.Domain
import Tapline.Input

data Token = Token {tokenKey :: Key, tokenDone :: Bool, tokenNext :: Bool}
  deriving (Eq, Show)

data RenderModel = RenderModel
  { shownRound :: Int,
    tokens :: [Token],
    remainingMicros :: Integer,
    heading :: String,
    subheading :: String,
    shownPaused :: Bool,
    shownReady :: Bool,
    shownComplete :: Bool,
    lastOutcome :: Maybe Outcome,
    roundResults :: [Outcome],
    successCount :: Int,
    shownGeneration :: Int
  }
  deriving (Eq, Show)

-- | Derive a render model without mutating the session or performing IO.
project :: Session -> RenderModel
project s =
  RenderModel
    n
    ts
    time
    title
    subtitle
    (isPaused s)
    (phase s == Ready)
    (phase s == Complete)
    verdict
    outcomes
    wins
    (generation s)
  where
    outcomes = map outcome (results s)
    wins = length (filter (== Success) outcomes)
    (n, ts, time, title, subtitle, verdict) = case phase s of
      Ready ->
        ( 1,
          makeTokens 0 (NE.toList (NE.head scenario)),
          roundBudget,
          "TWO KEYS. KEEP THE ORDER.",
          "Read left to right. Tap each tile before the line runs out.",
          Nothing
        )
      Challenge r ->
        ( roundNumber r,
          roundTokens r,
          max 0 (deadline r - activeMicros s),
          if isPaused s then "TAKE A BREATH" else "FOLLOW THE LINE",
          if isPaused s then "The clock is resting. SPACE to continue." else "One press per tile. Let go between repeated letters.",
          Nothing
        )
      Feedback r result _ ->
        ( roundNumber r,
          roundTokens r,
          0,
          outcomeLabel result,
          case result of
            Success -> "A clean line. Next one coming up..."
            WrongKey expected got -> "Needed " ++ keyLabel expected ++ "; received " ++ keyLabel got ++ ". Next line coming up..."
            Expired -> "The line ran out. A fresh one is coming...",
          Just result
        )
      Complete ->
        ( 6,
          [],
          0,
          if wins == 6 then "SIX CLEAN LINES" else "THE SET IS COMPLETE",
          show wins ++ " of 6 lines cleared. Press R for the same set again.",
          Nothing
        )
    roundTokens r = makeTokens (matched r) (NE.toList (sequenceKeys r))
    makeTokens :: Int -> [Key] -> [Token]
    makeTokens count = zipWith (\i key -> Token key (i < count) (i == count)) [0 ..]

outcomeLabel :: Outcome -> String
outcomeLabel Success = "LINE CLEARED"
outcomeLabel (WrongKey _ _) = "OUT OF ORDER"
outcomeLabel Expired = "TIME RAN OUT"
