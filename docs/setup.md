# Setup and the first build

For the opt-in Haskell executable and pre-GHC bootstrap checks, see
[native tooling](native-tooling.md). The commands below remain the established
Python compatibility route; neither path silently installs a compiler. For
Windows projects with Japanese paths, use the
[explicit native compiler selection](native-tooling.md#windows-explicitly-select-the-installed-compiler)
recipe before bootstrap/build, and keep its separate tool and game selections
clear. That opt-in route preserves installed versions and PATH; full native
three-OS end-to-end acceptance of the change is still pending.

The tested baseline is Python 3.12+, GHC 9.6.7 and Cabal 3.12.1.0. This pins
the project baseline, not a claim about the latest or recommended upstream
release. Git is needed to clone and run publication checks. The kernel needs
no third-party packages, artwork or native rendering SDK.

Doctor/plan show the available official archive versions, SHA-256, download
URLs and sizes from [the metadata lock](../tools/toolchains.json). The Windows
baseline archives total 339,105,165 bytes (about 323 MiB); extraction needs
additional disk space. Their official checksum tables and HEAD sizes were
read on 2026-10-04; the archives were not downloaded by that metadata check.
macOS archive sizes are explicitly unknown in this lock. Linux bindist selection
and native prerequisites remain with GHCup; no platform/ABI choice is guessed.
Checksums describe downloaded archives, not the observed installed executables.

Use the [official GHCup installation guide](https://www.haskell.org/ghcup/install/)
for Windows, macOS or Linux and its system prerequisites. GHCup distinguishes
recommended from latest versions and verifies its own downloaded toolchain
metadata. Installing a compiler is a separate, explicit operation:

```sh
ghcup install ghc 9.6.7
ghcup set ghc 9.6.7
ghcup install cabal 3.12.1.0
ghcup set cabal 3.12.1.0
```

Open a new terminal after PATH changes. On Windows use the Python command
that launches Python 3 (`python` in these examples, or `py -3`). Commands here
work without Bash. Tool downloads and OS prerequisites require network access;
the kernel's build and tests do not. No command silently installs a toolchain.

```sh
git clone https://github.com/M-simplifier/fp-game-alpha.git
cd fp-game-alpha
python tools/fp_game.py doctor
python tools/fp_game.py build
python tools/fp_game.py test
python tools/fp_game.py context libraries/game-transition/src/Game/Transition.hs --symbol replay
```

The Python doctor shown above reports observed versions, missing tools, optional
HLS and the baseline comparison. Its `ready-to-try` result means the tools were detected; only an
actual build/test establishes this checkout. JSON output is available with
`--json` on each subcommand. Failures return nonzero.

The CLI creates Cabal configuration, cache, store and build outputs inside
`.build/`. It disables remote repositories for this dependency-free profile.
An empty global Cabal cache therefore works without fetching Hackage security
metadata. Your global Cabal configuration is not modified. A raw `cabal build
--offline` with a brand-new global config can still try that bootstrap; use
the CLI path for first-user acceptance.

For the native route, `doctor` and saved-source `check` resolve the game's
compiler through `cabal path`, honoring project selection and custom wrappers.
Compiler-selection errors stop the command instead of falling back to PATH.
With prerequisites present, native doctor can write guarded `.build`
temporary configuration/cache state, cleans that query state afterward, and
performs no game build. The shipped local profile needs no network access. Custom
Cabal remote imports retain their own side effects, so inspect and trust project
configuration. The query has a fixed 20-second timeout. With no Cabal on PATH,
doctor creates no state; an explicit compiler does not require ambient `ghc`.

A compiler-only `cabal.project.local` is an ignored machine-local file, not part
of generated source. Never overwrite an existing profile; inspect and preserve
its settings. Use a raw forward-slash absolute path when deliberately adding
`with-compiler`, and recreate that local choice after relocation. The Windows
bootstrap's `-CompilerPath` affects the separate tool package only, so it does
not replace this game profile. See the linked recipe for exclusive UTF-8 creation.

Read [the type and arena guide](architecture.md) after the first tests. Native
graphics, browser, server and mobile toolchains require separate acceptance
and are tracked in [the milestones](roadmap.md).

## Consistent Haskell formatting

Use the [pinned project-local formatter](formatting.md) for explicit setup,
non-writing checks, owned-source formatting and external HLS integration.
Run `python tools/formatter.py plan`, then `install` when permitted;
`check` never downloads and `write` never targets vendored source.
