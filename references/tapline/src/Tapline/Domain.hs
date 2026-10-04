-- | Six-round ordered-key game. 'frame' is the authoritative boundary;
-- effects describe what a host may render or play after the pure update.
module Tapline.Domain
  ( Session,
    Frame (..),
    Phase (..),
    Round (..),
    Outcome (..),
    Result (..),
    Effect (..),
    initial,
    frame,
    replay,
    phase,
    isPaused,
    activeMicros,
    results,
    generation,
    scenario,
    roundBudget,
    feedbackDuration,
  )
where

import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Tapline.Clock
import Tapline.Input

-- | One indivisible host frame. Commands retain order and duplicates.
data Frame = Frame {observedAt :: Stamp, hasFocus :: Bool, commands :: [Command]}
  deriving (Eq, Show)

-- | The remaining challenge at one round; the deadline uses active microseconds.
data Round = Round
  { roundNumber :: Int,
    sequenceKeys :: NonEmpty Key,
    matched :: Int,
    deadline :: Integer,
    following :: [NonEmpty Key]
  }
  deriving (Eq, Show)

data Outcome = Success | WrongKey Key Key | Expired deriving (Eq, Show)

data Result = Result {resultRound :: Int, outcome :: Outcome, resultAt :: Integer}
  deriving (Eq, Show)

data Phase = Ready | Challenge Round | Feedback Round Outcome Integer | Complete
  deriving (Eq, Show)

-- | Chronological output; an IO host interprets these after the transition.
data Effect
  = BeganRound Int
  | MatchedKey Key
  | EndedRound Result
  | Paused
  | Resumed
  | Restarted Int
  | FocusLost
  | BatchDiscarded Int
  deriving (Eq, Show)

-- | Authoritative state. Its constructor and record fields remain private.
data Session = Session
  { sessionPhase :: Phase,
    sessionPaused :: Bool,
    sessionActiveMicros :: Integer,
    sessionResults :: [Result],
    sessionGeneration :: Int,
    wallClock :: Clock
  }
  deriving (Eq, Show)

-- Ordinary read functions, not exported record selectors. External code cannot
-- record-update the authoritative state; only initial/frame/replay can create it.
phase :: Session -> Phase
phase = sessionPhase

isPaused :: Session -> Bool
isPaused = sessionPaused

activeMicros :: Session -> Integer
activeMicros = sessionActiveMicros

results :: Session -> [Result]
results = sessionResults

generation :: Session -> Int
generation = sessionGeneration

roundBudget, feedbackDuration :: Integer
roundBudget = 7000000
feedbackDuration = 900000

scenario :: NonEmpty (NonEmpty Key)
scenario = (J :| [K]) :| [K :| [J], J :| [J, K], K :| [K, J], J :| [K, K, J], K :| [J, K, J, K]]

-- | Anchor wall time without starting the active challenge clock.
initial :: Stamp -> Session
initial now = Session Ready False 0 [] 0 (anchor now)

-- | Settle all due time boundaries before applying this frame's command batch.
-- At an exact deadline, expiry wins over a tap. Focus loss pauses and drops
-- the command batch; reset discards commands after it in the same frame.
frame :: Frame -> Session -> (Session, [Effect])
frame input old =
  let clockRuns = not (sessionPaused old) && inPlay (sessionPhase old) && hasFocus input
      (dt, clock') = observe clockRuns (observedAt input) (wallClock old)
      (settled, dueEffects) = settleDueBoundaries (sessionActiveMicros old + dt) old {wallClock = clock'}
   in if not (hasFocus input)
        then
          let lost = inPlay (sessionPhase settled) && not (sessionPaused settled)
              s = if lost then settled {sessionPaused = True} else settled
           in ( s,
                dueEffects
                  ++ (if lost then [FocusLost, Paused] else [])
                  ++ [BatchDiscarded (length (commands input)) | not (null (commands input))]
              )
        else
          let (s, fx) = applyCommands (commands input) settled
           in (s, dueEffects ++ fx)

inPlay :: Phase -> Bool
inPlay (Challenge _) = True
inPlay (Feedback _ _ _) = True
inPlay _ = False

-- Resolve all due boundaries at their scheduled times. At equality time wins.
settleDueBoundaries :: Integer -> Session -> (Session, [Effect])
settleDueBoundaries target s = case sessionPhase s of
  Challenge r
    | target >= deadline r ->
        let (ended, fx) = endRound (deadline r) Expired r s
            (rest, more) = settleDueBoundaries target ended
         in (rest, fx ++ more)
  Feedback r _ feedbackEnds | target >= feedbackEnds ->
    case following r of
      [] -> (s {sessionPhase = Complete, sessionActiveMicros = feedbackEnds, sessionPaused = False}, [])
      keys : remaining ->
        let n = roundNumber r + 1
            next = Round n keys 0 (feedbackEnds + roundBudget) remaining
            (rest, fx) = settleDueBoundaries target s {sessionPhase = Challenge next, sessionActiveMicros = feedbackEnds}
         in (rest, BeganRound n : fx)
  _
    | inPlay (sessionPhase s) -> (s {sessionActiveMicros = target}, [])
    | otherwise -> (s, [])

endRound :: Integer -> Outcome -> Round -> Session -> (Session, [Effect])
endRound at verdict r s =
  let result = Result (roundNumber r) verdict at
   in ( s
          { sessionPhase = Feedback r verdict (at + feedbackDuration),
            sessionActiveMicros = at,
            sessionResults = sessionResults s ++ [result]
          },
        [EndedRound result]
      )

applyCommands :: [Command] -> Session -> (Session, [Effect])
applyCommands [] s = (s, [])
applyCommands (Reset : rest) s =
  let next =
        s
          { sessionPhase = Ready,
            sessionPaused = False,
            sessionActiveMicros = 0,
            sessionResults = [],
            sessionGeneration = sessionGeneration s + 1
          }
   in (next, [Restarted (sessionGeneration next)] ++ [BatchDiscarded (length rest) | not (null rest)])
applyCommands (cmd : rest) s =
  let (s', fx) = applyCommand cmd s
      (s'', more) = applyCommands rest s'
   in (s'', fx ++ more)

applyCommand :: Command -> Session -> (Session, [Effect])
applyCommand TogglePause s = case sessionPhase s of
  Ready ->
    let keys :| remaining = scenario
     in (s {sessionPhase = Challenge (Round 1 keys 0 roundBudget remaining)}, [BeganRound 1])
  Complete -> (s, [])
  _ ->
    let paused = not (sessionPaused s)
     in (s {sessionPaused = paused}, [if paused then Paused else Resumed])
applyCommand (Tap key) s
  | sessionPaused s = (s, [])
  | otherwise = case sessionPhase s of
      Challenge r -> case drop (matched r) (NE.toList (sequenceKeys r)) of
        expected : remaining
          | key /= expected -> endRound (sessionActiveMicros s) (WrongKey expected key) r s
          | null remaining ->
              let (s', fx) = endRound (sessionActiveMicros s) Success r {matched = matched r + 1} s
               in (s', MatchedKey key : fx)
          | otherwise -> (s {sessionPhase = Challenge r {matched = matched r + 1}}, [MatchedKey key])
        [] -> (s, [])
      _ -> (s, [])
applyCommand Reset s = (s, []) -- reset is the batch barrier in applyCommands

-- | Compose complete frames. Splitting inside one command batch changes the
-- reset barrier and is therefore not a valid replay partition.
replay :: [Frame] -> Session -> (Session, [Effect])
replay inputs start = foldl' step (start, []) inputs
  where
    step (s, fx) input = let (next, new) = frame input s in (next, fx ++ new)
