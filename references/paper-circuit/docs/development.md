# Continue Paper Circuit

Start with [the game brief](../GAME-SPEC.md), [commands and limits](../README.md)
and [recorded checks](../CHECKS.json). This directory is an independent game:
its vendored core and Cabal project do not require the parent foundation clone.
Do not regenerate it to make a feature change.

## Locate the decision

- [Paper.Game](../src/Paper/Game.hs): opaque Cell/World, pipe connectivity,
  budget, win/loss, restart, once-per-attempt Undo and original Arena transition
- [Paper.Tuning](../src/Paper/Tuning.hs): bounded record admission and staged
  catalog; see [live tuning](live-tuning.md) for session adoption and checks
- [Paper.View](../src/Paper/View.hs): pure SVG projection from the player scene
- [Browser](../app/Browser.hs): owned StablePtr/IORef session, validated numeric
  input, SVG allocation/free and Haskell runtime exports
- [engine.mjs](../web/engine.mjs): WASI initialization and owned session lifecycle
- [controls.mjs](../web/controls.mjs): input/focus target routing, no game rules
- [index.html](../web/index.html): loading/error UI, real browser events and display

For a rule change, update native [laws](../test/Laws.hs) and actual Wasm
[smoke checks](../web/smoke.mjs). Input-routing changes also use
[controls tests](../web/controls.test.mjs). The latter use DOM stubs, not real
keyboard/focus evidence. Compile the native package with ordinary Cabal or the
README's direct GHC command, build Wasm with `bash build-web.sh`, then run the
Node tests. Serve `web/` and inspect actual browser behavior when available.
Do not confuse a Node pass or an SVG image with that final check.

## Choose the next meaningful change

The first slice and later Undo iteration are recorded in the brief. A useful
next feature could be another designed level with a different routing decision.
Define its player goal and solution/budget evidence first, implement the rule
and presentation, then play and revise it. This is an option, not a requirement
to add features the user did not request. Save formats do not yet exist; if added,
include restart/load semantics, corruption handling and compatibility tests.

## Keep the technical knowledge reachable

The following links pin public foundation revision
`dba7da9e3162a0b1c0a59cfe138142d063ef0cfc`. They are reading references, not build
dependencies. The separately vendored code revision is in
[foundation.lock.json](../foundation.lock.json).

- [Haskell types/errors/effects/laziness](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/haskell/technique-choices.md)
- [Meaningful properties and independent models](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/haskell/verification-review.md)
- [Browser loading/input/persistence and ABI boundaries](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/browser.md)
- [Time/input/save meaning](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/time-and-state.md)
- [Resource ownership and rendering projections](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/space-and-resources.md)
- [Evidence and guarantee scope](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/verification.md)

Those guides include other games' technical examples. Paper Circuit does not
inherit their renderer, rules, assets or previous validation. For offline reading,
copy only needed guides with their MIT notice and deliberately update links.

## Keep changes readable

Use the README's first-turn reading path and `docs/readability-review.md` when
reviewing handwritten or AI-generated changes. Name new state by its game role,
keep the public constructors/selectors intentionally opaque, and preserve the
single pure rule implementation behind Machine/Arena. Add a rule regression
before extending the example; do not treat the rubric score as proof of quality.
