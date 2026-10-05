# Lantern: a finite puzzle

The original Lantern rule says a fish departs once its row is clear after a
single-cell cart move. This library retains that transition and uses the
shared `Step`/`Machine` and `Arena` APIs. Invalid moves emit no game event;
admission rejects them before invoking the rule. The finite graph in the test
enumerates outcomes through `Arena.play`, then uses
`Game.Arena.Finite.forceReach` to answer reachability.

Create a checked board before playing:

```haskell
mkBoard [Cart V 2 2] [1] [2] -- cart begins at column 2, rows 1..2
-- Moving cart 0 by -1 leaves row 2 clear: Departed [2].
```

`Cart` and `Move` values are proposals. `mkBoard` checks counts, dimensions,
collisions and fish-row bounds with overflow-safe coordinate comparisons;
`legal` checks the starting state and each step. A `World` remembers its board,
so passing a state to a different board is rejected. World construction and
record-update fields are hidden; `positions` and `remaining` are ordinary
read-only projection functions. The bit mask counts fish still present, not a
score or arbitrary quantity. The public API compiler fixture confirms that a
consumer cannot record-update `positions`.

The test graph is finite, fully observed and controlled by one participant.
`forceReach` answers reachability for that graph. It does not prove fairness,
strategy under hidden information or a bound for every possible board.

Run `.build/tools/fp-game test` from the foundation root. Origin: selected
MIT technical source from the author's fixture at snapshot
`5335bb14f9ca644fbdc62a00be892f33ad590ba6`. The private generated
illustration and duplicate vendor modules are excluded. This publication
adds checked construction and clearer names; the transition for valid boards
is the selected original rule, exercised by the regression.

For this command, [bootstrap the native CLI](../../docs/native-tooling.md) once
from the foundation root. On Windows use `./.build/tools/fp-game.exe test`;
its explicit game compiler profile is separate from the tool bootstrap compiler.
