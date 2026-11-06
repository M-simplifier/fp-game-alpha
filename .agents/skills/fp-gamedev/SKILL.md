---
name: fp-gamedev
description: Implement, extend or review pure functional Haskell games, including domain rules, input/time, simulation, rendering boundaries, saves and performance; design for the game's own genre rather than inheriting a reference game.
---

Read [the shared core](../../../docs/architecture.md) and select only the relevant
[technical practice](../../../docs/practice/README.md). Use `$haskell-excellence`
for Haskell implementation decisions and `$new-game` for a new brief/workspace.
Use [game-experience](../game-experience/SKILL.md) when changing player choices,
feedback, UI/help or Japanese copy, selecting only the relevant reference.

Use [game-research](../game-research/SKILL.md) for a research question or to assess
knowledge beyond the current implementation guides. Follow the selected
[catalog](../../../research/catalog.json) entry to actual source, evidence and
limits before reusing it. A study's status does not make its policies mandatory
for this game; a request only to explore does not start the implementation loop.

Give this game its own types and rules. Keep authoritative transitions pure and
external effects explicit. Host input, clocks, resources and rendering interpret
that core; references demonstrate techniques, not mandatory starting games.

Implement the next observable player interaction, build it, play it and continue.
Use [headless play](../../../docs/headless-play.md) for abstract decisions and
actual target-host checks for input/presentation. Update save meaning and tests
when rules change. Historical reference parity must not forbid intentional new
behavior. Turn discovered bugs into proportionate reusable prevention checks.
