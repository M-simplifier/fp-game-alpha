# Signal Courier: an independent platformer brief

[Play, build and read the game](../references/signal-courier/README.md) ·
[Specification](../references/signal-courier/GAME-SPEC.md) ·
[Recorded experiment](../CURRENT-VERIFICATION.md)

Deliver lantern parcels across three connected night-city rooms, using
checkpoints and optional rooftop routes. The new Haskell domain owns physics
and authoritative state at fixed integer ticks; SVG is a projection. Keyboard
and touch controls are implemented. No Afterlight gameplay or assets were
copied.

The game deliberately vendors pinned transition/arena libraries so its Cabal
project and scripts work independently of the foundation. It is excluded from
the root Cabal project to avoid duplicate package identities. Source and runtime
provenance retain their hashes and licenses; vendored core and the WASI shim are
outside this game's authored-source formatting scope.

## What the experiment shows

The recorded native and actual Wasm/Node runs follow a direct winning route and
an all-stamp route. They also check the final playable deadline, replay,
checkpoint recovery and invalid input. Their exact traces, tool versions and
finite coverage belong to the experiment record, not an assertion that a new
checkout has just passed.

Linux CI's native/API/JavaScript checks do not install a Wasm compiler or drive
a browser. The recorded local Wasm execution is separate evidence. Browser
visuals, DOM input, accessibility and device feel need actual host checks; Node
execution cannot supply them. General platformer solvability and fun remain
outside the claim.

Use the game's local continuation and learn-code skills to change or explain
one real interaction. The README points to the rule order and current commands;
there is no second gameplay implementation in the JavaScript host.
