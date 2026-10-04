# Setup and the first build

The tested baseline is Python 3.12+, GHC 9.6.7 and Cabal 3.12.1.0. This pins
the project baseline, not a claim about the latest or recommended upstream
release. Git is needed to clone and run publication checks. The kernel needs
no third-party packages, artwork or native rendering SDK.

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

Doctor reports observed versions, missing tools, optional HLS and the baseline
comparison. Its `ready-to-try` result means the tools were detected; only an
actual build/test establishes this checkout. JSON output is available with
`--json` on each subcommand. Failures return nonzero.

The CLI creates Cabal configuration, cache, store and build outputs inside
`.build/`. It disables remote repositories for this dependency-free profile.
An empty global Cabal cache therefore works without fetching Hackage security
metadata. Your global Cabal configuration is not modified. A raw `cabal build
--offline` with a brand-new global config can still try that bootstrap; use
the CLI path for first-user acceptance.

Read [the type and arena guide](architecture.md) after the first tests. Native
graphics, browser, server and mobile toolchains require separate acceptance
and are tracked in [the milestones](roadmap.md).
