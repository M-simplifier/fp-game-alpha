# Reproduce the formal-method research

The original quantity/LiquidHaskell, SBV cancellation, and TLA+/TLC save
experiments are included as inspectable source, with optional isolated public
runners. They check real frozen Haskell inputs and their explicit models.
The default clone/new-game workflow does not install these specialized tools.
Historical results and new executions are separate records; source recovery
alone is not a rerun. The [2026-10-05 Linux integration record](evidence/formal-research-linux-20261005.json)
links the independently reread new receipts, exact counts and remaining limits. See [guarantee boundaries](guarantees.md) and the
[primary reference catalog](research-references.md).

## Choose a route by the question

- Quantity units, constructors and bounded arithmetic:
  [source-only quantity checks](../research/quantity/README.md), then the
  [actual six-binder LiquidHaskell checker](../research/quantity/lh-checker/README.md)
- Local refinement contracts and a deliberately false division contract:
  [LiquidHaskell diagnostics](../research/liquidhaskell/README.md)
- Cancellation conservation, progress monotonicity and partition rounding:
  [SBV model plus real helper/transaction bridge](../research/sbv-cancellation/README.md)
- Late callbacks, duplicate success, persistence ordering and fairness:
  [TLC finite protocol plus real save/load traces](../research/save-lifecycle/README.md)

Read the selected experiment's README before installing anything. It identifies
its exact inputs, assumptions, commands, failure rules and evidence scope.
The source and runner tests can be inspected without installing a prover.
These are research fixtures, not mandatory architecture for a new game.

## Use a result in your game or ask an AI to adapt it

Start with a concrete failure to prevent, then select one route. Do not install
all provers as part of `$new-game` or copy a frozen colony into a new design.

1. **State the claim and its assumptions.** Unit mixing and hidden constructors
   start with GHC rejection tests. Local bounded arithmetic can use the quantity
   contracts. Cancellation rounding/conservation fits the SBV integer model.
   Ordering, stale responses and eventual settlement fit the TLC protocol.
   Ordinary property/state-machine tests may be sufficient before any prover
2. **Reproduce the baseline, then create a separate experiment.** Keep these
   frozen sources and receipts unchanged. Name your game's actual module,
   function or transition and its source hash. A new bound, formula, compiler,
   invariant or source file creates a new experiment; historical constraint or
   state counts cannot be copied into its result
3. **Connect the claim to executable code.** Import the actual Haskell helper
   or transition in the bridge instead of copying its formula into both sides.
   Specify the input domain and check real callers, decode paths and failure
   cases. An Integer theorem does not certify Int64/Word64 overflow or a
   resource-list grouping implementation. Retain finite bridge tests even when
   the separate mathematical model is proved
4. **Adapt the falsifications too.** Include a deliberately wrong implementation
   and a weakened assumption that your check must reject with the right
   diagnostic. Update target-module bindings, expected result keys and counts
   through review. Missing output, unrelated compiler errors, UNKNOWN and
   timeout must remain failures. The known LH division false acceptance is a
   failed soundness gate; use a separately justified method rather than citing
   that SAFE result as assurance
5. **For protocols, document the abstraction.** Explain how actual events/state
   map to model actions/fields and check emitted traces against Init/Next.
   State bounds, ticket freshness, caller serialization, persistence abstraction
   and fairness explicitly. If the game adds queues, shared writers, reconnect
   or crash behavior, extend both model and real bridge; the old model says
   nothing about those additions
6. **Report three separate results:** what the model/checker establishes, which
   finite executions agree, and what remains trusted or untested. Retain pinned
   prerequisites, exact source/runner/output hashes and named negative outcomes.
   Passing a runner is reproducibility evidence, not a universal correctness
   certificate or independent proof-certificate verification

For an AI-assisted task, provide the concrete property, real source entrypoint,
selected experiment, intended domain/platform and acceptance conditions. Ask it
to explain why the bridge is faithful and to show an intentionally broken case,
not just to reproduce a green summary. The [verification practice](practice/haskell/verification-review.md)
provides the surrounding review questions.

## Lightweight hosted checks

