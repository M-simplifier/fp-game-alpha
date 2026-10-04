# Compiler and editor contract

`tools/fp_game.py` is a Python-standard-library CLI, independent of an editor.
It starts tools with argument arrays and captures their exit codes and output;
there is no shell expansion. UTF-8 input/output, paths with spaces, Windows
line endings and missing tools are part of its acceptance scope.

```sh
python tools/fp_game.py doctor --json
python tools/fp_game.py check libraries/game-arena/src/Game/Arena.hs --json
python tools/fp_game.py inspect libraries/game-arena/src/Game/Arena.hs --json
python tools/fp_game.py context libraries/game-arena/src/Game/Arena.hs --symbol play --json
```

`check FILE` runs GHC with `-fno-code`, warnings and forced recompilation.
`inspect FILE` runs GHCi's module browse; `--symbol NAME` adds compiler-backed
`:info` and `:type`. `context FILE --symbol NAME` provides that type/declaration
information and the file's imports. A missing symbol or invalid source fails
even when GHCi itself exits zero. Without a file, `check` builds the project.
Inspection outputs belong to `.build/` temporary directories.

The initial profile covers saved `.hs` files and explicitly declared local
source directories, with packages shipped with GHC. It does not reconstruct
every arbitrary Cabal component, language pragma or external dependency.
Compiler checking can evaluate Template Haskell: use the same workspace trust
decision as a normal build.

HLS already provides diagnostics, type/documentation hovers, symbols,
references and code actions. Keep HLS for live editor language intelligence;
this CLI adds reproducible saved-source context and game scaffolding that an
LLM or either editor can call. The feature relationship is grounded in the
[official HLS feature list](https://haskell-language-server.readthedocs.io/en/latest/features.html).
An HLS executable on PATH does not prove a live session is connected.

VSCode and Neovim wrappers use the same argument/result contract. See the
[editor setup](editors.md). The
[VSCode command API](https://code.visualstudio.com/api/extension-guides/command)
also allows an extension to query a provider such as HLS; the initial CLI path
does not substitute an empty result for a compiler query. See the explicit
platform/editor status in [verification](verification.md).
