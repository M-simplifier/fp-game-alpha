# Paper Circuit

A new browser puzzle implemented from its own brief, using only the shared
`Game.Transition` and `Game.Arena` libraries. It is not an Afterlight fork.
Haskell owns board state, pipe connectivity, budgets, one-use undo, victory,
input validation and SVG presentation. JavaScript only connects browser events
to the compiled Haskell program and displays its output.

## Play

Rotate tiles clockwise to bring water from the left inlet to both garden dots.
You have 18 turns. One undo per attempt restores the previous board and turn
budget; restart replenishes it. A finished game rejects rotation, but undo can
reopen the immediately preceding position if it has not been used.

## Read one turn, then change one rule

1. Start at `step` in [Paper.Game](src/Paper/Game.hs). Its boundary is
   `Command -> World -> (World, [Outcome])`: a player command produces a new
   immutable world and a report. `Cell` is a validated tile address; `Position`
   stores the board and remaining turns; `World` adds the previous position and
   whether the single undo was spent. The latter two representations are private.
2. Trace `Rotate` on cell 0 from `initial`. `rotateTile` first rejects a finished
   game, then looks up the tile. Its rotation changes from 1 to 2, its budget
   changes from 18 to 17, and the old position becomes the undo snapshot. The
   result is `Turned` cell 0. `Undo` restores that snapshot but spends the undo;
   `Restart` restores the entire initial world. The native tests named
   `first rotation is clockwise` and `undo restores visible board and budget`
   check this exact interaction.
3. Read `phase` and `wetCells` next: connected pipe openings spread water from
   the inlet. Watering both gardens wins, even on the last available turn.
4. At the bottom of the module, `Machine` names the same transition's associated
   state/input/output types; `Arena` admits a single gardener command and
   observes a read-only `Scene`. These advanced FP interfaces share rules rather
   than implementing a second game. Continue through [Paper.View](src/Paper/View.hs)
   for SVG, [Browser](app/Browser.hs) for session ownership, and
   [the JS shell](web/engine.mjs) for the ABI. There is no clock or persistence.

Small exercise: reduce the initial budget to 17 in `initial`. Update the budget
expectations in [test/Laws.hs](test/Laws.hs) and [web/smoke.mjs](web/smoke.mjs),
including the 17-turn loss trace and the last-turn win fixture (12 harmless
rotations, then five winning rotations). Keep the constructive win, undo-budget
restoration and victory-before-loss assertions. Run both suites below. This is
an exercise, not an already-applied rule change.

See the [scoped readability review](docs/readability-review.md) for strengths,
remaining improvements, and the limits of this review.

## Build and check

Native core tests require GHC with its bundled `containers` package:

```sh
mkdir -p .build/native
ghc -XGHC2021 -Wall -Werror -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/native test/Laws.hs -o .build/paper-laws
.build/paper-laws
bash test/check-opaque-api.sh
node web/controls.test.mjs
```

Optional historical compatibility check, when this game is inside the foundation
Git clone with its baseline history: `bash test/compare-baseline.sh`. It compares
public observations and outcomes with the pinned original source over all
four-command traces and 200 longer deterministic traces. It requires no network;
a standalone game copy can run the native rules and API checks without it.

Activate GHC-Wasm 9.14.1.20260330 and its matching WASI toolchain on PATH, then:

```sh
bash build-web.sh
node web/smoke.mjs
python -m http.server 8080 --directory web
```

Open the served `index.html` in a browser. The build does not install a compiler,
fetch dependencies, call an LLM, or alter another project. The bundled browser
shim is `@bjorn3/browser_wasi_shim` 0.4.2 with its original MIT/Apache notices.
The source core's MIT notices remain under vendor/.

## Evidence and unfinished acceptance

- Current readability revision: native transition/history/terminal regressions,
  three opaque-API rejection checks and 304 direct/Arena comparisons passed with
  GHC9.6.7. Historical evidence is retained in CHECKS.json
- Haskell Wasm: built with GHC9.14.1.20260330
- Real Wasm in Node with the browser WASI shim: input/refusal, independent
  sessions, win/loss/reset/undo, SVG and repeated allocation/disposal passed
- The original Haskell-generated SVG was rasterized and visually inspected
  separately; visual inspection was not repeated for this readability revision
- Actual browser mouse/touch/keyboard, focus, resize and back/forward execution
  remain unverified. Neither Node tests nor static SVG inspection establish them
- No persistence, level progression or human-enjoyment claim in this slice

First a complete rotation/network game was built and checked. One-use undo was
then added to the existing game, its pure transition, browser adapter, view and
tests without regenerating the project. See GAME-SPEC.md for the original brief.
This is a small workflow exercise, not proof of arbitrary-game or platform DX.

Do not redistribute a compiled Wasm binary without its actual compiler/runtime
and dependency licensing materials. Source publication and binary redistribution
are separate. The working Wasm artifact is intentionally a local build output.

## Continue with an AI

Invoke `$game-dev` after opening this game directory. Its
[local continuation guide](docs/development.md) maps the spec, code, build/test
steps and fixed-version technical knowledge without requiring the parent clone.
