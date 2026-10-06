# Tapline: ordered input at a real frame boundary

Tapline is a six-round pure game core. Each round presents an ordered sequence
of J/K taps; repeated letters require repeated commands. A host submits one
`Frame` containing its observed wall-clock `Stamp`, focus state, and **ordered**
command list. `Tapline.Domain.frame` returns the next authoritative `Session`
and chronological `Effect` values. `Tapline.View.project` derives everything a
renderer needs without changing the game state.

The smallest winning opening is:

```haskell
let start = initial (stamp 0)
    first = Frame (stamp 0) True [TogglePause, Tap J, Tap K]
-- frame first start ends round 1 with Success.
```

The source keeps `Stamp` distinct from the active challenge time. Wall-clock
regressions are clamped, pauses stop active time, and a lost-focus frame drops
its command batch. All due deadlines settle **before** commands: tapping at
exactly seven seconds expires the round. `Reset` is a barrier within its frame
and discards following commands. Splitting a frame around reset, deduplicating
repeated keys, or reordering taps changes the game; these are explicit
counterexamples to overbroad transition laws.

`Tapline.Adapter` exposes the original rule as both `Step`/`Machine` and an
`Arena`. The arena receives time and focus as host context and one ordered
command list as the player's action. An empty joint action is a valid clock
frame. `observe` returns the pure render model. Admission never implements a
second Tapline rule.

Run `.build/tools/fp-game test` from the foundation root. The regression
plays all six winning rounds, compares direct/Step/Arena outputs, and checks
the deadline, reset, order, focus pause, and a deduplication mutation. The
package is an executable **pure-core reference**; graphical hosting and
device input/performance have not been validated by this package.

The selected four original core modules came from the author's technical
gallery snapshot `5335bb14f9ca644fbdc62a00be892f33ad590ba6`. Their
original file digests and the per-title MIT license are in the publication
manifest. This edition adds a thin shared-library adapter, named behavior
boundaries, reader guidance, and explicit regressions. No old private Git
history, artwork, binaries, or browser host is included.

For this command, [bootstrap the native CLI](../../docs/native-tooling.md) once
from the foundation root. On Windows use `./.build/tools/fp-game.exe test`;
its explicit game compiler profile is separate from the tool bootstrap compiler.
