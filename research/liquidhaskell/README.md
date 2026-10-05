# Pinned LiquidHaskell diagnostic reproduction

This opt-in laboratory contains the recovered original arithmetic contracts,
negative controls, intentionally false division refinement, and frozen game
runtime bridge. The source files are byte-identical to the recovered transfer.
It does not participate in normal game/editor startup or the source-only
quantity command.

## Scope and the failed soundness gate

The expected pinned observation is that `DivAssumptionProbe` receives `SAFE`
while ordinary Haskell returns `0`, contradicting its claimed result `99`.
Reproducing that observation records both:

- `observation_reproduced: true`
- `division_soundness_gate: "failed"`

This is **not a soundness badge**. No newer LiquidHaskell version is assessed.
The runtime bridge is finite: 25 quantity pairs / 50 comparisons and 5,016
cancellation triples. It is not a universal bridge proof or whole-game proof.

The full diagnostic checks all twelve original modules. `--minimal` selects
Contracts, BadAddition, DivAssumptionProbe, DivNonzeroProbe and NoDivFalseProbe,
while retaining the ordinary runtime bridge. Named SAFE/UNSAFE markers, exact
expected process exits, nonzero checked-constraint counts for SAFE, and saved
query presence are checked. An arbitrary compiler failure never counts as an
expected negative control. Unknown, timeout and infrastructure failure remain
separate.

## Exact prerequisites

- POSIX environment and Python 3.12+ (safe tar extraction)
- GHC **9.6.3**, including ghc-pkg; no relaxed dependency bounds
- Cabal **3.16.1.0**
- Z3 **4.15.1**
- Native build prerequisites suitable for GHC, including a C compiler, GMP and libffi
- LiquidHaskell **0.9.6.3.1**, liquidhaskell-boot **0.9.6.3**,
  liquid-fixpoint **0.9.6.3**, built from the supplied exact dependency lock

Set `GHC`, `GHC_PKG`, `CABAL`, and `Z3` to explicit executable paths, or put the
required executables on PATH. This runner never installs compiler/solver
binaries and never changes default tools. GHC 9.6.6/9.6.7 is not interchangeable
with this historical checker stack. The freeze file pins the GHC 9.6.3 core
package versions, including bytestring 0.11.5.2.

## Isolated commands

Choose an absent `RUN_DIR` outside this experiment's source directory. Every
phase below uses the same directory. The explicit download step restores 121
official Hackage source archives (4,196,481 bytes), verifies each SHA-256 and
size, then applies the exact included official Cabal revisions. Toolchains,
dependency packages and generated evidence are not repository content.

```sh
export RUN_DIR=/absolute/path/to/a/new/lh-run
python3 research/liquidhaskell/check.py verify-sources
python3 research/liquidhaskell/check.py doctor
python3 research/liquidhaskell/check.py prepare --fetch-dependencies
python3 research/liquidhaskell/check.py build
python3 research/liquidhaskell/check.py check --require-sound-div
```

`--run-dir PATH` overrides the environment variable. `prepare` without
`--fetch-dependencies` only copies inputs and deliberately leaves dependency
readiness false. Use a fresh directory to repeat preparation or checker execution. An interrupted
or failed dependency build can be resumed with `build --retry-build`; each
attempt is retained under `build-attempts`, and the top-level build result is
the latest summary. Build is offline after pinned archives have been restored, uses
one Cabal job as historically configured, and has a two-hour process bound.
Each checker command retains `--total-Haskell`, `--savequery`, the 15-second SMT
limit and 180-second process limit. Timeouts kill the process group.

`check` exit 0 means observations matched, **including the failed division
soundness gate**. The first-check command above enables `--require-sound-div`, which returns 1
for the expected false acceptance. Omit this flag only when an observation-match
exit status is intentionally desired. Do not run the checker twice in the same
run directory: existing checker evidence is protected from overwrite.
Other observation mismatches return 1; prerequisite/infrastructure exceptions
return 2. Read `check-result.json`, not just the exit status. There is no green
soundness result in this laboratory.

## Evidence and source integrity

`prepared.json` records included-source and dependency-source identities.
`build-result.json` records actual tool/package versions and build status.
`check-result.json` records each named result, command, timeout, input hashes,
runner hash, runtime bridge and the separate division gate. Publishable command
arguments use `${RUN_DIR}`/`${GHC}` placeholders. Local raw logs may contain
machine paths and must be reviewed before sharing. A source hash is not a new
proof result; `verify-sources` explicitly records that the checker was not run.

