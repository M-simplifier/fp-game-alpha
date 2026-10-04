# Public alpha port

Source: [garden-of-afterlight 6367b56e](https://github.com/M-simplifier/garden-of-afterlight/tree/6367b56e3ff2042199667f2a5bfa50695f4aaf2f/editors/haskell-design). Original MIT license and third-party notices are retained.

Adaptations:
- Non-Windows C builds use the feature-test macros from pinned Tree-sitter 0.25.10 upstream Makefile, so strict C11 exposes POSIX and endian declarations.
- Linux optional GHC inference helpers link dynamically to the selected GHC 9.6.x installation. Both helper cache keys include the link mode. This helper already requires that compiler at runtime; shared GHC libraries must remain available. Missing libraries produce unavailable inference, never a verified result. The standalone syntax reader remains separate.
- Include unix 2.8.6.0 notice for the Linux compiler package closure; sources.json records the fetched license SHA256 (the URL is the license itself).
- Package smoke tests select Game.Transition.replay instead of an Afterlight-only function.

Current verification, 2026-10-04: Linux x64 GHC 9.6.7, Cabal 3.16.1.0, Node 24.19.0. Native build, TypeScript check, and all 58 npm tests passed. Tests exercise actual native parsing, explicit trusted inference, cache invalidation, relocated Unicode sources, and no-compiler-PATH syntax reading. Paper Circuit map/show also passed. These are not live editor UI tests. macOS and current Windows builds/editor hosts have not been rerun for this port; upstream historical evidence is not new alpha evidence.

The initial static GHC API helper link exceeded a bounded 45-second experiment; the dynamic helper built and executed successfully, and the full test suite then passed. This is evidence for the chosen Linux build improvement, not a universal performance benchmark or diagnosis of every prior stall.

Linux VSIX and Neovim archives were built successfully. The extracted packages both passed relocated-game syntax reads, no-Node/no-GHC-PATH syntax, the foundation-source selection, and explicit trusted inference. The aggregate package command then stopped because Neovim is not installed; its real editor consumer check is not run and the aggregate command is not a pass. No generated binary/archive is committed.
