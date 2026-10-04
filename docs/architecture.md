# Pure game boundaries and arenas

The stable alpha module names are `Game.Transition`, `Game.Arena` and
`Game.Arena.Finite`. Packages are `game-transition` and `game-arena`.
The explicit record and associated-type APIs use the same transition.

## Reading the types

`Step state input output` wraps `input -> state -> (state, output)`.
A whole input boundary determines the next authoritative state and a value
describing effects. It does not execute those effects. For example:

```haskell
counter :: Step Integer Integer [Integer]
counter = Step $ \increment state -> (state + increment, [increment])
-- replay counter [2,-1] 0 == (1,[2,-1])
```

`Machine witness` names game-specific associated `State`, `Input` and `Output`
types. `machine witness` returns its `Step`. A witness is necessary because
associated type families need not be injective: two games can share a state
type without sharing rules. `stepMachine` simply runs that dictionary.

`Transition state output` fixes inputs and composes state updates. Its
semigroup runs the left transition first, then the right, appending outputs
chronologically. This is generally **not commutative**.

## Laws and assumptions

For total steps and a lawful output monoid, transitions satisfy associativity
and left/right identity, by substitution and the output monoid laws. Equality
means extensional equality on states, not equality of function values.

If `replay step xs s = (middle, first)` and
`replay step ys middle = (final, second)`, then
`replay step (xs ++ ys) s = (final, first <> second)`.
`trace` records every complete boundary; its final state and concatenated
outputs agree with `replay`. Tests exercise 341 small traces and their cuts.

These equations do not permit splitting the commands inside a frame,
deduplicating repeated taps, permuting input, or moving elapsed time across a
pause control. Haskell permits bottom and unsafe IO, so the types alone do
not prove termination, determinism under hidden IO, bounded memory or speed.
`firstDivergence` checks supplied traces using the game's `Eq` instances.

## Admission, observation and play

`Joint participant action` enforces one submission per participant. A repeated
command belongs inside an ordered action batch. Empty submissions can describe
an environment-only boundary; the game decides whether to admit it.

`Arena` adds `Agent`, `Action`, externally recorded `Context`, participant
`View`, and `Rejection`. Its data flow is:

```text
context + joint actions + current state
                  |
                admit ---- rejection (no transition)
                  |
            original kernel input
                  |
             stepMachine
                  |
            next state + effects ---- IO host
                  |
                observe ---- participant view ---- policy
```

The contract is `play m c j s = fmap (\i -> stepMachine m i s) (admit m c j s)`.
Admission compiles a protocol into the original kernel input; it must not
implement another game ruleset. A valid attempt can lose or fail in-world.
`attempt` retains the old state explicitly on rejection. `admittedCandidates`
filters a supplied finite set and makes no completeness claim.

`Policy view action` receives observation history and previous own choices.
The API does not pass authoritative hidden state, another participant's current
choice or future context. Captured hidden values and unsafe IO remain possible.
`observationRespecting` is a bounded audit over supplied histories; it is not
a security proof. Arena regression tests include a state-peeking mutation.

## Finite analysis

`FiniteArena` validates distinct states and closed successor references.
`Choice` has nonempty edges; `Halted` has no continuation. Coalition-controlled
predecessors use existential choice; all other controllers use universal choice.

`forceReach` is the least fixed point of `target union CPre`.
`continueWithin` is the greatest fixed point of `safe intersection CPre`.
Monotonicity and a finite universe make the iterations terminate. The graph
model assumes finite states, complete information, turn-based control and the
stated adversarial interpretation. It does not prove properties of a different
executable game until its abstraction is justified. No scheduler fairness is
implied. Halted targets satisfy reachability but cannot continue forever.
