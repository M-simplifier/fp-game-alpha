# Compiler and editor contract

The [native Haskell CLI](native-tooling.md) owns `create-plan`, `create`,
`doctor`, `build`, `test`, `check` and `run`. Bootstrap once, then run
`.build/tools/fp-game` (`./.build/tools/fp-game.exe` on Windows). The installed
binary, creation-source foundation and selected game are separate roots;
`--project` defaults to caller cwd. The native guide is the setup and process
contract, including Windows's separate tool/game compiler selections.

```sh
.build/tools/fp-game doctor --json
.build/tools/fp-game check libraries/game-arena/src/Game/Arena.hs --json
```

Native `check FILE` runs the project's Cabal-selected GHC with `-fno-code`,
warnings and forced recompilation. Without a file, `check` builds the project.
Doctor and checks resolve the compiler through Cabal and fail if selection fails;
they do not fall back to an ambient compiler on PATH.

## Separate saved-source inspection

`tools/inspect_haskell.py` is a Python-standard-library specialist for only
`inspect` and `context`. It requires Python 3.12+ and both `ghc` and `ghci` on
PATH. Unlike native doctor/check, it does not query Cabal for the selected
compiler. Check that this separate PATH profile is appropriate for the source;
a working native compiler profile does not establish inspection readiness.
The pinned Windows unversioned compiler aliases have a known Japanese-path
argument limitation; the native explicit profile does not repair a separate
PATH-based GHC/GHCi invocation. Qualify that inspection profile independently.
The remaining migration is to share native compiler/component selection with
inspection while preserving its real GHCi module/type contract; it is not yet
implemented, and there is no silent native/Python fallback.

```sh
python tools/inspect_haskell.py inspect libraries/game-arena/src/Game/Arena.hs --json
python tools/inspect_haskell.py context libraries/game-arena/src/Game/Arena.hs --symbol play --json
```

`inspect FILE` runs GHCi's module browse; `--symbol NAME` adds compiler-backed
`:info` and `:type`. `context FILE --symbol NAME` provides that type/declaration
information and the file's imports. A missing symbol or invalid source fails
even when GHCi itself exits zero. Inspection output belongs to `.build/`
temporary directories. Commands use argument arrays and capture exit codes and
output without shell expansion.

The saved-source profile covers `.hs` files and explicitly declared local
source directories, with packages shipped with GHC. It does not reconstruct
every arbitrary Cabal component, language pragma or external dependency.
Compiler work can evaluate Template Haskell: use the same workspace trust
decision as a normal build. These tools do not inspect unsaved buffers.

## Independent readers and editors

HLS provides live diagnostics, type/documentation hovers, symbols, references
and code actions. Keep it for live editor language intelligence; the saved-source
tools provide reproducible command results that humans, agents and editors can
use. The feature relationship is grounded in the
[official HLS feature list](https://haskell-language-server.readthedocs.io/en/latest/features.html).
An HLS executable on PATH does not prove a live session is connected.

The [Haskell Design reader](https://github.com/M-simplifier/fp-game-alpha/blob/7682f7c620fbc03c288a501d5a9c116bbba7d999/docs/haskell-design.md) independently provides
`map`/`outline`/`show` and optional trusted inference. It retains its own setup,
compiler constraints and editor adapters. Formatter provisioning, headless
player journals and formal-method research tools are also separate; none is a
fallback implementation of the native operational commands.

The small VSCode and Neovim wrappers route doctor/check to the native binary
and inspect/context to the Python specialist. See [editor setup](editors.md).
The [VSCode command API](https://code.visualstudio.com/api/extension-guides/command)
also allows an extension to query a provider such as HLS. A missing executable
must fail visibly rather than substitute another backend or an empty result.
See the scoped platform/editor records in [historical verification](https://github.com/M-simplifier/fp-game-alpha/blob/7682f7c620fbc03c288a501d5a9c116bbba7d999/docs/verification.md).
