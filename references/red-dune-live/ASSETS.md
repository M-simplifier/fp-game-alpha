# Assets and redistribution

This source package is covered by the accompanying [MIT license](LICENSE), with
its inherited source identified in [provenance](PROVENANCE.md). It contains no
third-party artwork, audio recordings, fonts, textures or prebuilt executables.

- `ui/index.html` and `ui/app.js`: authored interface and procedural SVG map,
  roads, sites, vehicles and selection outlines. Parts continue the separately
  preserved Red Dune interface under its retained MIT notice
- `ui/style.css`: authored CSS colors, shapes, layout and accessibility controls
- `ui/protocol.js`: authored transport/state-ordering helpers, not visual assets
- `native/RedDune/Native/View.hs`: authored procedural native map, buildings,
  workers, carts and interface. Geometry and activity come from the game state
- The Windows app reads an installed Japanese system font into memory. No font
  file is copied into its package or modified on disk
- Font names in CSS are local/system fallback requests. No font files or remote
  font URLs are shipped, fetched or sublicensed by this package
- `data/*.json`: authored economic and campaign data, not asset-store content
- `src/Colony/*Fixture.hs`: procedural Haskell test/scenario constructors, not
  imported binary save fixtures. Their names do not exempt them from formatting
- Documentation and tests: authored source and bounded recorded evidence only

The optional official Hackage `network` and `hsc2hs` dependencies are resolved by
Cabal; their downloaded sources and binaries are not copied into this repository.
The local native build collects resolved Haskell package and vendored raylib
notices in `THIRD-PARTY-NOTICES.txt`. Wider binary redistribution still needs a
review of the actual compiler/runtime and platform license requirements.

Keep `.build/`, `dist-newstyle/`, dependency downloads, `.red-dune-saves/`, `.rdg`
and `.save` files, raw profiler dumps and binary acceptance fixtures out of the source
selection. The older archive's existing preservation fixtures stay there only;
the live continuation does not redistribute another copy of those payloads.
