-- | Optional finite, complete-information, turn-based analysis. This model is
-- separate from executable 'Game.Arena.Arena': a clock is not implicitly fair.
module Game.Arena.Finite
  ( Controller (..),
    Node (..),
    FiniteArena,
    ArenaError (..),
    finiteArena,
    states,
    controllablePredecessor,
    forceReach,
    continueWithin,
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE

-- | Other participants and external choices are adversarial for a coalition
-- query. This is a query assumption, not a statement about their intentions.
data Controller participant = Participant participant | External deriving (Eq, Show)

-- | A deadlock/terminal state or a nonempty set of labelled successors.
data Node participant action state = Halted | Choice (Controller participant) (NonEmpty (action, state))
  deriving (Eq, Show)

-- | A closed finite graph. The hidden constructor enforces distinct states
-- and known successors through 'finiteArena'.
newtype FiniteArena state participant action = FiniteArena [(state, Node participant action state)]
  deriving (Eq, Show)

-- | Structural errors in a proposed graph.
data ArenaError state = DuplicateState state | UnknownSuccessor state deriving (Eq, Show)

-- | Validate closure and uniqueness while retaining row and edge order.
finiteArena ::
  (Eq state) =>
  [(state, Node participant action state)] ->
  Either (ArenaError state) (FiniteArena state participant action)
finiteArena rows = do
  distinct [] universe
  mapM_ checkNode (map snd rows)
  pure (FiniteArena rows)
  where
    universe = map fst rows
    distinct _ [] = Right ()
    distinct seen (state : remaining)
      | state `elem` seen = Left (DuplicateState state)
      | otherwise = distinct (state : seen) remaining
    checkNode Halted = Right ()
    checkNode (Choice _ edges) = mapM_ known (NE.toList edges)
    known (_, successor)
      | successor `elem` universe = Right ()
      | otherwise = Left (UnknownSuccessor successor)

-- | States in original row order.
states :: FiniteArena state participant action -> [state]
states (FiniteArena rows) = map fst rows

-- | Coalition-owned nodes need one target successor; other controllers need
-- all successors in the target. 'Halted' is false, avoiding vacuous deadlock
-- guarantees from @all []@.
controllablePredecessor ::
  (Eq state, Eq participant) =>
  [participant] -> [state] -> FiniteArena state participant action -> [state]
controllablePredecessor coalition target (FiniteArena rows) =
  [state | (state, node) <- rows, succeeds node]
  where
    succeeds Halted = False
    succeeds (Choice controller edges) =
      let outcomes = map ((`elem` target) . snd) (NE.toList edges)
       in case controller of
            Participant participant | participant `elem` coalition -> or outcomes
            _ -> and outcomes

-- | Least fixed point of @target union CPre@. The coalition can force eventual
-- target membership against all other choices. Halted targets already satisfy
-- reachability. Targets outside the graph are ignored.
forceReach ::
  (Eq state, Eq participant) =>
  [participant] -> [state] -> FiniteArena state participant action -> [state]
forceReach coalition target arena = fixed []
  where
    step current =
      [ state
      | state <- states arena,
        state `elem` target || state `elem` controllablePredecessor coalition current arena
      ]
    fixed current = let next = step current in if next == current then current else fixed next

-- | Greatest fixed point of @safe intersection CPre@. This means continuing
-- forever within the safe set, so even a safe halted node fails this query.
continueWithin ::
  (Eq state, Eq participant) =>
  [participant] -> [state] -> FiniteArena state participant action -> [state]
continueWithin coalition safe arena = fixed (states arena)
  where
    step current =
      [ state
      | state <- states arena,
        state `elem` safe && state `elem` controllablePredecessor coalition current arena
      ]
    fixed current = let next = step current in if next == current then current else fixed next
