# Current verification

Run checks after changing the code, dependency graph or toolchain. A build,
a finite test, graphical startup and human play are different observations.
The native baseline is GHC 9.14.1 / Cabal 3.18.2.0, Node 24.13.0 and Python
3.14.2. A project's compiler selection still governs its own build.

## Source and shared libraries

From the repository root:

```sh
python tools/publication.py check
python tools/docs_lint.py --foundation-only
python tools/formatter.py check
cabal --config-file=templates/terminal-adventure/build.config build all --offline --builddir=.build/dist
cabal --config-file=templates/terminal-adventure/build.config test all --offline --builddir=.build/dist --test-show-details=direct
python tools/test_lantern_api.py
python tools/test_river_api.py
python tools/test_station_api.py
python tools/test_play.py
python tools/quantity/check.py check
```

Linux also runs `references/afterlight/scripts/check-cpp-format.py` and
`test-cpp-format.py`. Expected compiler failures count only when the positive
client compiles and the diagnostic rejects the intended API operation.

## Check the consumer being changed

| Consumer | Commands and boundaries |
| --- | --- |
| Native developer CLI | [Bootstrap and independent generation/relocation](native-tooling.md); `cabal test all --project-dir=tools/haskell`; `tools/test_native_cli.py`, `tools/test_workspace.py`, rendered `tools/docs_lint.py`, formatter integration and editor adapter checks |
| Windows UTF8 process boundary | `python tools/test_windows_toolchain_paths.py`: fresh Unicode library/executable, unchanged caller console code pages, split UTF8 scalars and closed downstream output; the native integration also checks timeout and descendant cleanup |
| Haskell Design | In `editors/haskell-design`: `npm ci`, `npm run check`, `npm run build`, `npm test`; package, relocated inference, actual Lua and headless Neovim scripts are listed in its `package.json` |
| Afterlight | [Native assets, laws and hosts](../references/afterlight/README.md); [Web build, C ABI, host and asset/HTTP checks](../references/afterlight/web/README.md) |
| Red Dune | [Bounded suites and explicit campaign commands](../references/red-dune/docs/ACCEPTANCE.md), [native distribution](../references/red-dune/README.md) and [HTTP/protocol contract](../references/red-dune/docs/HOST-VERIFICATION.md) |
| Standalone games | [Paper Circuit](../references/paper-circuit/README.md) and [Signal Courier](../references/signal-courier/README.md): native laws/private APIs, actual Wasm execution in Node and host input tests |

The Web build uses the locked official SDK's GHC-Wasm 9.14.1.20260731 /
base 4.22.1 and matching Cabal 3.14.2, with Node 24. Its host/target unit
identities require that driver pair; native Cabal 3.18.2 is not substituted.

## Exercised scope

The current modernization checks cover Windows shared-library/API tests,
independent Unicode CLI generation and relocation, editor inference/packages,
native h-raylib 6.1 builds and bounded Red Dune/Afterlight GPU startup and resource
shutdown. Linux covers shared libraries and intended API rejections, independent
CLI generation/relocation, all 64 editor behavior checks, Red Dune's native
lifecycle, actual loopback HTTP and checked GHCi reload/recovery, and both
standalone games. The
locked Web SDK builds Afterlight and both standalone games; the latter execute
their actual Wasm through the browser shim in Node. Linux-scoped Node is 24.21.0.

Windows file-symlink and locked-directory test branches require their stated
host capability; skipped cases do not count as passes. OS watcher checks use
standard temporary storage; Linux watching of a Windows mount through WSL is
not qualified. macOS CI, installed
VS Code UI, actual browser input/rendering, human play/listening, long campaigns
and renewed performance measurements are not qualified by these checks.
Compiled game distribution still requires its actual runtime/dependency notices.
