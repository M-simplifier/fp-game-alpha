# Validated level data in the real game

This experiment extends Paper Circuit itself, including its production pure
transition, SVG renderer, native tests and GHC-Wasm browser adapter. It is a
small fixed level family, not a new game engine or arbitrary level format.

## Edit data, then play

Build once as described in the README and serve `web/`. Expand **Level tuning**.
Edit `web/level.txt`, increase the revision, choose **Reload level.txt**, then
**New attempt**. No Haskell rebuild is needed for these data changes. Example:

```
revision 1 moveBudget 7 inletRotation 3
```

The initial page still starts the original 18-turn board. Loading is explicit;
there is no file watcher. Reload stages a level, without changing the live
board. New attempt creates a fresh session from the latest accepted level.
Restart repeats the current session's level. Undo retains its once-per-attempt
semantics, including restoring the previous budget and reopening terminal play.

## Boundary and limits

- `Level` is opaque. `level :: Integer -> Integer -> Either LevelError Level`
  checks budget 1–100 and inlet rotation 0–3 before narrowing either to `Int`
- Admission simulates a concrete clockwise solution using the real `step`:
  turn inlet 0 to rotation 2, then turn cells 2 and 11 twice each. This takes
  4–7 turns. The budget must permit this witness to win
- This is a sufficient constructive witness, not a shortest-path solver. For
  example, an equivalent straight-pipe orientation can allow a shorter route;
  admission deliberately accepts only budgets supporting the supplied witness
- Piece kinds, the other 15 rotations, board shape, inlet location, garden goals
  and one-use Undo rule remain fixed. No guarantee covers arbitrary layouts
- `Catalog` and `Revision` constructors are private. `stage` parses a fixed
  record, with a 128-character bound, decimal `Integer` fields, and revisions
  1–1,000,000,000 strictly above the last accepted revision. Failure supplies
  no replacement catalog. No Haskell `Read Int`, JSON DSL or evaluated code
- A `World` contains its immutable validated `Level`. Catalog changes cannot
  mutate a world or its undo snapshot. Default public observations and commands
  retain their original behavior
- The browser transports at most 128 UTF-8 bytes into the Haskell parser. The
  FFI assumes valid owned handles and allocated buffers from the host, as the
  original API did; arbitrary hostile raw Wasm pointer calls are not protected
- A request-generation token discards superseded fetch results, including after
  a newer invalid result or disposal. Haskell independently rejects revisions
  at or below the accepted revision. Failed fetches leave the catalog unchanged

Follow `stage` → `level` → `initialWith` to inspect admission; follow
`newSessionFrom` → `T.start` for adoption. `step Restart` uses `sessionLevel`;
rotation and undo use the original pure transitions. The browser factory has
additive `stage(text)` and `close()` operations, while `loadGame(bytes)` still
returns a callable session factory. Existing sessions survive catalog disposal.
The browser closes both resources on non-bfcache page exit.

## Check

Alongside the README's checks:

```sh
ghc -XGHC2021 -Wall -Werror -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/tuning test/Tuning.hs -o .build/paper-tuning
.build/paper-tuning
node web/tuning.test.mjs
```

Cabal exposes `paper-tuning` as a separate test suite. Opaque API checks now also
reject construction of `Level` and `Catalog`. Native cases cover all four
scrambles, exact witness budgets and smaller-budget rejection, invalid/huge
integers, staging, restart and undo. Real Wasm cases cover stage rejection,
current/new session behavior, superseded asynchronous responses, disposal and
existing gameplay. These are not browser mouse, focus, keyboard or paint tests.
Actual browser UI execution remains unverified; no UI pass is claimed.

## Same-game iteration measurement

Activate the existing GHC-Wasm toolchain, then run:

```sh
python test/iteration/measure.py
```

This intentionally edits the default budget in `src/Paper/Game.hs` locally for
five trials, restoring the original file and rebuilding in `finally`. Run with
no concurrent edits or builds. It does not install tools or publish files.
Both paths change the same budget to 19/20, rotate tile 4, and force the same
Haskell SVG; exact hashes and moves must match for each pair.

The data path starts timing before writing a local data file, sends its path
to an already initialized Node/Wasm process, reads and validates it, creates a
session, rotates, renders and returns a hash. The source path starts before
writing the Haskell constant, incrementally compiles/links, starts a fresh
Node/Wasm runtime, then performs the same gameplay/render observation.
Both include Python/Node protocol overhead. Toolchains and compiler object
caches are warm. The data runtime is warm while the rebuilt runtime must be
initialized; that distinction is intentional and explicitly part of the loop.

Recorded medians were 9.31 ms for data and 2,584.45 ms for source rebuild,
with exact paired observation equality. Raw results are in
`test/iteration/measurements.json`. This is one local environment
and five ordered pairs, not a universal performance claim. It measures neither
HTTP transport nor a file watcher, browser navigation, first paint, input
responsiveness, developer editing time or player enjoyment.
