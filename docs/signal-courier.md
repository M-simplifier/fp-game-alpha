# Signal Courier: an independent platformer brief

[Game source and commands](../references/signal-courier/README.md) ·
[Specification](../references/signal-courier/GAME-SPEC.md) ·
[Detailed DX evidence](../references/signal-courier/docs/experiment.md)

Three connected night-city rooms, lantern parcel handoffs, checkpoints and
optional rooftop stamps. Keyboard and touch host controls are implemented.
Physics and authoritative state use fixed integer ticks in a new Haskell domain;
SVG is a projection. No Afterlight gameplay or assets were copied.

The shared transition/arena packages and lightweight Wasm plumbing were reused.
The reference vendors pinned core copies intentionally so its own Cabal project
and scripts remain independent of a sibling checkout. It is not added to the
root Cabal project, avoiding duplicate package identities. Root formatting
covers only its src/app/test files, never the vendored core or WASI shim.

## Evidence boundaries

Native and actual Wasm/Node execution verify a direct winning route (422 ticks)
and an all-stamp route (605 ticks), both with zero falls. The final playable tick
can win at tick 10,800; following inputs cannot advance a terminal session.
Bounded invariant enumeration, replay, checkpoint recovery, opaque API compiler
rejection and input ownership checks complement those concrete traces.

Linux CI runs the native game, negative API and pure JavaScript input tests.
This does not install a Wasm compiler or establish browser/device acceptance.
The documented Wasm build and runtime were run locally with the existing
GHC-Wasm 9.14.1.20260330 toolchain. Browser visuals, DOM input and device feel
remain unverified; localhost restrictions were respected rather than bypassed.

The source includes small, explicitly reviewed game-dev and learn-code skills
for continuing this game. They contain public development guidance only.
General platformer solvability and fun are not proved by this experiment.

## Publication integration

The publication policy allowlists the two skill files by exact path; there is
no general `.agents` exception. Core and WASI provenance retain source hashes
and licenses. Generated manifest JSON uses one-space indentation so this larger
reviewed source catalog remains below the unchanged 512 KiB per-file limit.
All ordinary source still receives the same gate and pattern scan.

The official landing page is unchanged in this integration. A future card,
subject to its writing owner's review, could describe: “Signal Courier: a new
2D Haskell platformer with lantern deliveries, checkpoints and optional rooftop
routes. Native and actual Wasm winning traces checked; browser/device input
acceptance pending.” README and documentation provide discovery meanwhile.
