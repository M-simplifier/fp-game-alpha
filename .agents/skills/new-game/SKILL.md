---
name: new-game
description: Start a user's independent pure functional game project from this foundation and continue into their actual gameplay implementation. Use for a new game workspace, not generic Haskell questions.
---

Read [the creation and continuation workflow](../../../docs/new-game.md) and
[the supported routes](../../../docs/platforms.md). Reuse known decisions;
detect tools and OS before asking at most four missing questions.

Select a real route, show its alpha limits, and follow doctor → plan →
scaffold → build/check/test/run. Keep the game outside the starter checkout
by default, preserve existing directories, and leave game licensing independent.

After the first scaffold works, implement the user's promised mechanic through
state/rules/view/regressions. Continue in the generated project's local
`$game-dev` workflow. A renamed demo or a successful scaffold is not completion.
