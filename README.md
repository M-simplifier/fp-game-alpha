# fp-game-alpha

A Haskell foundation for starting and continuing your own pure functional
game. Clone it, invoke `$new-game` in Codex, and develop an independent game
outside this checkout. The game owns editable source, tests, assets, config,
versioned docs, saves and a local `$game-dev` skill.

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

The first maintained route is a native terminal adventure, with real rules,
view, validated saves and a Machine/Arena adapter. Add your actual mechanic
after generation; the starter is no longer required. Kernel versions/source
hashes are pinned locally. Standard Cabal works, and your game's license is
your decision. See [start and continue a game](docs/new-game.md).

The CLI keeps config/cache/output in `.build/`; this profile needs only packages
bundled with GHC. `inspect`, `context` and editor wrappers use actual compiler
results. See [setup](docs/setup.md), [editors](docs/editors.md),
[Haskell style](docs/haskell.md), [architecture and laws](docs/architecture.md),
[acceptance contract](docs/acceptance.md), [milestones](docs/roadmap.md), and
[publication manifest](PUBLICATION-MANIFEST.md).

This is an alpha. A finite test or historical verification result is scoped
evidence, not a proof that every game, host or platform works. The repository
retains the [MIT license](LICENSE) and all selected upstream notices.
