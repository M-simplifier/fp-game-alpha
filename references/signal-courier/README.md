# Signal Courier

A self-contained new Haskell platformer. Deliver three lantern parcels across
a small night city; jump the canals and collect optional rooftop stamps.

## Build and play

With native GHC 9.6+ and GHC-Wasm on PATH:

```sh
./test-native.sh
./build-web.sh
node web/smoke.mjs
python3 -m http.server 8000 --directory web
```

Open the served page in a browser. Arrow keys or A/D move; Space/W/Up jumps.
Touch buttons support movement and jumping. R retries from the last beacon;
Shift+R restarts. Focus loss pauses and clears held keys/queued jumps.

The browser host displays Haskell-produced SVG. JavaScript only transports
input and elapsed time, owns WASI/session lifetime and places SVG in the DOM.
The simulation does not depend on rendering or wall-clock APIs. The optional
Cabal package builds only the native library/tests, not the browser reactor.

`web/game.wasm` is built, ignored output. The checked-in WASI shim retains its
license. No CDN, package install or sibling repository is needed at runtime.

## Continue and learn

Use `.agents/skills/game-dev` for changes and `.agents/skills/learn-code` to
understand the real code. See [experiment evidence and limits](docs/experiment.md).
Project-owned formatter: `python tools/formatter.py plan`, `install`, `check`,
`write`, `check`. Editor-local external Ormolu can use the path printed by the
helper; no editor settings were overwritten or claimed tested.
