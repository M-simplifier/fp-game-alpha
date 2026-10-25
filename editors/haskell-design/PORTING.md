# Public alpha port

Source: [garden-of-afterlight 6367b56e](https://github.com/M-simplifier/garden-of-afterlight/tree/6367b56e3ff2042199667f2a5bfa50695f4aaf2f/editors/haskell-design). Original MIT license and third-party notices are retained.

The current native profile uses GHC 9.14.1 and Cabal 3.18.2. Its Cabal syntax
reader uses the package's symbolic-path API; compiler helpers target GHC 9.14.
Versioned notices describe the actual dependency closure in `native/licenses`.

- Non-Windows C builds use the feature-test macros from pinned Tree-sitter 0.25.10's upstream Makefile, so strict C11 exposes POSIX and endian declarations.
- Linux optional inference helpers link dynamically to the selected GHC installation. Both helper cache keys include link mode. Shared GHC libraries must remain available; missing libraries produce unavailable inference. Syntax reading remains independent of GHC at runtime.
- Package smoke tests select `Game.Transition.replay` from the current foundation.
- Editor batches share a content/compiler-keyed helper cache with manual verification. Failed builds can recover; changed helper source is reselected without restarting the editor.
- Source discovery retains a component's implicit root when `hs-source-dirs` or a common-stanza import appears only in a conditional branch.

Use the [current verification guide](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/verification.md) and the package
scripts for build, inference, relocation and editor checks. A successful package
or headless editor check does not establish interactive editor behavior.
