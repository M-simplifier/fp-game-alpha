# Reproduction entrypoints

The historical experiments have recorded runs on pinned toolchains. The
source-only quantity check below is the first maintained public runner. All
LiquidHaskell, SBV, TLC and Bend checker entrypoints in the remaining sections
are integration plans until their selected sources and prerequisites are
published and rerun from a clean clone. Do not infer portability from old logs.

## Common contract for public runners

1. Resolve the repository and experiment directory from the runner's own location. Accept executable paths through `GHC`, `GHC_PKG`, `CABAL`, `Z3`, `JAVA`, `PYTHON`, `NODE`, and `BEND` as relevant; otherwise use the executable name on PATH
2. Check the requested executable exists and print its version before creating evidence. Fail with a specific prerequisite error when the version or package set differs from the pinned experiment; optionally allow an explicitly labelled exploratory run
3. Keep dependencies, package databases, generated files, temporary state, and results under a caller-selected `RUN_DIR`. Never overwrite the historical evidence summary or original fixtures
4. Record actual versions, command arguments, exit codes, timeouts, each named result, fixture hashes, and runner hashes. Redact machine-local absolute paths from publishable summaries
5. Keep `unknown`, timeout, tool error, expected counterexample, unexpected acceptance, and proof success distinct. Validate semantic markers as well as process exit codes
6. Read-only input identity and a new execution result are separate records. A relocated or edited script has a new hash and must never be labelled byte-identical to its historical source

The common contract describes the target for future runners. The current
quantity runner uses the ignored `.build/quantity` directory and pins GHC
9.6.7; it has a narrower scope than the historical checker experiment.

## Quantity

Selected source directory: `research/quantity`. Run the maintained route:

```sh
python research/quantity/check.py doctor
python research/quantity/check.py check
```

It checks the exact frozen source hashes, eight intended GHC type rejections,
two positive compilations, and 631,024 Python-oracle rows on both the frozen
and annotation-only Haskell modules. Windows GHC 9.6.7 passed locally; the
three-OS clean-checkout result is tracked separately. This command does not
invoke LiquidHaskell or Z3. A different or unavailable GHC fails the check.

Pinned checker prerequisites: GHC 9.6.3, LiquidHaskell 0.9.6.3.1, liquidhaskell-boot 0.9.6.3, liquid-fixpoint 0.9.6.3, Z3 4.15.1. Runtime tests additionally use Python3 and the GHC-provided binary/deepseq packages.

The selected `fixture/Colony/Units.hs` and `annotated/Colony/Units.hs` remain
byte-identical to the transferred source. Their SHA-256 values are
`082f8af0cb1a2de3e4faa62753b31a2d263e232fd729f318ac9d58a813f9ef75`
and `d90d4fce3bf1d6220a4366b4d05316002919b5c6e50b7d4b9e43ef9571c8d46d`.
The historical `scripts/make-copies.py` and six mutant modules are still
outside this selected public route.

Future LiquidHaskell checker integration must preserve all six `--check-var`
options, `--total-Haskell`, the 15-second SMT limit, 180-second process limit,
and the recorded 256 MiB GHC stack limit. It needs the exact GHC 9.6.3 package
database and three data directories. The source transfer's historical
`scripts/check-final.sh` and `scripts/check-scoped.sh` are not yet public
entrypoints.

The current `check.py` replaces the path-bound historical GHC runtime and
static wrappers for this source-only subset. `oracle.py` preserves the
historical vector generator and expected-value functions; its obsolete
path-bound runner was removed. Whole-game archive validation, SMT queries,
and compiler/solver-capture replay were not performed by this public command.

The broader historical target is good SAFE25, all six named mutants UNSAFE,
the finite runtime/type checks above, eight UNSAT model queries and one SAT
cast-before-check witness. Only the source-only finite checks have a public
runner. It matches named GHC diagnostic markers, so an arbitrary compiler
failure does not pass as a desired type rejection.

Do not export the old `record-metadata.py` unchanged: it inspects entire historical game trees. New public metadata must describe the included inputs and the new run only. Full solver-capture replay requires complete initialization-bearing streams; these are optional archival evidence, not necessary to include in the small source repository.

## LiquidHaskell diagnostic

Proposed directory: `research/liquidhaskell`.

Use the same pinned LH stack as quantity. The existing GHC 9.6.6 environment was incompatible with this LH release's bytestring constraint, so a generic “GHC 9.6” prerequisite is insufficient. Do not hide the mismatch with relaxed dependency bounds.

