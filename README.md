# fp-game-alpha

A small, auditable Haskell foundation for pure functional games. The public
alpha starts with real transition and arena libraries. Game rules own their
state and effects; hosts own IO, clocks, rendering and persistence.

With GHC 9.6.7 and Cabal 3.12.1.0 on PATH:

```sh
cabal build all --offline
cabal test all --offline --test-show-details=direct
```

The initial kernel needs only `base`, shipped with GHC. Later alpha milestones
add playable references, scaffolding and editor-independent inspection.
See the [architecture and laws](docs/architecture.md),
[acceptance contract](docs/acceptance.md), [milestones](docs/roadmap.md), and
[publication manifest](PUBLICATION-MANIFEST.md).

This is an alpha. A finite test or historical verification result is scoped
evidence, not a proof that every game, host or platform works. The repository
retains the [MIT license](LICENSE) and all selected upstream notices.
