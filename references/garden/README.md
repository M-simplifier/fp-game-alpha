# Garden: pure world, controls, and clock

Garden is an 80 × 44 immutable simulation. `Garden.World` hides construction of
`Coord`, `Seed`, and `World`; `coord` validates board bounds, and the same seed
gives the same initial terrain. `Garden.Simulation.stepWorld` owns movement and
growth rules. `Garden.Session.advance` distinguishes player `Input` from a
logical `Tick`; ordinary edits do not move time. `Garden.View.project` creates
disposable render data without IO or an authoritative-state update.

There are two useful input boundaries:

- `garden` / `GardenArena` apply one event. A simulation tick admits no player
  action; a command admits exactly one gardener action.
- `gardenClock` / `GardenClockArena` apply one complete host frame. The frame
  carries elapsed microseconds and an ordered command batch. The scheduler
  processes controls before ticks, caps work at five ticks per frame, retains
  running debt, and clears debt at pause, step, reset, or resume edges.

For example, begin with `newSession (seedFromText "my-garden")`. It starts
paused. `Input TogglePause` resumes it; a `Tick` then updates the world. A
`StepOnce` command advances one tick and leaves it paused. `ResetSameSeed`
rebuilds the original terrain. A host should interpret returned `Effect`
values after applying the pure transition.

`ElapsedMicros` is a newtype at the frame-adapter boundary so elapsed host
microseconds are not confused with logical tick counts. The legacy scheduler
still accepts an `Integer` internally and clamps negative readings. `Seed`,
`Coord`, and session/clock construction are restricted by their modules;
the world fingerprint is diagnostic and **not** a collision-free identity.
The screen-input adapter checks bounds before subtracting its pixel origin,
including extreme `Int` coordinates.

Run `python tools/fp_game.py test` from the foundation root. The regression
checks deterministic seed/reset, event Step/Arena agreement, scheduler
Step/Arena agreement, the five-tick cap and debt, pause/resume
edges, pixel bounds, a dropped-tick mutation, and a counterexample to splitting
one frame across a control edge. These are finite traces and local invariants,
not a proof of every world state, renderer, save path, or device performance.

The six original source modules and per-title MIT notice were selected from
the author's gallery snapshot `5335bb14f9ca644fbdc62a00be892f33ad590ba6`.
The publication manifest records each original digest. This edition adds
explicit shared-library adapters, safer screen-coordinate validation, an
auditable example and regressions. No private Git history, artwork, compiled
toolchain, or graphical host is included.