Generated LH `.smt2` files may lack complete initialization. The diagnostic
runner does not claim standalone solver-capture replay. The historical whole
873-file game audit and old output counts are not fabricated or rerun here.

`provenance.json` records archive SHA-256, original/transfer/published hashes and
safe laboratory-relative paths. The new wrapper replaces the old path-bound
scripts, whose source hashes remain as adaptation provenance. Public historical
summaries remain separately curated in `docs/evidence/historical-guarantees.json`.

Runner contract tests, which do not prove the Haskell properties:

```sh
python3 -m unittest discover -s research/liquidhaskell -p 'test_*.py' -v
```

See [third-party notices](THIRD-PARTY-NOTICES.md). All generated/downloaded state
belongs under `RUN_DIR`, including Cabal config/store/cache, temporary files,
package databases, copied sources, compiler output and logs.

## Native linker portability

Some official GHC 9.6.3 Linux bindists make `hsc2hs` request GNU gold. A host
with only GNU bfd can fail a dependency's C probe with `cannot find ld`. Set
`HSC2HS_OPTIONS=--lflag=-fuse-ld=bfd` explicitly for `build` on that host.
The chosen native-linker option is recorded in the command evidence and does
not change Haskell package versions, refinements or logical checker flags.
Keep earlier failed evidence with `--retry-build`; never count the failure as
an expected logical negative control. This option is not needed when the
required native linker is already available.

## Optional compiler/solver bootstrap

Install GHCup from its [official installation guide](https://www.haskell.org/ghcup/install/)
and review its [system requirements](https://www.haskell.org/ghcup/install/#system-requirements).
The [GHC 9.6.3 release page](https://www.haskell.org/ghc/download_ghc_9_6_3.html)
also provides official compiler bindists. With GHCup available, this optional
POSIX setup keeps tool installations separate and does not select new global
defaults:

```sh
export TOOLS="$(pwd)/.build/formal-tools"
mkdir -p "$TOOLS"
GHCUP_INSTALL_BASE_PREFIX="$TOOLS/ghcup-state" \
  ghcup install ghc 9.6.3 --no-set --isolate "$TOOLS/ghc-9.6.3"
GHCUP_INSTALL_BASE_PREFIX="$TOOLS/ghcup-state" \
  ghcup install cabal 3.16.1.0 --no-set --isolate "$TOOLS/cabal-3.16.1.0"
export GHC="$TOOLS/ghc-9.6.3/bin/ghc"
export GHC_PKG="$TOOLS/ghc-9.6.3/bin/ghc-pkg"
export CABAL="$TOOLS/cabal-3.16.1.0/cabal"
```

Obtain Z3 from the [official 4.15.1 release](https://github.com/Z3Prover/z3/releases/tag/z3-4.15.1)
for your platform, or use the [pinned z3-solver Python distribution](https://pypi.org/project/z3-solver/4.15.1.0/)
with an isolated target:

```sh
python3 -m pip install --target "$TOOLS/z3-4.15.1" --no-deps 'z3-solver==4.15.1.0'
export Z3="$TOOLS/z3-4.15.1/bin/z3"
python3 research/liquidhaskell/check.py doctor
```

GHCup verifies its download digest before installing. Record the selected
platform archive and its hash alongside your run; a different platform archive
has a different identity. Reserve several GB for GHC and the plugin build, not
just the roughly 200 MB compiler archive. The compiler setup is separate from
the 4.2 MB of pinned Hackage source archives restored by `prepare`.

On a host without gold, export `HSC2HS_OPTIONS=--lflag=-fuse-ld=bfd` before the
build step, as explained above. None of these setup commands is called by the
normal game, editor or source-only quantity runner. Native/macOS/Windows build
portability is not established by a Linux run.

## Recorded new Linux run

[The 2026-10-05 Linux x86-64 receipt](evidence/linux-20261005.json) records a
fresh isolated run of this public wrapper: all twelve named checker outcomes
matched, as did the 25-pair/50-comparison and 5,016-triple runtime bridge.
The intentionally false division refinement was accepted while Haskell
returned 0 instead of 99: `observation_reproduced=true`,
`division_soundness_gate="failed"`, strict process exit **1**. This is not a
soundness pass, cross-platform certification or clean-clone CI result.
The earlier missing-gold build failure and successful recorded bfd adaptation
are kept distinct from the logical diagnostic results.

The repository preserves the exact original newline bytes of pinned Cabal
revision metadata and retained package licenses using narrow `.gitattributes`
exceptions. Do not normalize those files: their byte hashes are part of the
dependency/source reproduction contract.
