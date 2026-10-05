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

The native CLI/terminal-workspace profile passed actual Linux, Windows and macOS
CI at `be1208af`; this remains experimental, bounded evidence. The native guide
links the exact jobs and scope limits. It is not verification of this checkout
or of every new game, editor or host.

## What doctor and builds establish

Doctor resolves the game's compiler through Cabal's bounded `cabal path` query,
honoring project selection and custom wrappers. It reports the selected path and
version, missing tools and baseline comparison. `ready-to-try` means detection
and selection succeeded; only an actual build/test establishes this checkout.
`--json` is available on captured commands. Failures return nonzero.

Build/test use Cabal configuration, cache, store and output inside `.build/`,
with package repositories disabled for the baseline game profile. They work
without fetching Hackage metadata, even with an empty global Cabal cache.
The project's ordinary `build.config` route remains usable where supplied.
Tool bootstrap has a separate dependency acquisition/cache contract; do not
mistake a warm tool build for clean-machine setup.

Doctor and saved-source `check` use the same project-selected compiler rather
than guessing from PATH. Selection errors stop the command with no fallback.
With Cabal present, doctor creates guarded temporary configuration/cache state
under `.build`, removes that query state afterward, and performs no game build.
The query has a fixed 20-second timeout. With no Cabal on PATH, doctor creates
no state; an explicit compiler does not require an ambient `ghc` alias. The
shipped local profile needs no network access. Cabal's package-offline mode is
not a network sandbox: inspect and trust custom remote project imports, whose
side effects remain Cabal's responsibility.

Read [the type and arena guide](architecture.md) after the first tests. Native
graphics, browser, server and mobile toolchains require separate acceptance
and are tracked in [the milestones](roadmap.md).

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
Run `python tools/formatter.py plan`, then `install` when permitted;
`check` never downloads and `write` never targets vendored source.
