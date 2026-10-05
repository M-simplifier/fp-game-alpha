# Pinned quantity LiquidHaskell reproduction

This opt-in checker runs the recovered annotation-only `Colony.Units` module
and its **six original, one-edit mutants** in an isolated output directory.
It shares the sibling [LiquidHaskell laboratory](../../liquidhaskell/README.md)
and installs nothing. The ordinary [quantity runtime checker](../README.md)
is a separate target and uses a different GHC version.

## Run

Use Python 3.12+ on a POSIX host with the exact GHC **9.6.3**, Cabal
**3.16.1.0**, Z3 **4.15.1**, LiquidHaskell **0.9.6.3.1**,
liquidhaskell-boot **0.9.6.3**, and liquid-fixpoint **0.9.6.3** stack.
Set `GHC`, `GHC_PKG`, `CABAL`, and `Z3` to those executables, or put the
matching versions on `PATH`. Prepare and build the sibling laboratory first,
using its documented commands; `LH_RUN_DIR` below is that existing run directory.
Do not use GHC 9.6.7 from the ordinary runtime target for these plugin checks.

From the repository root:

```sh
python3 research/quantity/lh-checker/check.py source-check
python3 -m unittest discover -s research/quantity/lh-checker -p 'test_*.py'

python3 research/quantity/lh-checker/check.py doctor --lh-run-dir "$LH_RUN_DIR"
python3 research/quantity/lh-checker/check.py check --lh-run-dir "$LH_RUN_DIR"
```

`check` and `doctor` create unique output directories under the ignored
`.build/quantity-lh/`. An explicit `--run-dir` or `RUN_DIR` must name a new
or empty directory, disjoint from the prepared lab and the maintained source
tree. Each invocation starts with all seven cases marked `not_run` and emits
its own `result.json`; an old report cannot satisfy a new run. `doctor` verifies
prerequisites and package identity but performs none of the seven checks.

The shared prepared layout is:

```text
LH_RUN_DIR/
  prepared.json
  build-result.json
  cabal-home/config
  cabal-store/ghc-9.6.3/package.db/
  lab/cabal.project
  lab/cabal.project.freeze
  lab/source/
  lab/vendor/
  lab/dist-newstyle/packagedb/ghc-9.6.3/
```

The runner validates the sibling's prepared-source hashes, verified
dependency marker and successful pinned build record, exact executable versions, all three plugin package pins
through `cabal exec --offline`, and the seven snapshotted trusted imports
against the prepared vendor sources. It never downloads dependencies, relaxes
pins, or accepts an unrelated compiler/package error as a mutant rejection.
Inherited `LIQUIDHASKELL_OPTS`, `LIQUID_DEV_MODE`, GHC package/RTS overrides,
and package data-directory overrides are cleared. Required data paths are then
set explicitly; home, XDG, and temporary directories are isolated per run.

## Exact acceptance contract

All seven named cases run with the historical `--check-var` selections:
`quantityMax`, `mkQty`, `qtyValue`, `zeroQty`, `addQty`, `subQty`.
The flags include `--total-Haskell`, `--savequery`,
`--smttimeout=15000`, and GHC `+RTS -K256m -RTS`. The historical lowercase
`m` is preserved exactly. Each compiler/Cabal/solver process group is bounded
by a 180-second process timeout.

- `good`: exit 0, exactly `LIQUID: SAFE (25 constraints checked)`, with all
  six selected binder names present
- `add-plus-one`, `sub-plus-one`, `upper-reversed`, `upper-off-by-one`,
  `always-left`, `missing-lower`: exit 1, `LIQUID: UNSAFE`, and
  `Liquid Type Mismatch`
- Unknown, timeout, stack overflow, parse/package failures, crashes, changed
  inputs, wrong SAFE counts, or unexpected acceptance all fail the aggregate

Each verdict and its constraint count or mismatch diagnostic must come from
the unique `Compiling Colony.Units` block for that case's exact staged source
path. A dependency's SAFE count or unrelated module's mismatch cannot satisfy it.

