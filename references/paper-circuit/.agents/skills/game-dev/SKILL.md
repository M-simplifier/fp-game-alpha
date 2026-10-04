---
name: game-dev
description: Continue this independent Paper Circuit Haskell/Wasm puzzle: change its own rules, SVG and host, run its checks, and preserve the intended pipe-routing game.
---

Read [the local continuation guide](../../../docs/development.md) and this game's
brief before editing. Select only relevant pinned technical references from
that guide. Work in this game; do not regenerate it or copy another game's rules.

Keep rules and SVG presentation in Haskell. Browser JavaScript transports input
and displays output. Add a gameplay change, update its native and Wasm checks,
then inspect the actual target host when available. Preserve the distinction
between Node/WASI evidence and real browser input/focus/navigation verification.