The [formal-research-contracts workflow](../.github/workflows/formal-research-contracts.yml)
runs only for changes in these research families or by manual dispatch. It
checks recovered source hashes and Python wrapper/parser refusal behavior,
including simulated UNKNOWN, timeout and unrelated compiler diagnostics.
It installs no compiler/prover toolchains and does not rerun the mathematical
experiments. Receipt-mutation tests requiring a complete local run are skipped
there. Its green result must not be reported as a hosted LH, SBV or TLC proof.

## Common public-runner contract

1. Resolve sources from the runner's own location. Executable overrides use
   GHC/GHC_PKG/CABAL/Z3/JAVA/PYTHON where relevant; otherwise use PATH
2. Check exact pinned tool/package versions before a claimed checker run
3. Keep dependencies, package databases, generated trace modules, temporary
   files and results under RUN_DIR; preserve the included original inputs
4. Record actual versions, arguments, exits, timeouts, named outcomes, source
   and runner hashes. Publishable receipts redact machine-local paths;
   review raw local logs before sharing them
5. Distinguish a proof, expected counterexample, invalid-trace rejection,
   UNKNOWN, timeout and tool failure. An arbitrary nonzero process is not a
   successful negative control, and an aggregate exit zero is not a theorem
6. Bind new executions to the actual public wrapper hash. An adapted wrapper
   is not byte-identical to its old path-bound version

The lightweight source-only quantity runner predates this shared convention;
it uses `.build/quantity` and does not run a solver. The optional specialized
runners do not overwrite the curated historical evidence summary.

## Quantity

```sh
python research/quantity/check.py doctor
python research/quantity/check.py check
```

This unchanged GHC 9.6.7 route checks eight intended GHC rejections, two
positive compilations, and 631,024 Python-oracle rows on both the frozen and
annotation-only modules. It does not invoke LiquidHaskell or Z3.

The original fixture and annotated module remain byte-identical, SHA-256
`082f8af0cb1a2de3e4faa62753b31a2d263e232fd729f318ac9d58a813f9ef75`
and `d90d4fce3bf1d6220a4366b4d05316002919b5c6e50b7d4b9e43ef9571c8d46d`.
The recovered [checker package](../research/quantity/lh-checker/README.md)
contains the genuine six mutants and keeps the selected-binder, totality,
15-second SMT, 180-second process and 256 MiB GHC-stack boundaries.

The optional checker uses GHC 9.6.3, LiquidHaskell 0.9.6.3.1,
liquidhaskell-boot 0.9.6.3, liquid-fixpoint 0.9.6.3 and Z3 4.15.1.
The [new pinned checker receipt](../research/quantity/lh-checker/evidence/linux-20261005.json)
records SAFE25 for the six selected good binders, UNSAFE for all six named
mutants, seven complete streams/175 responses replayed exactly, and nine
independent SMT models (eight UNSAT plus one SAT witness). Whole-module checking, arbitrary casts,
serialization and the whole game remain outside that claim.

## LiquidHaskell diagnostic

The [public diagnostic runner](../research/liquidhaskell/README.md) restores
the recovered exact offline package lock from official hash-pinned Hackage
archives. It requires the exact GHC 9.6.3 stack, not merely any GHC 9.6.
All downloads, build products and checker outputs are opt-in and isolated.

```sh
python research/liquidhaskell/check.py verify-sources
python research/liquidhaskell/check.py doctor
python research/liquidhaskell/check.py prepare --run-dir .build/lh-1 --fetch-dependencies
python research/liquidhaskell/check.py build --run-dir .build/lh-1
python research/liquidhaskell/check.py check --run-dir .build/lh-1 --require-sound-div
```

The last command is expected to fail the soundness gate if the known false
acceptance is reproduced. Choose the check options on the first invocation:
existing checker evidence is protected from overwrite. Omit
`--require-sound-div` for observation-only acceptance; add `--minimal` to
select five diagnostics rather than the full twelve. Expected minimal observations are Contracts=SAFE,
BadAddition=UNSAFE, DivAssumptionProbe=SAFE-but-invalid,
DivNonzeroProbe=UNSAFE, NoDivFalseProbe=UNSAFE, and ordinary runtime
`divZeroProbe 0 == 0`. The false postcondition claims 99 under x==0.

