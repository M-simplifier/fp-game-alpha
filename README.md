# fp-game-alpha

[日本語の紹介ページ](https://m-simplifier.github.io/fp-game-alpha/) · [配達を一件、コードで追う](https://m-simplifier.github.io/fp-game-alpha/learn.html)

A Haskell foundation for making your own game with AI. Give the AI a game brief,
invoke `$new-game`, and build a playable slice around a small pure core.
Haskell experience is optional; the AI should prepare the host and explain the
code when you want to understand it.

The long-term work is a pure functional game engine shaped by different real
games. This alpha shares usable tools, examples and research along the way.
Read [the purpose](docs/purpose.md) for that distinction.

## Start with your game

Clone this repository and open it in an AI environment that can read files,
edit code and run commands. Tell it what the player should experience and where
the game should run, then invoke [new-game](.agents/skills/new-game/SKILL.md).
If the environment does not recognize skill names, give it that file directly.

The [creation guide](docs/new-game.md) covers the brief, first playable slice
and continued development. References are examples to learn from; a new game
gets its own design. The [platform guide](docs/platforms.md) distinguishes
available source from checks completed on a real host.

An optional terminal starter is also available through the native `fp-game`
tool. Follow [setup and bootstrap](docs/native-tooling.md); generated games
carry their tool source and can continue outside this checkout.

## Understand and improve it

- [A delivery, read through code](https://m-simplifier.github.io/fp-game-alpha/learn.html): a Japanese beginner lesson using Station's actual types, decisions and state changes.
- [learn-code](docs/learn-code.md): ask the AI about one operation in your own current game.
- [Design boundaries](docs/architecture.md) and [readable Haskell](docs/haskell.md): choose responsibilities, representations and useful checks.
- [Technical practice](docs/practice/README.md): deeper guidance selected for the problem at hand.
- [Headless play](docs/headless-play.md): let an AI make real choices and inspect the consequences.
- [Editor support](docs/editors.md): optional compiler-backed source inspection; it is not required to start.

## Examples to explore

| Example | A useful question to investigate |
| --- | --- |
| [Station Dispatch](references/station/README.md) | How do a resource cost and a stale turn affect a delivery? |
| [Lantern](references/lantern/README.md) | What can a finite puzzle establish about every reachable state? |
| [Garden](references/garden/README.md) and [Tapline](references/tapline/README.md) | How do ordered input and time enter a pure transition? |
| [River Home](references/river/README.md) | How do daily rules, saves and a multi-day journey fit together? |
| [Paper Circuit](references/paper-circuit/README.md) | How can a new puzzle add an undo operation without inheriting another game's design? |
| [Signal Courier](references/signal-courier/README.md) | How do fixed ticks, checkpoints and platformer movement interact? |
| [Garden of Afterlight](references/afterlight/README.md) | How does a pure game connect to a 3D renderer and audio? |
| [Red Dune live](references/red-dune-live/README.md) | Who owns stock, work, delivery and durable saves in a continuing colony? |

These examples have different host and verification boundaries; each entry
links to its own run instructions. [Research reproduction](docs/research-reproduction.md)
covers optional formal-method experiments. The [archived Red Dune](references/red-dune/README.md)
and frozen comparison sources retain their original role as evidence.

## Contribute and verify

Use the checks for the boundary you change, plus the repository's required CI.
[Acceptance](docs/acceptance.md) states what a public path must establish;
[verification records](docs/verification.md) preserve the conditions of earlier
runs. Passing a finite test does not establish every game or host.

The implementation is the source of truth. Keep names, types and responsibilities
readable. Documentation should teach a useful idea, explain a design reason or
record an external constraint; avoid parallel catalogs of what the code already says.
The public Station lesson intentionally teaches from source excerpts, checked
against the implementation in CI.

Published files retain [provenance and license records](PUBLICATION-MANIFEST.md).
This repository uses the [MIT license](LICENSE) with selected upstream notices.
The license for a separately authored game is its author's decision.
