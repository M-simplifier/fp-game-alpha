# River Home: pure village rules and validated saves

This reference has a small 20 × 16 village, a garden, firewood, weather, a
neighbor's dinner promise, and a day that ends only when the player sleeps at
home. The first observable action can be `Tick 0 0`: it advances one logical
1/30-second movement boundary without changing the player's position. Walk
near a plot and `Interact` to plant or water it. The authored scenarios in
`scenarioGame` reach days one to three and the shared dinner through real
commands, not by constructing private game state.

Read `Life.Domain` in this order: `Game` and its read-only projections;
`advance` for the command decision; `interactionTarget` for the common
prompt/action target; `sleep` for the overnight crop/wood/weather update; then
`encodeGame`/`decodeGame` for persistence. `Game`'s constructor and update
fields are private. A `Cell` is merely an input/view coordinate: build and
movement rules validate it. `Life.Adapter` places the unchanged `advance`
behind `Step`/`Machine` and an `Arena`. Admission separates `MovementTick`
from `InteractionBoundary`; a no-input movement boundary means `Tick 0 0`.
An invalid build is admitted and resolved as an in-world no-op with a notice,
because the domain rule, rather than the protocol adapter, owns construction.

For a complete tiny trace, `replay riverStep [Tick 0 0, ChooseBuild Roof]
initialGame` yields the same state/effects as two calls to `advance`. Split
each command with `splitCommand` and `play RiverArena` yields the same result.
`RiverView` is a disposable projection. Its named `Int` fields aid reading but
do not create unit or range safety. Returned `Effect` values are host requests,
not saved authority.

`Life.Clock.schedule` allocates at most eight ticks to a frame and retains
the rest as microsecond debt. The host must apply exactly that many `Tick`
commands; scheduling alone does not advance the game. The clock and game
state are separate so pause/control policy remains a host responsibility.
The snapshot codec has a 65,536-code-point cap, version and field validation,
then reconstructs `Game`; it does not deserialize a public `Game` constructor.
Save round-trip and continuation checks cover selected scenarios. There is no
automatic migration, crash-durable storage, or guarantee for arbitrary future
game changes.

Run `python tools/fp_game.py test` at the foundation root. The public test
checks the authored journey, weather/crop/wood differences, overnight report,
save rejection and continuation, direct Step/Arena agreement, protocol
rejection, finite invariant-preserving prefixes, extreme tick saturation,
clock debt, and a deleted-rule mutation. The original author suite included
QuickCheck properties; those dependencies are outside this offline alpha
profile, so its 350-case runs are historical and **not** claimed here. These
finite tests do not prove every command sequence, player experience, native or
Web renderer, or device performance.

The original `Life.Domain` and `Life.Clock` and per-title MIT notice were
selected from the author's technical snapshot
`5335bb14f9ca644fbdc62a00be892f33ad590ba6`. The publication manifest
records original digests; only explanatory Haddock was added to the domain
rules. This edition adds the named-view adapter, executable focused checks
and a reading path. It includes no private Git history, binary, artwork,
font, or graphical host.