`observation_reproduced=true` and `division_soundness_gate=failed` must remain
separate. The [new pinned-run receipt](../research/liquidhaskell/evidence/linux-20261005.json)
records all twelve observations and the deliberately failing strict gate. Reproducing this checker behavior does not restore a usable
cancellation/division guarantee. The newer-version source inconsistency in
[guarantees](guarantees.md) is still an unexecuted observation unless a separate
newer compiler/checker run is explicitly recorded.

## SBV cancellation

```sh
python research/sbv-cancellation/run.py self-test
python research/sbv-cancellation/run.py replay --run-dir .build/sbv-replay-1
python research/sbv-cancellation/run.py doctor --run-dir .build/sbv-doctor-1
python research/sbv-cancellation/run.py check --run-dir .build/sbv-check-1
python research/sbv-cancellation/run.py verify --run-dir .build/sbv-check-1
```

The public profile is GHC 9.6.7 / Cabal 3.12.1.0 / SBV 10.12 / Z3 4.15.1;
`replay` needs no SBV/Z3 installation. The historical GHC 9.6.6/Cabal 3.16.1.0
profile is separately named. See the [setup and source provenance](../research/sbv-cancellation/README.md).

The full gate requires all four general query keys and both bounded query
keys to be UNSAT, and all three control keys SAT. The original executable's
bounded fallback cannot satisfy this public general-theorem gate. UNKNOWN,
timeout, error, missing keys and unexpected extra keys fail closed.

It also requires the 36,400-input SBV/helper bridge, extracted SAT-witness
replay, nine same-Z3 SMT replays, and 1,412 transactions / 127,011 assertions.
R=0 checks cover a helper branch only. Manually supplied progress and ample
return capacity do not establish scheduler or arbitrary placement coverage.

## Save lifecycle

```sh
sh research/save-lifecycle/scripts/reproduce.sh doctor
sh research/save-lifecycle/scripts/reproduce.sh self-test
RUN_DIR="$PWD/.build/save-lifecycle-1" sh research/save-lifecycle/scripts/reproduce.sh check
RUN_DIR="$PWD/.build/save-lifecycle-1" sh research/save-lifecycle/scripts/reproduce.sh verify
```

The [isolated public route](../research/save-lifecycle/README.md) uses GHC
9.6.7 with pinned boot packages, Java 21 and the official TLC v1.7.4 jar
(TLC 2.19). The jar is downloaded tooling, never repository content; its
SHA-256 is `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
The historical GHC 9.6.6 run remains distinct.

Preserve the original finite bounds and TLC `-workers 1 -seed 1 -fp 0`,
record the heap setting, and compare all thirteen typed trace fields.
Expected outcomes are safety/fair-liveness exit0, mutant invariants exit12,
unfair-liveness exit13, and invalid trace exit11, each with its specific
semantic marker. Missing fields, booleans in integer positions, unsupported
optimized Python execution and invalid reference traces must be rejected.

The original fixed model's safety count is 79,227 distinct states. Successful
finite trace matching is not a universal Haskell refinement proof. Liveness
assumes per-request weak fairness, and permits eventual failure as settlement.
Fresh ticket identities, a serialized caller and isolated per-request storage
remain essential assumptions; read the full [limits](guarantees.md).

## Bend

Proposed directory: `research/bend`.

Existing entrypoint: `BEND=/path/to/bend GHC=/path/to/ghc bash experiments/reproduce.sh`. Bend must report 2.0.35; GHC cross-check was recorded with 9.6.6; Node was 24.19.0. The script already accepts BEND/GHC, isolates HOME, and disables telemetry. It writes generated files beside its sources, so a public wrapper should copy inputs into RUN_DIR first or clearly document that behavior.

The Haskell part is optional in the historical script. A Bend-only pass must not report the cross-language check as run. Native C, GPU, and BendTT kernel checking need separate explicit commands/prerequisites and separate statuses. Generating C or BendTT text is not executing it.

Generated `world.mjs`, `world.c`, and `proof.bendtt` can be omitted and regenerated. If runtime-bearing generated code is committed, retain `experiments/BEND-LICENSE.txt` and upstream attribution.
