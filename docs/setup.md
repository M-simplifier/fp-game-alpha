# Setup and the first build

The native Haskell `fp-game` executable is the authoritative operational path.
Start with [native tooling](native-tooling.md) for the pre-GHC checks, explicit
one-time bootstrap and compiler-selection details. No command silently installs
a compiler or downloads tool dependencies.

The verified baseline is GHC 9.6.7 and Cabal 3.12.1.0. This pins the project's
tested profile, not the latest or recommended upstream release. Git is needed
to clone and run publication checks. Python is not required for native planning,
creation, doctor, build, test, check or run. Separate inspection, formatter,
player-journal and maintainer tools retain their own prerequisites.

Use the [official GHCup installation guide](https://www.haskell.org/ghcup/install/)
for Windows, macOS or Linux and its system prerequisites. Reuse an appropriate
installed toolchain. Installing or changing a compiler is a separate, explicit
operation; preserve existing project compiler settings and wrappers.

## Bootstrap once, then use the executable

```sh
git clone https://github.com/M-simplifier/fp-game-alpha.git
cd fp-game-alpha
# Linux/macOS: check installed tools without downloads
sh tools/bootstrap-fp-game.sh --check
# Explicitly acquire pinned CLI dependencies and build the separate tool package
sh tools/bootstrap-fp-game.sh --download
.build/tools/fp-game doctor
.build/tools/fp-game build
.build/tools/fp-game test
```

With the pinned dependency index/store already populated, omit `--download`
for an offline bootstrap. The tool package's external dependencies are separate
from the game core's GHC-bundled-only dependencies. Normal commands run the
built executable directly; rerun bootstrap explicitly when its source changes.

On Windows use `./tools/bootstrap-fp-game.ps1 -Check` and the
[explicit compiler selection recipe](native-tooling.md#windows-explicitly-select-the-installed-compiler)
before bootstrap/build, especially for Japanese paths. Run
`./.build/tools/fp-game.exe` after bootstrap. The bootstrap's `-CompilerPath`
selects the compiler for the tool package only; the game's own Cabal profile
selects its compiler. Probe an actual installed executable and preserve existing
settings. Do not rewrite PATH or overwrite `cabal.project.local`. That ignored,
machine-local profile is excluded from generated source and must be deliberately
recreated after relocation.

## What a successful command establishes

Doctor checks the selected compiler and prerequisites; `ready-to-try` is not a
build result. Build and test the checkout you are using. Game builds use isolated
`.build/` state with repositories disabled for the baseline profile. Bootstrap
uses separate pinned tool dependencies and needs an explicit initial download
or a populated cache.

Doctor and saved-source `check` honor the compiler selected by Cabal, including
custom wrappers. Selection failures stop without a PATH fallback. Cabal's
offline mode is not a network sandbox; inspect and trust custom project imports.
See [the native guide](native-tooling.md) for compiler profiles, failure diagnosis
and the exact scope of recorded platform results.

After the first tests, read [the type and arena guide](architecture.md) when
changing the kernel. Other hosts have separate requirements in
[the platform records](platforms.md).

## Optional compiler inspection and formatting

Saved-source inspection is a separate Python 3.12+ helper requiring both GHC
and GHCi on PATH. It does not inherit native doctor/check's Cabal-selected
compiler profile:

```sh
python tools/inspect_haskell.py context libraries/game-transition/src/Game/Transition.hs --symbol replay
```

See [the compiler/editor contract](tooling.md) for its precise scope. On Windows
use the command that launches Python 3 (`python` or `py -3`).

Use the [pinned project-local formatter](formatting.md) for explicit setup,
non-writing checks, owned-source formatting and external HLS integration.
