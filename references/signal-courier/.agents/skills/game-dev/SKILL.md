---
name: game-dev
description: Continue Signal Courier, a pure Haskell fixed-tick browser platformer.
---
Read GAME-SPEC.md, README.md and docs/experiment.md. Preserve current user edits.
The domain is src/Signal/Game.hs; SVG is a projection in src/Signal/View.hs.
Keep host events and clocks in web/controls.mjs and web/index.html.
Run ./test-native.sh, ./build-web.sh, node web/smoke.mjs and the pinned formatter.
Use the public pinned knowledge links in docs/experiment.md; do not inherit a
reference game's domain or import its framework. Browser and device play remain
required before claiming controls, presentation or feel verified.
