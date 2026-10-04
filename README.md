# fp-game-alpha

A small, auditable Haskell foundation for pure functional games. The public
alpha starts with real transition and arena libraries. Game rules own their
state and effects; hosts own IO, clocks, rendering and persistence.

With Python 3.12+, GHC 9.6.7 and Cabal 3.12.1.0 on PATH:

```sh
python tools/fp_game.py doctor
python tools/fp_game.py build
python tools/fp_game.py test
```

The CLI keeps Cabal configuration, cache and outputs inside `.build/`, so an
empty Cabal cache can build without downloading a package index. The initial
kernel needs only `base`, shipped with GHC. `inspect` and `context` provide
actual saved-source GHC/GHCi output. Later milestones add playable references
and scaffolding.
See the [architecture and laws](docs/architecture.md),
[acceptance contract](docs/acceptance.md), [milestones](docs/roadmap.md), and
[publication manifest](PUBLICATION-MANIFEST.md).

This is an alpha. A finite test or historical verification result is scoped
evidence, not a proof that every game, host or platform works. The repository
retains the [MIT license](LICENSE) and all selected upstream notices.
