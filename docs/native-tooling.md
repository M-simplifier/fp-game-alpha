# Native Haskell development tools

The native `fp-game` executable is the authoritative path for `create-plan`,
`create`, `doctor`, `build`, `test`, saved-source `check` and `run`. It is a
separate source package: its JSON/hash dependencies never enter the small game
core or the generated game's offline dependency graph. There is no parallel
Python implementation of these operational commands.

Compiler inspection remains a separate `tools/inspect_haskell.py` specialist.
Formatter, player-journal, prover and Haskell Design tools retain their own
responsibilities and prerequisites. Choosing the native CLI as the default does
not broaden its experimental evidence or make every tool Python-free. Clone,
invoke `$new-game`, and give the AI an arbitrary brief and requested platform;
the terminal starter below is optional learning material, not the primary UX.

## Start without hiding setup cost

GHC and Cabal are already required to compile a game. Compiling this tool also
requires its pinned external dependencies once. There are no published native
binary releases in this route. Installing GHC/Cabal is a separate, explicit
step using the [official GHCup guide](https://www.haskell.org/ghcup/install/).
The verified baseline is GHC 9.6.7 / Cabal 3.12.1.0. Source compilation requires
GHC 9.6 or newer APIs; other compiler versions and dependency resolutions remain
unverified. The resulting binary uses Cabal's project-selected game compiler
and the Cabal executable on PATH. It does not silently change the game compiler
or inherit a GHC-API helper's version lock.

Before a compiler is installed, a Haskell source executable cannot diagnose it.
These tiny shell/PowerShell checks can; they do not install anything:

```sh
# Linux/macOS
sh tools/bootstrap-fp-game.sh --check
```

```powershell
# Windows PowerShell
./tools/bootstrap-fp-game.ps1 -Check
```

Build once, with explicit permission to acquire the pinned dependencies:

```sh
# Linux/macOS, from the foundation or generated game
sh tools/bootstrap-fp-game.sh --download
.build/tools/fp-game doctor --json
```

On Windows, use the [explicit compiler profile](#windows-explicitly-select-the-installed-compiler)
below before bootstrapping and operating on a game with Japanese paths.

With a populated dependency index/store, omit `--download` / `-Download` for an
offline build. The source is under `tools/haskell`, build objects under
`.build/native-tool`, and the copied executable under `.build/tools`. A custom
Cabal configuration may be selected explicitly with `CABAL_CONFIG`. Bootstrap
uses the selected dependency cache and does not rewrite an existing global
configuration. A first Cabal invocation can initialize its ordinary default
configuration if none exists.
It makes no shell-profile changes and does not install to a global bin folder.
Normal CLI commands run that executable directly, without rebuilding it.
Re-run bootstrap explicitly after changing tool source. Windows can refuse an
update while the old executable is running; close that process and retry.

The tool's package/index acquisition and compiler selection are distinct from
later game builds. Game build/test use project-local configuration, store and
output with repositories disabled. They require only GHC-bundled packages for
this baseline profile.
Do not describe an already-warm dependency cache as a clean-machine setup test.

## Windows: explicitly select the installed compiler

The verified Windows profile explicitly selects an installed compiler to
avoid a known launcher boundary. It never automatically replaces a compiler. In the pinned GHC 9.6.7 installation, the
unversioned C launcher aliases corrupted Japanese arguments. The same
installation's `ghc-9.6.7.exe` passed the bounded actual library and executable
Japanese-path builds in the [Windows compiler-path probe](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37295633672/job/111716047359#step:5:1).
The declared profile subsequently passed the complete native CLI/game-development
suite on [Windows](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37309094405/job/111761295675) at `be1208af`, alongside Linux and macOS. It remains an
experimental, pinned-toolchain route. This does not establish that every Windows
installation, wrapper or compiler version has the same behavior.

Choose an executable that actually exists on this machine and probe it. The
following path is an example, not a discovered installation location:

```powershell
# From the foundation or generated game root; use your actual installed path.
$compiler = 'C:/ghcup/ghc/9.6.7/bin/ghc-9.6.7.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'Choose an installed compiler.' }
& $compiler --numeric-version
if ($LASTEXITCODE -ne 0) { throw 'The selected compiler probe failed.' }
./tools/bootstrap-fp-game.ps1 -Check -CompilerPath $compiler
./tools/bootstrap-fp-game.ps1 -Download -CompilerPath $compiler
```

Inspect the reported version and path before proceeding. `-CompilerPath` probes
and reports the selected executable and passes the same selection to both
`cabal build` and `cabal list-bin`. Omit `-Download` when the pinned dependency
cache is ready. Bootstrap does not edit PATH, switch the installed GHC version,
rewrite aliases or add a game compiler profile. Without this option it retains
its ordinary selection; it never silently bypasses an alias.

Bootstrap builds the **separate** `tools/haskell` source package. Passing
`-CompilerPath` selects the compiler for that tool build only. A game, including
the foundation root project, needs its own Cabal compiler selection. Inspect
its existing `cabal.project`, `cabal.project.local`, compiler wrappers and local
settings first. Preserve deliberate choices; do not replace a custom profile
merely because the baseline example uses a different executable.

For a project with no local profile, create `cabal.project.local` in that game
root with a raw, forward-slash absolute path:

```cabal
with-compiler: C:/ghcup/ghc/9.6.7/bin/ghc-9.6.7.exe
```

`with-compiler` consumes the whole field as a path, including spaces. Do not
add JSON or shell quote characters: Cabal 3.12.1.0 treats those as literal parts
of the executable name. The chosen path must not contain a newline.

This PowerShell example writes that one setting as UTF-8 and refuses an existing
file. Run it from the intended game root with `$compiler` set and probed above.
If the file already exists, inspect and deliberately edit it while preserving
its other settings instead of deleting or overwriting it:

```powershell
$localProfile = Join-Path (Get-Location).Path 'cabal.project.local'
$stream = [IO.File]::Open($localProfile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $line = 'with-compiler: ' + $compiler.Replace('\', '/') + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($line)
    $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
./.build/tools/fp-game.exe doctor --json
./.build/tools/fp-game.exe build --json
./.build/tools/fp-game.exe test --json
```

This compiler-only profile is machine-local, ignored by Git and nonportable.
It is never copied into generated source. When relocating a game, leave it
behind and deliberately recreate the selection after inspecting the new
machine's compiler and the destination's existing settings. The copied native
tool source and game source remain independent of this absolute host path.

## Project compiler diagnostics and saved-source checks

Native `doctor` and `check FILE` ask `cabal path` for the project's selected
compiler using the same guarded `.build` state and offline configuration as
native builds. Cabal parses the project configuration; the CLI does not guess
from an ambient `ghc`, rewrite compiler wrappers or override a custom compiler.
A failed, timed-out or invalid compiler query is an error, with no fallback to
another compiler on PATH. Doctor reports the selected compiler's path and
version; saved-source checks invoke that selected executable.

Doctor is not entirely filesystem-read-only: when Cabal is present, it creates a
scoped temporary configuration and cache under guarded `.build` and removes that
query state afterward. Existing build state is preserved. A valid project-selected
compiler does not require an ambient `ghc` alias. The query has a fixed 20-second
timeout and does not build the game. The shipped local project profile queries without downloads or repository
access. Cabal's `--offline` and disabled package repositories are not a network
sandbox: a custom project with remote imports can have Cabal's own import side
effects. Inspect and trust that project configuration before querying it. Missing
Cabal on PATH is reported without creating project state. `ready-to-try`
still means detection and selection succeeded, not that a build or test passed.

## Commands and independent roots

`--project DIR` is relative to caller cwd, and defaults to caller cwd. It selects
the game for build/test/check/run, or the **foundation source** for creation.
It never defaults to the installed executable's directory. The creation
destination is a different argument and can be a chosen folder outside the clone.

```sh
.build/tools/fp-game create-plan my-game "../My Game 日本語" --project . --json
.build/tools/fp-game create my-game "../My Game 日本語" --project . --json
.build/tools/fp-game build --project "../My Game 日本語" --json
.build/tools/fp-game test --project "../My Game 日本語" --json
.build/tools/fp-game check src/Game/Rules.hs --project "../My Game 日本語" --json
.build/tools/fp-game run --smoke --project "../My Game 日本語" --json
.build/tools/fp-game run --project "../My Game 日本語"
```

On Windows use `./.build/tools/fp-game.exe` in place of the executable path above.
Use `create-plan` to inspect the typed plan, or `create --dry-run` to return it
without reserving a destination. An existing directory is
always refused, even if empty. Never regenerate over a user's changed game.
Source links, path escapes and linked mutable output are checked explicitly;
these checks are not a sandbox for adversarial filesystem races.

Creation is still the **optional native terminal example**. It is useful only
when the requested brief fits that host. For a browser, graphical native,
server or mobile brief, `$new-game` must author the game's domain and requested
host, prepare its actual toolchain, implement a playable slice and continue from
play feedback. Neither this command's flags nor a planned platform record are
a ceiling on the AI's work. Do not substitute a terminal template for the brief.

Generated workspaces carry native tool source, dependency pins, both bootstrap
scripts, core hashes/notices and local continuation guidance. After copying a
game without `.build`, bootstrap its copied source once and use its local native
executable. Machine-local `cabal.project.local` selections are excluded;
inspect and recreate them deliberately for the destination machine as described
[above](#windows-explicitly-select-the-installed-compiler). The original
foundation is not a build dependency. Tool dependency
acquisition may still need the network on a machine without the pinned cache.
The ordinary `build.config` Cabal route remains independent of the tooling too.

## Machine-readable and process contract

- Executed build/test/check/smoke results keep `command`, `exit_code`, `stdout`
  and `stderr`; `command` is an argument array, never a shell string
- `--json` prints one JSON value to stdout; child output is captured inside it
- Captured child streams decode as UTF-8 with replacement for malformed bytes,
  then normalize CRLF and lone CR to LF, matching Python's universal-newline
  text mode. This is a text API, not an arbitrary-binary-output transport;
  interactive inherited input/output is left untouched
- Validation failures add `status: "error"` and a stable `error_code`; the process
  and JSON exit code are both 1. Invalid command syntax exits 2
- Doctor identifies `implementation: "haskell"` rather than a Python runtime;
  `ready-to-try` detects tools and the project compiler selection; it does not
  establish a successful game build
- `check` without a file builds the project. File checks use the existing saved
  `.hs`/declared-source profile with Cabal's selected compiler, not an arbitrary
  Cabal component reconstruction
- Captured commands default to 180 seconds; `--timeout SECONDS` accepts 1–86400
- Interactive `run` inherits terminal input/output. On POSIX it replaces the
  CLI process with Cabal, leaving ordinary job control with the shell. A tool-level
  `--timeout` requires captured `run --smoke`; interactive JSON is also refused
- Compiler work can execute Template Haskell. Use normal workspace trust rules

The verified POSIX captured-command timeout/SIGINT/SIGTERM paths clean up the
managed child process group. SIGKILL, a process crash and power loss cannot run that in-process
cleanup and are not covered by those observations.

The executable and [package source](../tools/haskell/README.md) must remain
separate from compiler-API editor helpers. This CLI does not acquire their GHC
API version coupling or claim to inspect an unsaved editor buffer.

## Command ownership and continuation

- The native binary owns project selection, configuration validation, typed
  creation plans, destination ownership, build/check execution and result rendering
- Captured POSIX child signals use shell-style `128 + signal`; interactive
  execution follows Cabal's and the shell's lifetime/status behavior
- Title/author substitution is single-pass. Literal placeholder-looking text
  supplied by a user remains literal
- Source/destination validation rejects unsafe internal paths, linked selected
  source, linked mutable output, unsupported device names and unsafe executable
  target strings such as `--help`. Top-level roots still resolve normal relative
  paths such as `../My Game` from caller cwd. Existing destinations are never reused
- Generated source carries the native CLI, bootstrap, pinned dependencies,
  continuation documentation and workflow. Copying a workspace excludes local
  build state and compiler profiles, not the source needed to continue it

Creation never authorizes overwriting an existing game or substituting a terminal
starter for another requested platform. Add mechanics to the user's current
source and tests; do not regenerate the workspace to continue development.

## Separate specialist tools and host adapters

`tools/inspect_haskell.py` owns only `inspect` and `context`, requiring Python
3.12+ and both GHC and GHCi on PATH. This inspection profile is independent of
the Cabal-selected compiler used by native doctor/check. The small editor
wrappers dispatch to the appropriate backend; they do not rebuild the native
binary or fall back to Python for operational commands. See
[the compiler/editor contract](tooling.md) and [editor setup](editors.md).

Python remains in formatter provisioning, headless player journals, independent
test/oracle harnesses, maintainer publication/docs checks and some optional asset
preparation. Provers and the Haskell Design reader retain their separate setup
and evidence. Those tools have distinct jobs, not duplicate create/build/run
implementations. There is no compatibility launcher for the removed Python CLI
or scaffolder.

The native operational path and its bootstrap scripts do not call Python. Native
acceptance removes copied Python files before rebuilding and continuing a
relocated game. An independent Python test oracle helps expose behavioral
mistakes without duplicating production command interpretation.
Browser JavaScript, editor TypeScript/Lua, C interfaces and shaders retain real
host responsibilities; replacing them merely to change language is not the goal.
For interactive POSIX use, the native tool execs Cabal and lets the existing
shell own foreground/background jobs. It does not add a private terminal proxy
or C stop adapter. Captured commands retain managed child cleanup. The Windows
path retains inherited console behavior and Job Objects.

## Verification boundaries

`tools/test_native_cli.py` runs real GHC/Cabal operations and actual terminal
input, including source edits, a second mechanic after relocation, Japanese and
space-containing paths, CRLF input, JSON/exit compatibility, refusal cases and
compiler timeout/cancellation checks. It runs outside the checkout and rebuilds
the generated tooling after deleting the original game and source snapshot.
The tests are evidence for this bounded CLI and optional starter only.

On Windows, the acceptance driver requires
`--windows-compiler <verified-compiler-path>` in addition to `--binary`.
Replace that placeholder with the actual installed executable selected by the
[Windows recipe](#windows-explicitly-select-the-installed-compiler); it is not a
literal filename or automatic compiler discovery.

The reusable `.github/workflows/native-tooling.yml` executes bootstrap, typed
package tests and the same integration suite on Linux, Windows and macOS.
`alpha-checks` calls it once on each PR/main push and requires it before Pages
publication; manual native-only dispatch is also available. Its presence is not
proof that those jobs passed; inspect results for the exact revision. Dependency
caches are OS/architecture/toolchain/lock-specific, never cache game output or
the final executable, and can be written only by a validated main push.
The Windows matrix job runs the complete compiler-path and Template Haskell
preflight once, before native bootstrap. `--select-compiler-output` adds an output
file only after every required profile assertion passes; it does not select a
smaller suite. Linux/macOS start independently, without a separate Windows job
ahead of the whole matrix. A Windows failure still fails native acceptance and
blocks Pages publication.
The native job also runs generated-document lint, formatter integration, ordinary
Cabal workspace continuation and real native editor-adapter subprocess checks.
They reuse its existing executable rather than add another dependency bootstrap
to the source/kernel job. That job checks the kernel through ordinary Cabal and
retains the separate inspection, player and source gates. The native job's
45-minute ceiling permits slower first setup; captured commands remain bounded.
The VSCode adapter subprocess check mocks only host UI; it does not establish
installed-editor acceptance. Lightweight Node/Lua contracts separately exercise
routing and refusal cases. A configured check is not evidence of a passed revision.

No physical editor session, graphical presentation, touch device, binary release
or human fun assessment follows from these checks. Record unavailable Windows
symlink privileges separately rather than labelling a skipped case a pass.

The [prevention ledger](failure-prevention.md#native-tooling-ownership-and-transport-boundaries)
records the discovered ownership, filesystem, relative-root, text transport and
first-use failures, their structural fixes and the tests that prevent recurrence.

## Verification scope

The current commands and required CI are described above. For exact historical
revisions, job links, cache conditions and measured setup/startup costs, read the
[pinned CI and measurement record](https://github.com/M-simplifier/fp-game-alpha/blob/7682f7c620fbc03c288a501d5a9c116bbba7d999/docs/native-tooling.md#verified-ci-and-local-measurements).
Those observations are not a fresh run of this checkout or of a generated game.
Tooling changes need their affected checks and current CI; a game's feature
change needs its own tests and host play checks. Source-only relocation proves
independent continuation, not a cold-machine install or a prebuilt distribution.
