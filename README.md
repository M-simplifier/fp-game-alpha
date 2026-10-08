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

## Haskell development tooling

The native `fp-game` executable is the authoritative path for `create-plan`,
`create`, `doctor`, `build`, `test`, `check` and `run`. Bootstrap it once, then
run the local binary directly. Generated games carry its source and can continue
after relocation without Python for these commands. See
[native setup and its evidence boundaries](docs/native-tooling.md).
Python is only needed for separate tools such as compiler inspection, formatting
and headless player journals. This tooling does not restrict `$new-game` to the
terminal starter or establish acceptance for every game and host.

## Optional terminal starter

This command path is one maintained example, not a restriction on `$new-game`.

With GHC 9.6.7 and Cabal 3.12.1.0 installed, follow
[the bootstrap guide](docs/native-tooling.md) once. From the clone on Linux/macOS:

```sh
.build/tools/fp-game doctor
.build/tools/fp-game create-plan my-game "../My Game"
.build/tools/fp-game create my-game "../My Game"
.build/tools/fp-game build --project "../My Game"
.build/tools/fp-game test --project "../My Game"
.build/tools/fp-game run --project "../My Game"
```

On Windows use `./.build/tools/fp-game.exe` and the guide's explicit compiler
profile, selecting the tool and game compilers separately. To continue from the
game directory without the clone, bootstrap its copied tool source once and use
its own local executable.

This optional starter is a native terminal adventure, with real rules,
view, validated saves and a Machine/Arena adapter. Add your actual mechanic
after generation; the starter is no longer required. Kernel versions/source
hashes are pinned locally. Standard Cabal works, and your game's license is
your decision. See [start and continue a game](docs/new-game.md).

The CLI keeps config/cache/output in `.build/`; this profile needs only packages
bundled with GHC. The separate `tools/inspect_haskell.py` owns `inspect` and
`context`, using Python plus GHC/GHCi on PATH. The editor wrappers use native
doctor/check and that inspection tool; saved-source results are compiler-backed.
See [setup](docs/setup.md), [editors](docs/editors.md),
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
for real type rejections and runtime-oracle checks; LiquidHaskell checking
is a separate, pinned opt-in route with its own evidence and limits.
Recovered [formal-method research](docs/research-reproduction.md) adds optional,
isolated checker routes for the real quantity modules, cancellation arithmetic,
and asynchronous save lifecycle. Start with the question and its stated limits;
install only the prover needed for that experiment.

The [complete Afterlight source](references/afterlight/README.md) is an optional
package with the original renderer/audio and browser hosts, a pinned dependency
check route, and a frozen gameplay oracle. Host execution and binary
redistribution are separate acceptance stages.

[Red Dune: A Settlement That Lasts](references/red-dune-live/README.md) is the
active colony campaign: physical production and delivery, three-shift staffing,
construction, recovery and durable checkpoints, with a local Haskell HTTP host
and browser command room. See [the live source/check route](docs/red-dune-live.md)
for Linux build/play instructions and separate short, long-campaign and browser
gates. Native host/protocol evidence does not establish real-browser acceptance;
keyboard, pointer, layout and a human playthrough remain unverified.

The [archived Red Dune colony simulation source](references/red-dune/README.md) is an
optional, in-progress Linux/GHC 9.6 reference with exact-restored compatibility
fixtures. Start with its [source reading and check route](docs/red-dune.md);
full game checks on the earlier core and bounded formatted-core checks are
reported separately. It is not a campaign release or a new-game template.

## Play through an AI-facing interface

[Headless gameplay](docs/headless-play.md) lets an AI make actual Station choices
through the Haskell Arena, inspect consequences, and produce a replayable player
journal. Use `$play-game` or `python tools/play.py --help`. The pilot evaluates
abstract decisions; it is not a human-fun guarantee or a renderer benchmark.

## Purpose-specific skills

- `$new-game`: brief and platform to a new game designed around the shared core
- `$fp-gamedev`: implement and refine this game’s rules and runtime boundaries
- [`$game-experience`](.agents/skills/game-experience/SKILL.md): design player experience and progression, or improve UI/help and Japanese copy from play feedback
- `$haskell-excellence`: types, errors, effects, resources, evaluation and verification
- `$game-platform`: host preparation, build, assets and distribution
- `$play-game`: actual player decisions through the current headless adapter
- `$learn-code`: understand your actual game's Haskell types and behavior, with no prior Haskell knowledge required

The [technical knowledge index](docs/practice/README.md) is the canonical guide;
these entries route to the relevant knowledge without making every task read it all.

The [experience design](docs/game-experience/design.md) and
[UI/Japanese guide](docs/game-experience/ui-and-japanese.md) preserve the reusable
judgments from the 7 October Red Dune study. Read the
[sources and evidence limits](docs/game-experience/sources.md) when evaluating a
claim; the positive owner trial does not establish long-term or universal appeal.

## A game authored from its own brief

[Paper Circuit](references/paper-circuit/README.md) is a new 2D browser puzzle
whose Haskell core and SVG presentation were written from scratch. Only the
small shared core is reused. Native and real-Wasm/Node checks pass; actual
browser UI acceptance remains unverified. This example is not a required
template for new games.

[Signal Courier](docs/signal-courier.md) adds an independent fixed-tick 2D
platformer: three lantern deliveries, checkpoints and optional rooftops. Native
and actual Wasm traces verify direct and all-stamp wins; browser/device
play remains unverified. Read the [DX report](references/signal-courier/docs/experiment.md)
for reused code, knowledge, tests and prevention lessons.

### Read types and design

[Learn from your game's code](docs/learn-code.md) with a chosen action, its real
types and a small prediction or optional change. The skill works with independent
games as well as the references; it does not require an editor installation.

[Haskell Design](docs/haskell-design.md) restores the original native map/outline/show
reader, optional trusted inference, and VSCode/Neovim adapter sources. Start with
the haskell-editor-setup skill; current-platform checks and remaining UI limits are explicit.
