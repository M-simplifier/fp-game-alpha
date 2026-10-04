---
name: fp-gamedev
description: Implement, extend or review pure functional Haskell games, including domain rules, input/time, simulation, rendering boundaries, saves and performance; design for the game's own genre rather than inheriting a reference game.
---

Read [the shared core](../../../docs/architecture.md) and select only the relevant
[technical practice](../../../docs/practice/README.md). Use `$haskell-excellence`
for Haskell implementation decisions and `$new-game` for a new brief/workspace.

Give this game its own types and rules. Keep authoritative transitions pure and
external effects explicit. Host input, clocks, resources and rendering interpret
that core; references demonstrate techniques, not mandatory starting games.

Implement the next observable player interaction, build it, play it and continue.
Use [headless play](../../../docs/headless-play.md) for abstract decisions and
actual target-host checks for input/presentation. Update save meaning and tests
when rules change. Historical reference parity must not forbid intentional new
behavior. Turn discovered bugs into proportionate reusable prevention checks.
