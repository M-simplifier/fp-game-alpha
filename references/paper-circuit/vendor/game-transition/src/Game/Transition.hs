{-# LANGUAGE TypeFamilies #-}

-- | A game owns its state, input boundaries and output meaning. This module
-- composes those boundaries without imposing ticks, rewards or rendering.
-- See @docs/architecture.md@ for the laws and their totality assumptions.
module Game.Transition
  ( Step (..),
    Machine (..),
    stepMachine,
    Transition (..),
    forInput,
    replay,
    Observation (..),
    trace,
    Divergence (..),
    firstDivergence,
  )
where

-- | An explicit dictionary for one complete input boundary. The resulting
-- output describes effects; executing those effects belongs to an IO host.
newtype Step state input output = Step
  {runStep :: input -> state -> (state, output)}

-- | Optional instance syntax for the same dictionary. The witness distinguishes
-- machines whose associated state or input types happen to be identical.
class Machine machine where
  type State machine
  type Input machine
  type Output machine
  machine :: machine -> Step (State machine) (Input machine) (Output machine)

-- | Apply exactly one boundary using an explicit machine witness.
stepMachine ::
  (Machine machine) =>
  machine -> Input machine -> State machine -> (State machine, Output machine)
stepMachine witness = runStep (machine witness)

-- | A state transformer with accumulated output. @first <> second@ runs first
-- and then second, appending outputs in that same chronological order.
newtype Transition state output = Transition
  {runTransition :: state -> (state, output)}

instance (Semigroup output) => Semigroup (Transition state output) where
  Transition first <> Transition second = Transition $ \initial ->
    let (middle, firstOutput) = first initial
        (final, secondOutput) = second middle
     in (final, firstOutput <> secondOutput)

instance (Monoid output) => Monoid (Transition state output) where
  mempty = Transition $ \state -> (state, mempty)

-- | Fix one input to obtain a composable transition.
forInput :: Step state input output -> input -> Transition state output
forInput (Step advance) input = Transition (advance input)

-- | Replay whole input boundaries in list order. Outputs require a lawful
-- monoid. This does not authorize splitting a frame's internal command batch.
replay :: (Monoid output) => Step state input output -> [input] -> state -> (state, output)
replay step inputs = runTransition (foldMap (forInput step) inputs)

-- | Retain the state and output on both sides of one input boundary.
data Observation state input output = Observation
  { before :: state,
    observedInput :: input,
    after :: state,
    emitted :: output
  }
  deriving (Eq, Show)

-- | Inspect each boundary separately; output need not be a monoid.
trace :: Step state input output -> [input] -> state -> [Observation state input output]
trace _ [] _ = []
trace step (input : remaining) state =
  let (next, output) = runStep step input state
   in Observation state input next output : trace step remaining next

-- | First mismatch in authoritative state or emitted output. Indices are
-- zero-based. Equality here is only the equality supplied by the game.
data Divergence state input output = Divergence
  { boundaryIndex :: Int,
    leftObservation :: Observation state input output,
    rightObservation :: Observation state input output
  }
  deriving (Eq, Show)

-- | Compare a refactor or adapter on one supplied trace. @Nothing@ says only
-- that this trace agrees; it is not universal equivalence or a performance test.
firstDivergence ::
  (Eq state, Eq output) =>
  Step state input output ->
  Step state input output ->
  [input] ->
  state ->
  Maybe (Divergence state input output)
firstDivergence left right inputs initial = compareFrom 0 initial initial inputs
  where
    compareFrom _ _ _ [] = Nothing
    compareFrom index leftState rightState (input : remaining) =
      let (leftNext, leftOutput) = runStep left input leftState
          (rightNext, rightOutput) = runStep right input rightState
          leftSeen = Observation leftState input leftNext leftOutput
          rightSeen = Observation rightState input rightNext rightOutput
       in if leftNext /= rightNext || leftOutput /= rightOutput
            then Just (Divergence index leftSeen rightSeen)
            else compareFrom (index + 1) leftNext rightNext remaining
