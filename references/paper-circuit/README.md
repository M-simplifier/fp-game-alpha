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

## Build and check

Native core tests require GHC with its bundled `containers` package:

```sh
mkdir -p .build/native
ghc -XGHC2021 -Wall -Werror -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/native test/Laws.hs -o .build/paper-laws
.build/paper-laws
```

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

- Native pure rules: constructive win, invalid cells, exhausted budget, reset,
  one-use undo and 304 direct/Arena comparisons passed with GHC9.6.6
- Haskell Wasm: built with GHC9.14.1.20260330
- Real Wasm in Node with the browser WASI shim: input/refusal, independent
  sessions, win/loss/reset/undo, SVG and repeated allocation/disposal passed
- Haskell-generated SVG was rasterized and visually inspected separately
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