Primary entrypoints: `scripts/check-minimal.sh` for five diagnostic modules; `scripts/check-modules.sh` for all twelve cases; `scripts/runtime.sh` for the ordinary-runtime bridge. A public build needs a supported package setup with the exact dependency lock. The historical `cabal.project` disables remote repositories and assumes a local vendor tree; either reconstruct that tree from pinned official package sources, or provide a separately documented public Cabal build and revalidate it.

The minimal diagnostic expects Contracts=SAFE, BadAddition=UNSAFE, DivAssumptionProbe=SAFE-but-invalid, DivNonzeroProbe=UNSAFE, NoDivFalseProbe=UNSAFE, and runtime `divZeroProbe 0` equal to 0. Check these expectations explicitly; the historical minimal script records results without enforcing every expected classification.

Keep two outcomes separate: `observation_reproduced=true` and `division_soundness_gate=failed`. The existing `scripts/validate.py --require-sound-div` exits 1 for the known false acceptance. Do not turn this into a green soundness badge. No newer-version runtime result exists in the inspected evidence.

## SBV cancellation

Proposed directory: `research/sbv-cancellation`.

Pinned prerequisites: GHC 9.6.6/base 4.18.2.1, SBV 10.12, Z3 4.15.1, Cabal 3.16.1.0, and compatible native build dependencies. Eleven package versions/hashes are recorded in `metadata/dependency-lock.json`; do not include downloaded packages or build caches in the small public export.

Primary entrypoints: `scripts/prove.sh`, `source/Proof.hs`, and `scripts/replay-bundled.sh`. Prefer the bundled `frozen-0.4` fixture. `scripts/replay.sh` is an original-location runner and must not be the public default. Parameterize tool paths and use local library-discovery configuration only when needed.

Exact acceptance requirement: inspect the named query result map. Require all four general query keys and both bounded query keys to be `unsat` for the recorded full result, and all three control keys to be `sat`. The historical proof executable can accept a bounded fallback if a general query fails to prove; an aggregate exit 0 therefore does not by itself establish the general theorem. A fallback run must retain the general result as unknown/error and advertise only the bounded claim.

Also require the 36,400-input helper bridge, extracted SAT-witness replay, and 1,412 transactions / 127,011 assertions. Keep the helper-only R=0 checks separate from valid running-job behavior. Do not infer scheduler coverage from fixtures that directly set progress.

## Save lifecycle

Proposed directory: `research/save-lifecycle`.

Prerequisites: Linux/POSIX, GHC 9.6.6 with the frozen core's packages, Java, Python3, and TLC release v1.7.4 (TLC 2.19). The TLC jar is external tooling, not repository content. The recorded jar SHA-256 is `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.

Entrypoint: `scripts/reproduce.sh`, which fetches/verifies the pinned jar and invokes `scripts/run_experiment.py`, followed by `scripts/verify_evidence.py`. Retain the default included `vendor/colony0.2` source fixture or a byte-identical renamed fixture. Change the compiler default to PATH or require `GHC`; permit JAVA/PYTHON overrides without changing logical flags.

Preserve model bounds and TLC `-workers 1 -seed 1 -fp 0`, record the actual heap setting, and keep generated trace modules under the new run directory. Preserve all thirteen parser fields. Reject missing fields, booleans in integer positions, unsupported optimized Python mode, and invalid typed reference traces.

Expected outcome distinctions: safety/fair-liveness success exits 0; mutant invariant counterexamples exit 12; unfair-liveness counterexample exits 13; invalid traces are rejected with exit 11. Those nonzero negative controls are not infrastructure failures when their expected diagnostics match. Conversely an arbitrary nonzero result must never count as the desired counterexample.

## Bend

Proposed directory: `research/bend`.

Existing entrypoint: `BEND=/path/to/bend GHC=/path/to/ghc bash experiments/reproduce.sh`. Bend must report 2.0.35; GHC cross-check was recorded with 9.6.6; Node was 24.19.0. The script already accepts BEND/GHC, isolates HOME, and disables telemetry. It writes generated files beside its sources, so a public wrapper should copy inputs into RUN_DIR first or clearly document that behavior.

The Haskell part is optional in the historical script. A Bend-only pass must not report the cross-language check as run. Native C, GPU, and BendTT kernel checking need separate explicit commands/prerequisites and separate statuses. Generating C or BendTT text is not executing it.

Generated `world.mjs`, `world.c`, and `proof.bendtt` can be omitted and regenerated. If runtime-bearing generated code is committed, retain `experiments/BEND-LICENSE.txt` and upstream attribution.
