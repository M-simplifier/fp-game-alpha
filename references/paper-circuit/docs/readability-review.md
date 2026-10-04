# Paper Circuit readability review

Scope: `src/Paper/Game.hs`, the README reading path, and the transition tests.
This is an author review using the foundation's seven-dimension rubric, not a
human study, a guarantee of beginner comprehension, or a review of every reference.
The same standard should be applied when an AI adds or changes this game.

## Rubric assessment

- Domain vocabulary — 2/2: `Position`, `previousPosition`, `UndoUse`, and
  `rotateTile` replace a positional state tuple and an unexplained Boolean.
- Type meaning — 2/2: `Cell` validation, private `World`, and the limited meaning
  of the `Rotation` alias are documented. `Position` prevents history from
  restoring undo availability. The README explains Machine's associated types.
- Local reasoning — 2/2: `step` shows the three commands; `rotateTile` states its
  terminal guard before lookup, update, snapshot, and outcome.
- Function shape — 2/2: undo and rotation each have one named helper. `wetCells`
  separates connected neighbors from traversal without an extra framework.
- Boundary clarity — 2/2: the reading path identifies the pure transition,
  admission, observation, SVG projection, Haskell session IO, and JS host.
- Failure visibility — 2/2: refusal returns the unchanged world; terminal games
  may undo or restart. Last-turn victory is explicitly ordered before loss.
- Example quality — 1/2: the first rotation and terminal history have executable
  checks; the budget exercise gives exact fixtures but has not been tried by a
  new reader, and actual browser interactions remain unchecked.

Total: 13/14, a review judgment only. A score cannot establish usability or
replace behavioral, boundary, licensing, or browser checks.

## Two strengths

1. The actual `step -> rotateTile` path speaks in game terms while retaining the
   same pure transition and Machine/Arena integration.
2. `test/Laws.hs` covers snapshots across win/loss/refusal and one-use undo;
   `test/check-opaque-api.sh` checks that clients cannot forge Cell/World or use
   the new private history selector to update World.

## Highest-impact remaining improvements

1. Have a Haskell beginner follow the first-turn reading path and perform the
   budget exercise without assistance; record confusion rather than inferring
   readability from this author's score.
2. Give `wetCells` a small worked connectivity example if traversal proves the
   next stumbling block. Current tests exercise outcomes but do not teach the
   seen-set algorithm independently.
3. Review `Paper.View` and `app/Browser.hs` separately for layout and lifetime
   readability, then test actual keyboard, focus, touch, resize and history UI.

## Compatibility and evidence limits

Public names and function types remain unchanged. Cell/World stay opaque;
record selectors are deliberately absent from the export list.
`test/compare-baseline.sh` reproduces the historical comparison against its pinned
Git source, validating the baseline hash before compilation. Equality retains
its state meaning. Derived `Show World` now uses the named internal structure;
it was not a save format, and its text is not preserved. Rotation is an `Int`
alias, not a proof of a legal angle. Neither GHC nor these tests establishes all
possible traces. Native and Node/Wasm checks are recorded in `CHECKS.json`, with
prior evidence preserved separately. No browser UI or repeated SVG visual
inspection is claimed for this change.

## Live-tuning addition (author review)

`stage` admits a fixed record into an opaque `Catalog`; `level` handles the
actual game constraints and constructive witness. `initialWith` creates a World
with a captured `sessionLevel`, so tracing Restart does not require inspecting
mutable browser state. Rotation/Undo still use the original rules. This adds
one small public module and one private Level field, rather than embedding
revision management in every gameplay command.

Tradeoffs: the positional two-field Level stays private and small, and the
witness is deliberately conservative rather than a general solver. Browser
errors currently distinguish staged/rejected only; the pure API has typed
errors, but the FFI does not expose their detail. Real browser usability and
a novice reading exercise remain unverified.
