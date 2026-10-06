# Use saved-source tools from an editor

For the richer Haskell Design declaration reader and editor view, see
[Haskell Design setup](https://github.com/M-simplifier/fp-game-alpha/blob/main/docs/haskell-design.md). The wrappers below are a separate,
smaller compiler-command integration.

These optional small wrappers show real compiler results for the selected
**saved** Haskell file. Save changes before querying. They do not index unsaved
buffers or replace HLS.

Doctor and saved-source check use the project's `.build/tools/fp-game`
(`fp-game.exe` on Windows). Follow [native bootstrap](native-tooling.md) once
before using these commands. The wrappers use that exact project-local binary;
they never rebuild it on startup or fall back to a Python operational CLI.
A missing binary reports the bootstrap step.

Inspect and context use the separate `tools/inspect_haskell.py` specialist,
requiring Python 3.12+ and both GHC and GHCi on PATH. This is distinct from the
Cabal-selected compiler honored by native doctor/check. A native compiler
profile does not configure inspection; see [the compiler contract](tooling.md).

## VSCode

Open your game folder as a trusted VSCode workspace. The selected project and
file must belong to the same workspace folder after resolving links; trusting
an unrelated open folder does not authorize its commands. With the native binary
bootstrapped and the separate inspection prerequisites available when needed,
launch the supplied development extension from that folder:

```sh
code --extensionDevelopmentPath="./editors/vscode" .
```

The command palette exposes `FP Game: Doctor`, `Check Saved Haskell File`,
`Inspect Saved Module`, and `Type Context at Cursor`. Select a binding for
context. Compiler errors populate Problems; results appear in the FP Game output
channel. `fpGame.python` selects a Python executable only for inspect/context,
without shell evaluation; it does not affect native doctor/check. With a selected
file, the root is the nearest `fp-game.json`/`cabal.project`; doctor without an
active editor uses the open workspace root. The extension is supplied as source;
Marketplace publication is not claimed.

## Neovim

Neovim 0.10+ provides `vim.system`; the tested host version is recorded in
[verification](verification.md). In a game folder, load the local module:

```vim
:lua dofile(vim.fn.getcwd() .. '/editors/neovim/fp-game.lua').setup({ python = 'python' })
```

Open a saved `.hs` file, then use `:FPGDoctor`, `:FPGCheck`, `:FPGInspect` and
`:FPGContext advance`. Checks populate quickfix (`:copen`); other results open
a scratch split. The root comes from the nearest `fp-game.json`/`cabal.project`,
so there is no sibling starter checkout dependency. The module can be loaded
from your normal `init.lua`; no plugin manager is required. The `python` setting
applies only to inspect/context, not native doctor/check.

## HLS and guarantee boundaries

For live hover, completion, refactors and unsaved-buffer diagnostics, use HLS
and the official Haskell VSCode extension, or `:FPGHls` in Neovim after installing
a compatible `haskell-language-server-wrapper`. The Neovim command starts an
ordinary LSP client and uses this game's isolated `build.config`. Foundation
checkouts without that file can use their normal HLS setup instead.

HLS is tied to a GHC version; a wrapper being on PATH does not prove the selected
server can load this project. Consult the [official compatibility table](https://haskell-language-server.readthedocs.io/en/latest/support/ghc-version-support.html).
The [Neovim LSP documentation](https://neovim.io/doc/user/lsp/) describes its
client API. The [VSCode extension test guide](https://code.visualstudio.com/api/working-with-extensions/testing-extension)
describes a real extension host test. These are separate from plain CLI checks.

Compiler-column conversion in the small wrappers is approximate for tabs and
some Unicode text; HLS provides richer source positions. CLI diagnostics cover
the declared source directories, not arbitrary installed Cabal packages.

## Reproduce editor checks

From the foundation checkout, bootstrap the native binary, then run
`python tools/test_editors.py neovim` or `python tools/test_editors.py vscode`.
These commands create a temporary game through the actual native CLI, copy the
tested binary into its project-local tool path, and start the installed editor
with an isolated profile.
The harness uses `--binary PATH`, then `FP_GAME_BINARY`, then the checkout's
`.build/tools/fp-game` (`fp-game.exe` on Windows) for creation. It requires Python,
GHC/Cabal and the selected editor; missing prerequisites fail explicitly.
On Windows, pass `--windows-compiler` with the verified compiler path (or set
`FP_GAME_COMPILER`); the harness creates the game's explicit native profile.
This does not replace the inspector's separate PATH GHC/GHCi requirement.
`python tools/test_editors.py neovim --with-hls` additionally requires real LSP
initialization, type hover and compiler diagnostics. Logs stay in `.build/`;
the compact result states exactly what ran. No macOS editor pass follows from
Windows editor tests or macOS kernel CI. Historical editor records predate the
native-default routing and do not establish that these changed adapters passed
in an actual editor.

Lightweight routing and diagnostic contracts can be checked with
`node editors/vscode/test/adapter-contract.js` and
`lua editors/neovim/adapter-contract.lua` (or `texlua`). These use mocked process
adapters; they are not actual editor/compiler or live-HLS acceptance.

## Consistent Haskell formatting

Use the [pinned project-local formatter](formatting.md) for explicit setup,
non-writing checks, owned-source formatting and external HLS integration.
Run `python tools/formatter.py plan`, then `install` when permitted;
`check` never downloads and `write` never targets vendored source.
