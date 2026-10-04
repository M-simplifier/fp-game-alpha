# fp-game-alpha

[日本語の紹介ページ — 壊れないゲーム開発](https://m-simplifier.github.io/fp-game-alpha/)


A Haskell foundation for AI-driven, pure functional game development. Clone it,
invoke `$new-game`, and give the AI your game brief and platform requirements.
The intended workflow designs a new game around the small shared core, prepares
its host, implements a playable slice, and continues from play feedback.
References are learning material, not mandatory game templates.

The long-term aim is a pure functional game engine whose design and APIs are
refined through different real games. This alpha shares the useful parts now;
see [the research direction and what the alpha provides](docs/purpose.md).

See [the development workflow](docs/new-game.md). It separates the intended
experience from the platform checks already completed; the foundation is still
alpha and does not establish that every target or generated game is correct.

## Optional terminal starter

This command path is one maintained example, not a restriction on `$new-game`.

With Python 3.12+, GHC 9.6.7 and Cabal 3.12.1.0 on PATH:

```sh
python tools/fp_game.py doctor
python tools/fp_game.py plan my-game "../My Game"
python tools/fp_game.py scaffold my-game "../My Game"
cd "../My Game"
python tools/fp_game.py build
python tools/fp_game.py test
python tools/fp_game.py run
```

This optional starter is a native terminal adventure, with real rules,
view, validated saves and a Machine/Arena adapter. Add your actual mechanic
after generation; the starter is no longer required. Kernel versions/source
hashes are pinned locally. Standard Cabal works, and your game's license is
your decision. See [start and continue a game](docs/new-game.md).

The CLI keeps config/cache/output in `.build/`; this profile needs only packages
bundled with GHC. `inspect`, `context` and editor wrappers use actual compiler
results. See [setup](docs/setup.md), [editors](docs/editors.md),
[Haskell style](docs/haskell.md), [architecture and laws](docs/architecture.md),
[review findings and prevention](docs/failure-prevention.md),
[guarantees and limits](docs/guarantees.md),
[acceptance contract](docs/acceptance.md), [milestones](docs/roadmap.md), and
[publication manifest](PUBLICATION-MANIFEST.md).

This is an alpha. A finite test or historical verification result is scoped
evidence, not a proof that every game, host or platform works. The repository
retains the [MIT license](LICENSE) and all selected upstream notices.

The first additional reference is the [Lantern finite puzzle](references/lantern/README.md).
The [Tapline pure-core reference](references/tapline/README.md) exercises
ordered input, active time and six complete rounds through Step and Arena.
The [Garden pure-core reference](references/garden/README.md) connects
deterministic world updates to event and clock-frame adapters.
The [River Home pure-core reference](references/river/README.md) covers a
multi-day village journey, fixed ticks, validated saves and Step/Arena agreement.
The [Station Dispatch pure-core reference](references/station/README.md) covers
all six orders and three endings with an opaque turn token; JSON save and
asynchronous UI acceptance remain pending.
The [quantity source lab](research/quantity/README.md) has a GHC-only route
for real type rejections and runtime-oracle checks; its recorded
LiquidHaskell result is historical and remains separately scoped.

The [complete Afterlight source](references/afterlight/README.md) is an optional
package with the original renderer/audio and browser hosts, a pinned dependency
check route, and a frozen gameplay oracle. Host execution and binary
redistribution are separate acceptance stages.

## Play through an AI-facing interface

[Headless gameplay](docs/headless-play.md) lets an AI make actual Station choices
through the Haskell Arena, inspect consequences, and produce a replayable player
journal. Use `$play-game` or `python tools/play.py --help`. The pilot evaluates
abstract decisions; it is not a human-fun guarantee or a renderer benchmark.

## Purpose-specific skills

- `$new-game`: brief and platform to a new game designed around the shared core
- `$fp-gamedev`: implement and refine this game’s rules and runtime boundaries
- `$haskell-excellence`: types, errors, effects, resources, evaluation and verification
- `$game-platform`: host preparation, build, assets and distribution
- `$play-game`: actual player decisions through the current headless adapter

The [technical knowledge index](docs/practice/README.md) is the canonical guide;
these entries route to the relevant knowledge without making every task read it all.

## A game authored from its own brief

[Paper Circuit](references/paper-circuit/README.md) is a new 2D browser puzzle
whose Haskell core and SVG presentation were written from scratch. Only the
small shared core is reused. Native and real-Wasm/Node checks pass; actual
browser UI acceptance remains unverified. This example is not a required
template for new games.

### Read types and design

[Haskell Design](docs/haskell-design.md) restores the original native map/outline/show
reader, optional trusted inference, and VSCode/Neovim adapter sources. Start with
the haskell-editor-setup skill; current-platform checks and remaining UI limits are explicit.
