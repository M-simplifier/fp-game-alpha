# Formatting without a global install

Ormolu makes indentation and layout consistent so a beginner can concentrate
on the game's vocabulary and rules. It does not replace clear names, small
functions, comments about intent, or gameplay tests.

## One project-local route

Run these from your game directory (Python 3.12+):

```sh
python tools/formatter.py plan
python tools/formatter.py install
python tools/formatter.py check
python tools/formatter.py write
python tools/formatter.py path
```

- `plan` lists the exact version, official URL, size, SHA-256, local executable
  destination and selected sources. It neither downloads nor changes files
- `install` explicitly downloads the pinned archive into `.build/tools/ormolu/`.
  It verifies the archive hash, permits only its single regular executable,
  checks the executable's version, and reuses an already verified local cache
- `check` verifies the cache and reports formatting differences without changing
  source. Missing or damaged tools fail with guidance; it never downloads
- `write` changes only the owned `.hs` files selected in `formatter.json`.
  Review the diff and run your game tests afterward
- `path` prints the verified absolute executable path for editor integration

The lock is `tools/formatter.lock.json`, currently Ormolu 0.9.0.0 from the
[official release](https://github.com/tweag/ormolu/releases/tag/0.9.0.0).
No binary is committed, no global PATH or user profile is changed, and no
compiler or HLS is installed by this route. Downloads need network access.
Keep `.build/` ignored by Git. A partial or damaged cache is not silently
replaced: inspect it, remove only this project's affected Ormolu cache folder,
then explicitly install again.

The CLI retains Ormolu's AST safety check and requests its idempotence check.
It never passes `--unsafe`. GHC2021 is supplied; Cabal's default extensions and
dependencies are also read by Ormolu where a `.cabal` file is available. Use
source LANGUAGE pragmas and a reviewed project `.ormolu` for other extensions
or fixity declarations. Unsupported syntax or CPP may require a separate
reviewed route; a successful format is not a successful build.

## Any independently authored game

The helper does not require the terminal template, shared kernels, or a game
framework. For a fresh game written from its brief, copy `tools/formatter.py`
and `tools/formatter.lock.json` into that game, add a `formatter.json` like:

```json
{
  "schema": 1,
  "source_roots": ["app", "src", "test"]
}
```

Choose only directories containing this game's editable Haskell. The source
roots are explicit, not a recursive whole-repository sweep. Vendor, oracle,
fixture and build/cache directories are rejected as roots and excluded inside
roots. Symlinks, Windows junctions, hard-linked Haskell files and paths escaping the
project are refused. Missing roots and an
empty source selection fail instead of reporting a meaningless pass.

The optional terminal scaffold already copies the helper, lock, owned-source
config, this guide and CI steps into the new directory. Its local `$game-dev`
skill continues there without the starter checkout. The foundation config covers 94 live Haskell sources across the template, core
libraries, current reference games and native reader. Frozen oracle/vendor/fixture
inputs remain excluded. Six CPP-containing Afterlight declarations are explicitly
kept verbatim with formatter control comments; the surrounding modules are formatted.
Their native and Wasm preprocessed forms were compared with public pre-format commit `2487f7b`.
This is not a claim that every historical source or every CPP region is reformatted.

## Editor integration: propose, preserve, verify

[HLS configuration](https://haskell-language-server.readthedocs.io/en/latest/configuration.html)
provides `haskell.formattingProvider: "ormolu"` and
`haskell.plugin.ormolu.config.external: true`. Selecting Ormolu alone can use
the version bundled in HLS, which need not match this lock.

After `install` and `path`, put the returned executable's parent directory on
**the HLS process's PATH**. For VS Code, merge these workspace settings into
`.vscode/settings.json`, preserving all existing values:

```json
{
  "haskell.formattingProvider": "ormolu",
  "haskell.plugin.ormolu.config.external": true,
  "[haskell]": { "editor.defaultFormatter": "haskell.haskell" }
}
```

Merge that local directory into `haskell.serverEnvironment.PATH` along with
the existing compiler, Cabal and system PATH entries. Use the host separator
(`;` on Windows, `:` elsewhere). Do not commit machine-specific absolute
paths. Alternatively launch the editor from a terminal with a process-local
PATH prepend. Restart HLS and format an owned source, then run CLI `check`
to establish agreement. For Neovim, give its HLS process the same environment
and use the equivalent nested LSP `haskell.plugin.ormolu.config.external`
setting. Keep normal workspace trust prompts; do not weaken them.

These are integration instructions, not a claim that your editor is already
configured. The existing editor-setup helper emits proposals and preserves
existing files; review/merge the formatter additions rather than overwriting
those settings. Automatic format-on-save is optional and should be a deliberate
workspace choice.

## Verification boundary

Linux x86_64 installation, verified cache reuse, actual template formatting and
an independent generated game's check/write/check route were tested locally.
Pinned assets also exist for Windows x86_64 and macOS x86_64/arm64. CI contains
three-OS install/check coverage, including a generated-game regression; adding
those jobs does not establish that they have run. Other platforms fail clearly in this helper. The agent can still research an
official platform build, agree any required installation permissions, verify
it, and only then add a pinned repeatable route. Do not treat tool coverage as
the limit of an authorized game brief.
Actual HLS formatting and Windows/macOS runtime acceptance still need testing.
Compiler/HLS provisioning, Linux ABI prerequisites and a universal environment
installer are outside this formatter slice.
