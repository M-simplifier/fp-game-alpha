# Reproduce cancellation arithmetic and its implementation bridge

This is the original experiment's `Proof.hs`, `Replay.hs`, and frozen 0.4
Haskell source, with a new portable, isolated runner. It is not a rewritten toy
model and does not check the current live game's whole implementation.
[Provenance](provenance.json) binds every recovered input to its exact SHA-256
and source Git blob. The original experiment was recorded with GHC 9.6.6;
the public profile uses GHC 9.6.7 / Cabal 3.12.1.0 / SBV 10.12 / Z3 4.15.1.

## Choose the smallest useful check

For the finite implementation bridge, only Python 3.12+ and GHC 9.6.7 are needed:

```sh
python research/sbv-cancellation/run.py self-test
python research/sbv-cancellation/run.py replay --run-dir .build/sbv-replay-1
```

For the actual SMT proof, use a POSIX host with the pinned compiler, Cabal,
Z3, a C compiler, and the native GHC development libraries. `GHC`, `GHC_PKG`,
`CABAL`, and `Z3` can name executables; otherwise they are resolved from PATH.
Each new execution requires a fresh directory. The default game and source-only
quantity workflow do not download or depend on any prover.

One optional way to obtain the official Z3 4.15.1 binary is the pinned
[Z3 Python distribution](https://pypi.org/project/z3-solver/4.15.1.0/):

```sh
python -m pip install --no-deps --target .build/research-tools/z3 z3-solver==4.15.1.0
export Z3="$PWD/.build/research-tools/z3/bin/z3"
python research/sbv-cancellation/run.py doctor --run-dir .build/sbv-doctor-1
python research/sbv-cancellation/run.py check --run-dir .build/sbv-check-1
python research/sbv-cancellation/run.py verify --run-dir .build/sbv-check-1
SBV_VERIFIED_RUN=.build/sbv-check-1 python -m unittest discover -s research/sbv-cancellation -p 'test_*.py'
```

The install location above is separate from the fresh run directory. An
existing official Z3 installation is equally suitable; the runner verifies its
version and records the executable hash. `RUN_DIR` may replace `--run-dir`.
A `--profile historical` route enforces the original GHC 9.6.6 / Cabal 3.16.1.0
versions and boot packages; it is retained for exact historical-toolchain
comparison and is not a claim of a new run on those older executables.

`check` downloads eleven official Hackage source archives, 1,491,375 compressed
bytes total, verifies their pinned sizes and SHA-256 hashes, and builds offline.
The [dependency lock](metadata/dependency-lock.json) is recovered unchanged;
[toolchain package sets](metadata/toolchains.json) keep historical and public
profiles separate. Downloaded upstream packages retain their original licenses.
The original Cabal source's `license: NONE` field is preserved as provenance;
the selected author-supplied experimental sources here are covered by this
repository's root MIT license. No dependency binaries or caches are published.

All downloaded sources, Cabal configuration/store, build artifacts, solver
transcripts, and logs stay under RUN_DIR. `SBV_DOWNLOAD_CACHE` may point to a
read-only directory of the same eleven tarballs; cached bytes are still copied
and hash-checked. There is no relaxed-bound dependency fallback, global package
installation, or mutation of the included original fixtures.

## What a successful run establishes

- Four general SInteger queries and two separately bounded queries are UNSAT
- The legacy eight-lot rounding discrepancy, missing progress upper bound,
  and Word64-overflow controls are SAT
- The extracted eight-lot witness is replayed through the imported real helper
- 36,400 literal evaluations agree with the frozen `cancelLoss` implementation
- Nine complete SMT streams give the expected verdict again with the same Z3
- The original direct-source suite passes 1,412 cancellation transactions and
  127,011 assertions, with 2,145 separate zero-required helper-branch inputs

The mathematical domain assumes Q >= 0, R > 0, and 0 <= p <= R. The source uses
mathematical integers. The eight-slot property is a fixed-arity algebraic
identity, not a theorem about arbitrary list processing or resource grouping.
A same-solver replay is not independent proof-certificate checking.

The finite transaction suite sets progress directly and supplies ample return
capacity. It does not establish scheduler timing, all capacity/placement cases,
FEFO correctness, serialization, UI behavior, or universal refinement of the
implementation. Read [the guarantee boundaries](../../docs/guarantees.md).

## Failure and evidence contract

The original proof executable permits a bounded fallback. This public wrapper
requires the exact complete nine-key result map: general UNKNOWN/error is a
failure even if the bounded query succeeds. Extra or missing keys, unexpected
SAT/UNSAT, nonzero processes, malformed/missing output, or timeout cannot pass.
`self-test` falsifies this gate with seven changed maps and three incomplete
replay outputs; those tests check the wrapper, not solver soundness.

Each run writes `receipt.json`: input/runner hashes, actual tool and package
versions, executable hashes, command arguments, exit codes, timeouts, named
results, and output hashes. Publishable receipt paths are redacted. Raw logs
remain local and can contain machine paths; review them before sharing.
`verify` rereads the receipt, source identities, copied fixture bytes, command
logs, proof artifacts and exact result map. An edited wrapper has a new hash;
old receipts must not be relabelled as executions of the edited wrapper.

The [public validation receipt](evidence/public-validation.json) records the
new Linux run. Its eighteen commands all passed; the optional receipt mutation
test rejects thirteen changed metadata/input/log cases. Receipts are integrity
and reproducibility records, not tamper-proof certificates.
