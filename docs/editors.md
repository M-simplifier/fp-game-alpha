# Use saved-source tools from an editor

The CLI is the stable editor-independent boundary. These optional small wrappers
show real compiler results for the selected **saved** Haskell file. Save changes
before querying. They do not index unsaved buffers or replace HLS.

## VSCode

Open your game folder in VSCode. With Python, GHC and Cabal on PATH, launch the
supplied development extension from that folder:

```sh
code --extensionDevelopmentPath="./editors/vscode" .
```

The command palette exposes `FP Game: Doctor`, `Check Saved Haskell File`,
`Inspect Saved Module`, and `Type Context at Cursor`. Select a binding for
context. Compiler errors populate Problems; results appear in the FP Game output
channel. `fpGame.python` selects a Python executable without shell evaluation.
The extension is supplied as source; Marketplace publication is not claimed.

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
from your normal `init.lua`; no plugin manager is required.

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

From the foundation checkout, `python tools/test_editors.py neovim` and
`python tools/test_editors.py vscode` start the installed editors using a new
temporary game and isolated profile. Missing editors fail explicitly.
`python tools/test_editors.py neovim --with-hls` additionally requires real LSP
initialization, type hover and compiler diagnostics. Logs stay in `.build/`;
the compact result states exactly what ran. No macOS editor pass follows from
Windows editor tests or macOS kernel CI.
