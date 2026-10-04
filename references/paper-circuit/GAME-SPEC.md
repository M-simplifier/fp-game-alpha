# Paper Circuit — scratch-game acceptance brief

A browser-based 2D pipe-routing puzzle. Click tiles to rotate them clockwise.
Connect the pump at the upper-left to both gardens before the move budget runs
out. The drawing shows the actual wet network, available moves and win/loss.
Restart makes a new attempt. Mouse and touch use the same tile action.

Game-specific source and SVG presentation are newly authored. Only the small
Game.Transition/Game.Arena libraries are reused; no Afterlight game, world,
renderer, assets, physics or save format is copied. Geometry and artwork are
procedural SVG. JavaScript may adapt browser input and display Haskell-generated
SVG, but must not implement pipe connectivity, scoring or win/loss rules.

Acceptance: compile native pure rules and a browser Wasm host; valid clicks
change the visible network, invalid input preserves state, a constructive path
wins within budget, exhaustion stops rotation, reset restores the initial state.
Run the browser host when accessible; Node/WASI checks are not actual browser
interaction. Then implement a second meaningful rule without regeneration.

This is a small playable validation of the workflow, not a commercial-scale
engine or a claim that every platform/genre is already accepted.

## Second iteration

After the first complete build and play-protocol checks, add one undo per attempt.
It restores the previous board and move budget; it cannot be reused until restart.
The game, view, host and native/Wasm tests must all agree.
