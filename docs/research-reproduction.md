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

Each linked experiment README is the canonical current-status page. Read it
before installing anything. It identifies
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

## Commands and current status

The experiment READMEs linked above are the canonical source for each route's
commands, prerequisites, current receipt and remaining limits. This guide owns
selection and adaptation, rather than repeating result counts or install recipes.
The [guarantee catalog](guarantees.md) explains what each claim means and trusts;
[the roadmap](roadmap.md) lists future experiments.