The run copies only checked Haskell source into the isolated output directory;
generated `.liquid`, object files, captures, and logs do not alter the inputs.
A fresh, nonempty `.fq` and `.smt2` must be generated for every named case;
their hashes are recorded, and partial `.smt2` files are never used as replay input.
A process-local executable named `z3` captures the exact bytes sent to and
received from the real pinned solver. Its source is an unchanged recovered
wrapper. Each case must produce captures with solver answers, and replay through
the real Z3 must match every recorded response, with one answer per
`(check-sat)` and no `unknown` or solver error. Capture exit markers may be absent
because liquid-fixpoint terminates its child; replay and complete response counts
remain mandatory. Replay is bounded at 90 seconds per stream.

The nine unchanged standalone SMT formulas also run: eight must return
`unsat`; the specifically named cast-before-check alternative must return
`sat`. Their original internal 20-second solver timeout and 30-second process
timeout remain unchanged. These mathematical/bitvector models are independent
of the Haskell bodies; they are not compiler-extracted proofs.

Exit 0 from `check` means `PASS_SCOPED_LH_REPLAY_AND_MODELS`: all seven named
LH observations, all captured streams, and all nine model outcomes matched.
It does **not** include the separate 631,024-row runtime oracle or static
constructor/coercion checks, which must be run with `../check.py`. Missing or
incorrect prerequisites return 2; failed observations return 1.

## Source identity and provenance

`provenance.json` records original → transfer-packed → selected destination
SHA-256 values for every recovered input. All 28 selected files remain
byte-identical to the transfer, including every formula and mutant.
The normalized `trusted-imports.json` contains only vendor-relative paths;
its original and adapted hashes are recorded separately.

- Source transfer archive: `fp-game-alpha-lh-quantity-source-transfer-20261004.zip`
- Transfer ZIP SHA-256:
  `5d78133d94b6872974087efed7e3580f4b46b58138951acf914b81d89c73c407`
- Frozen fixture SHA-256:
  `082f8af0cb1a2de3e4faa62753b31a2d263e232fd729f318ac9d58a813f9ef75`
- Annotation-only source SHA-256:
  `d90d4fce3bf1d6220a4366b4d05316002919b5c6e50b7d4b9e43ef9571c8d46d`

The exact fixture is the complete prefix of the checked source; its suffix
contains only LiquidHaskell annotations and whitespace. Types, imports,
instances, roles, function bodies, and Haskell tokens are unchanged.

Historical whole-game archives, path-bound scripts, raw historical reports,
attempt logs, and the old 2,975-file audit are not shipped or recreated here.
Historical acceptance is not copied into a new result. Runtime input/output
corpora likewise come from a new ordinary runtime run, not historical reports.
Third-party snapshots retain their [license and attribution](THIRD-PARTY-NOTICES.md).

## Remaining trust boundary

The checked bound is 0 through 9,000,000,000,000. This is a selected-binder
result under explicit bounded inputs for addition/subtraction and the pinned
GHC/LH arithmetic assumptions. It is not full-module, serialization, caller,
game, compiler, or verifier soundness. The `Int64` casts rely on trusted
import specifications; the independent bitvector checks do not prove GHC's
machine implementation. Exact replay uses the same solver, not an independent
proof checker. The known historical false-division acceptance is not repaired
by this quantity result, and any division-dependent soundness gate stays separate.

The unit tests exercise orchestration and refusal behavior with simulated
tool output; passing them does not claim that LiquidHaskell ran. Only a new
successful `check` report supplies current scoped checker evidence.

## Recorded new Linux run

[The 2026-10-05 Linux x86-64 receipt](evidence/linux-20261005.json) records the
actual pinned run: good SAFE25, all six named mutants UNSAFE, seven complete
captured streams with 175 exactly replayed answers (11 SAT / 164 UNSAT), and all
nine independent models (eight UNSAT / one SAT counterexample). The checker
returned 0. All 28 selected recovered inputs matched before and after execution.
This run does not repeat the separate source-only runtime oracle, establish
verifier soundness, or certify clean-clone/cross-platform execution. In
particular, the [sibling diagnostic](../../liquidhaskell/README.md) reproduced
its intentionally false accepted division claim and keeps the soundness gate
failed.
