{-# LANGUAGE TypeFamilies #-}

-- | A discrete deterministic arena layered over the original game kernel.
-- Context belongs to the host; policies choose actions using observations.
module Game.Arena
  ( Arena (..),
    Joint,
    JointError (..),
    joint,
    singleton,
    nobody,
    submissions,
    play,
    admitted,
    admittedCandidates,
    Attempt (..),
    attempt,
    Seen (..),
    Policy (..),
    choose,
    observationRespecting,
  )
where

import Game.Transition

-- | At most one submission per participant at a boundary. Repeated commands
-- must stay inside one action, such as Tapline's ordered command list.
-- The constructor is hidden so callers cannot bypass 'joint'.
newtype Joint participant action = Joint [(participant, action)] deriving (Eq, Show)

-- | A duplicate is a protocol error, independent of a game's own admission.
data JointError participant = DuplicateParticipant participant deriving (Eq, Show)

-- | Validate uniqueness without reordering submissions. Quadratic in the
-- number of participants; this representation targets small joint batches.
joint :: (Eq participant) => [(participant, action)] -> Either (JointError participant) (Joint participant action)
joint entries = validate [] entries
  where
    validate _ [] = Right (Joint entries)
    validate seen ((participant, _) : remaining)
      | participant `elem` seen = Left (DuplicateParticipant participant)
      | otherwise = validate (participant : seen) remaining

-- | A single submission is unique by construction.
singleton :: participant -> action -> Joint participant action
singleton participant action = Joint [(participant, action)]

-- | An environment-only boundary. Whether it is admissible is game-specific.
nobody :: Joint participant action
nobody = Joint []

-- | Read the original ordered submissions without exposing a constructor.
submissions :: Joint participant action -> [(participant, action)]
submissions (Joint entries) = entries

-- | There is no implicit scoring, fairness, perfect information or finite state
-- requirement. An admitted action can fail in-world (for example a wrong guess).
class (Machine machine) => Arena machine where
  type Agent machine
  type Action machine
  type Context machine
  type View machine
  type Rejection machine

  -- | Project the observation available to this participant.
  observe :: machine -> Agent machine -> State machine -> View machine

  -- | Compile choices and recorded external context to the /original/ kernel
  -- input. Admission must not execute a second copy of the game rules.
  admit ::
    machine ->
    Context machine ->
    Joint (Agent machine) (Action machine) ->
    State machine ->
    Either (Rejection machine) (Input machine)

-- | Admit once, then advance the original machine once. A rejection performs
-- no transition. This equation is the central adapter contract.
play ::
  (Arena machine) =>
  machine ->
  Context machine ->
  Joint (Agent machine) (Action machine) ->
  State machine ->
  Either (Rejection machine) (State machine, Output machine)
play witness context choices state = do
  input <- admit witness context choices state
  pure (stepMachine witness input state)

-- | Query admission only; do not run the kernel.
admitted :: (Arena machine) => machine -> Context machine -> Joint (Agent machine) (Action machine) -> State machine -> Bool
admitted witness context choices state = case admit witness context choices state of
  Left _ -> False
  Right _ -> True

-- | Filter a supplied finite candidate list. This does not assert that the
-- candidates enumerate every action of the game.
admittedCandidates ::
  (Arena machine) =>
  machine ->
  Context machine ->
  [Joint (Agent machine) (Action machine)] ->
  State machine ->
  [Joint (Agent machine) (Action machine)]
admittedCandidates witness context candidates state =
  filter (\candidate -> admitted witness context candidate state) candidates

-- | Explicitly retain the original state on protocol rejection.
data Attempt state output rejection = Rejected rejection state | Advanced state output deriving (Eq, Show)

-- | A state-preserving wrapper around 'play', useful in a host loop.
attempt ::
  (Arena machine) =>
  machine ->
  Context machine ->
  Joint (Agent machine) (Action machine) ->
  State machine ->
  Attempt (State machine) (Output machine) (Rejection machine)
attempt witness context choices state = case play witness context choices state of
  Left rejection -> Rejected rejection state
  Right (next, output) -> Advanced next output

-- | One observation and the participant's own previous choice.
data Seen view action = Seen {view :: view, previousOwnChoice :: Maybe action} deriving (Eq, Show)

-- | A policy receives its observation history. The interface does not supply
-- authoritative state, another player's current choice or future context.
-- Haskell types alone cannot exclude hidden captures, bottom or unsafe IO.
newtype Policy view action = Policy {runPolicy :: [Seen view action] -> action}

-- | Run the supplied policy on the supplied history.
choose :: Policy view action -> [Seen view action] -> action
choose = runPolicy

-- | Check equal projected observations imply equal choices over the supplied
-- histories. A bounded audit, not an information-security or totality proof.
observationRespecting :: (Eq view, Eq action) => (history -> view) -> (history -> action) -> [history] -> Bool
observationRespecting project policy histories =
  and
    [project x /= project y || policy x == policy y | x <- histories, y <- histories]
