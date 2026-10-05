# Guarantees and their boundaries

This alpha separates a small pure Haskell transition core from games, platform adapters, and research examples. Purity makes state transitions easier to inspect and replay. It does not establish termination, bounded memory, overflow safety, storage durability, cross-platform determinism, or a correct user interface.

The historical results below were recorded on 3–4 October 2026 and apply to
the named source versions and toolchains. Original sources and optional isolated
public runners are now included. New reruns are identified separately; neither
source recovery nor a toolchain build counts as a checker pass. The
[historical evidence summary](evidence/historical-guarantees.json) separates
curated past results from new runs. The
[reproduction guide](research-reproduction.md) gives current and planned
entrypoints and opt-in toolchain boundaries; the [reference catalog](research-references.md) supplies primary
material.

## Reading a result

- **Checked, scoped:** the stated checker or solver discharged the stated obligations under its assumptions
- **Finite test passed:** the listed inputs matched; untested inputs are not covered
- **Counterexample observed:** a concrete failure or deliberately weakened model was reproduced
- **Tool error or blocked:** no mathematical conclusion follows from an unsuccessful tool invocation
- **Source observation:** code was inspected, but the corresponding toolchain was not executed
- **Not run:** the experiment was not performed

A rejected mutant is useful evidence that a check detects that particular defect. An aggregate PASS can mean that the experiment reproduced its expected counterexamples; it must not be read as “everything is safe.” Replaying SMT with the same solver is reproducibility evidence, not independent proof-certificate checking.

## Quantity contracts on a real Haskell module

**Recorded result:** LiquidHaskell reported SAFE with 25 constraints for six selected binders from the frozen colony 0.6 `Colony.Units` module. Six deliberately broken implementations were UNSAFE. The original Haskell source bytes, types, imports, roles, instances, and function bodies were retained, with refinement comments appended.

**Selected source-only result:** `research/quantity/check.py check` passed
locally with GHC 9.6.7 on Windows: eight intended type errors, two positive
compilations, and 631,024 finite oracle rows on each of the frozen and
annotation-only modules. It does not rerun the LiquidHaskell checker or its
six mutants. Those now have a separate [recovered checker route](../research/quantity/lh-checker/README.md). The source-only result is recorded separately in
[Windows quantity evidence](evidence/quantity-windows.json); cross-OS CI is
tracked in the verification record.

**Public checker rerun:** the exact pinned GHC 9.6.3/LH/Z3 stack now reports
SAFE25 for the good module and UNSAFE for all six original mutants. The
[new quantity receipt](../research/quantity/lh-checker/evidence/linux-20261005.json)
records seven fresh initialization-bearing solver streams with 175 exactly
replayed responses (11 SAT / 164 UNSAT), and eight UNSAT independent models
plus one SAT cast-before-check witness. These are new-run counts; the historical
14-stream/350-response record below is not relabelled as this execution.
The caller terminates interactive capture children, so captured solver exit
stamps are absent; fresh replay exits 0, complete response counts and exact
stdout equality are checked separately.

The selected binders are `quantityMax`, `mkQty`, `qtyValue`, `zeroQty`, `addQty`, and `subQty`. Let `M = 9,000,000,000,000`.

- `quantityMax` is exactly M; `zeroQty` is exactly zero
- `mkQty n` succeeds exactly when `0 <= n <= M`; its successful value is exactly n
- `qtyValue` returns the integer corresponding to the stored quantity representation
- For inputs explicitly assumed to be within 0..M, `addQty a b` succeeds exactly when `a+b <= M`, and returns exactly a+b
- For the same bounded-input assumption, `subQty a b` succeeds exactly when `b <= a`, and returns exactly a-b

This is selected-binder checking, not a whole-module or whole-game proof. The unrestricted whole-module attempt ended in stack overflow. Read/Binary-related binders appearing in a dependency closure do not establish serialization correctness. Exact failure strings were tested separately rather than specified by these refinements.

The implementation stores Int64 but checks bounds before conversion and performs addition/subtraction through Integer. The proof still trusts GHC, LiquidHaskell 0.9.6.3.1, liquidhaskell-boot 0.9.6.3, liquid-fixpoint 0.9.6.3, imported arithmetic/conversion specifications, the translation to SMT, and Z3 4.15.1. In particular, the generic imported conversion assumptions are not a proof of arbitrary out-of-range machine-integer casts.

Separate evidence:

- 631,024 runtime rows matched an independent arbitrary-precision Python oracle, with zero mismatches; the annotated and original versions produced identical output on those same rows
- Eight negative compilation examples rejected cross-unit operations, inappropriate coercions, or access to the hidden constructor
- Eight independent integer/bitvector queries returned UNSAT; an intentionally unsafe cast-before-check design produced a SAT witness
- Fourteen complete solver streams were replayed, matching 350 responses

The runtime counts include repeated inputs from different test classes. Static unit protection relies on both a nominal role and a hidden constructor; a synthetic example with an exposed constructor demonstrated why the nominal role alone is insufficient. Unsafe operations, unverified callers, deserialization, and dynamic `Resource`/`Qty StockUnit` correspondence are outside this result.

## LiquidHaskell arithmetic and a failed division contract

**Public rerun:** all twelve original diagnostics and the finite runtime bridge
now reproduce on the exact GHC 9.6.3 / LH 0.9.6.3.1 / Z3 4.15.1 stack.
The [new execution receipt](../research/liquidhaskell/evidence/linux-20261005.json)
records four SAFE observations, eight target-specific UNSAFE controls,
25 quantity pairs / 50 comparisons and 5,016 cancellation triples.
The strict soundness gate returns exit 1: reproduction succeeds while division
soundness remains failed. The [optional route](../research/liquidhaskell/README.md)
keeps these outcomes separate and does not assess a newer LH release.


The smaller Integer-only `Contracts.hs` example was SAFE with 23 constraints on GHC 9.6.3 / LiquidHaskell 0.9.6.3.1 / Z3 4.15.1. Incorrect addition, unjustified nonnegative subtraction, always-failing checked addition, a call with an impossible precondition, a partial pattern match, and nondecreasing recursion were rejected. An impossible input precondition itself was SAFE, illustrating vacuous truth.

**The division diagnostic failed its intended soundness test.** Under the satisfiable input condition `x == 0`, a deliberately false postcondition claimed that `x div 2 == 99`. The pinned checker accepted it as SAFE; ordinary Haskell execution returned 0. Generated constraints and complete solver traffic showed contradictory imported division premises. Nonzero-dividend and no-division controls were rejected.

Consequently the SAFE result for the division-dependent cancellation example is **withheld as a usable guarantee**. The SBV result below stands on its own separate model and assumptions.

Source inspection on 4 October 2026 found a zero-boundary contradiction still present in Hackage 0.9.14.1.1, release v0.9.14.1, and develop commit `952f02cfa4eb94f194e5b72706e55ce4fc1bcbb6`. The relevant newer clause requires `v < x` when `1 < y && x >= 0`; combined with nonnegativity, x=0 and y=2 imply both `v < 0` and `v >= 0`. This is an **unexecuted source-level inconsistency candidate** for those versions, not a runtime reproduction on a current compiler. See the [pinned source](https://github.com/ucsd-progsys/liquidhaskell/blob/952f02cfa4eb94f194e5b72706e55ce4fc1bcbb6/src/GHC/Real_LHAssumptions.hs) and [related issue discussion](https://github.com/ucsd-progsys/liquidhaskell/issues/2285#issuecomment-2122794785).

## Cancellation arithmetic with SBV

**Public rerun:** the recovered, byte-identical original `Proof.hs`, `Replay.hs`
and frozen 0.4 source passed on GHC 9.6.7 / Cabal 3.12.1.0 / SBV 10.12 /
Z3 4.15.1. The isolated [public runner](../research/sbv-cancellation/README.md)
requires the full six-UNSAT/three-SAT map, finite bridge/replay counts below,
and nine complete same-Z3 solver-stream replays. The original executable's
bounded fallback cannot satisfy this public general-result gate. The new
[validation receipt](../research/sbv-cancellation/evidence/public-validation.json)
binds actual versions, named outcomes and input/output hashes.


**Recorded result:** four general SInteger queries and two separately bounded queries returned UNSAT with SBV 10.12 / GHC 9.6.6 / Z3 4.15.1. Three negative controls returned SAT. No query in the recorded final run returned unknown.

For nonnegative total Q, positive required progress R, and `0 <= p <= R`, define `L = floor(Q*p/R)` and `refund = Q-L`. The general queries establish bounds, conservation, monotonicity in p, and equality of the aggregate formula for eight nonnegative slots whose sum is Q. The eight-slot result is an algebraic equality for fixed arity, not induction over arbitrary lists and not proof that the application groups resources correctly. Conservation is also an identity following from the refund definition.

The legacy per-lot formula has a concrete counterexample: eight lots of one unit at half progress lose zero under per-lot flooring but four under aggregate flooring. Removing `p <= R` allows negative refund. A separate Word64 example demonstrates overflow in multiplication; mathematical-integer results do not certify Word64 arithmetic.

The actual frozen 0.4 helper matched 36,400 concrete symbolic evaluations. A direct-source replay exercised 1,412 cancellation transactions with 127,011 assertions. These cover a directed finite fixture suite, including all 128 positive ordered compositions of Parts8 at 11 progress boundaries, plus four baselines. Metal partitions rotate through three selected patterns rather than their full Cartesian product.

The transaction tests supply progress directly and ample return capacity. They do not establish scheduler timing, arbitrary capacity/placement feasibility, general FEFO correctness, all rulesets, save correctness, or universal refinement of the Haskell implementation. Solver, compiler, SBV, translation, and the stated model/source mapping remain trusted.

## Save lifecycle with TLA+ and Haskell traces

**Public rerun:** the recovered original model, 13-field bridge, fixtures and
frozen 0.2 Haskell source are included with an [isolated runner](../research/save-lifecycle/README.md).
A new GHC 9.6.7 / Java 21 / pinned TLC 2.19 run reproduced the finite safety
counts, fair liveness, three model/Haskell mutant correspondences, 78 normal
corpus states, invalid-trace rejections and parser controls described below.
The experiment's full [public validation receipt](../research/save-lifecycle/evidence/public-validation.json)
identifies the exact runner/input hashes and scope.


**Recorded result:** TLC 2.19 from release v1.7.4 exhaustively explored a fixed model with two epochs, two fresh request IDs per epoch, at most one edit per epoch, and one active request per epoch. Safety exploration completed with 79,227 distinct states, 583,932 generated states, and no queued states remaining.

The invariants cover stale success/saved status, successful persistence, duplicate success acceptance, snapshot revision matching, active-request correspondence, and state domains. Three weakened protocol models produce stale-callback, duplicate-success, and success-before-persist counterexamples.

The Haskell laboratory caller imports the frozen 0.2 save API and uses real file save/load operations. The three model counterexamples matched all 13 observed state fields in the corresponding mutant replay. Eight normal Haskell traces, 78 states in total, were accepted by the model's existing Init/Next relation; three mutant traces were rejected. These are finite trace correspondence results, not a refinement proof for every execution.

Liveness passed under per-request weak fairness for eventual storage outcome and callback delivery. Removing fairness produced the expected liveness counterexample. The claim is eventual settlement to success or failure, not successful saving or a response-time bound.

Fresh complete ticket identity is a required assumption: reusing an identical completed ticket let an old duplicate match a new active request in a direct API probe. The persist mutant is stopped by a laboratory caller gate; it is not evidence that the core checks storage phase itself. The epoch mutant weakens complete identity comparison to serial-only comparison rather than deleting a redundant condition in production code.

This experiment uses one serialized caller and isolated storage directories per request. Shared-writer races, queue/coalescing behavior, process/power failure, reconnect, real UI behavior, browser storage, mobile suspension, and arbitrary model sizes remain outside scope. TLC fingerprints, parser/model correspondence, GHC, and storage abstraction remain trusted.

## Bend and Haskell comparison

Bend 2.0.35 generated sequential JavaScript that matched a Haskell reference on 4,907 complete final-world traces and 17 balanced-tree map/reduce sizes. Rerun and split/resume checks agreed. Three authored laws were accepted by the ordinary Bend checker; five deliberately invalid type/ownership/law/termination examples were rejected. These are finite differential tests and ordinary-checker observations, not end-to-end compiler verification or performance measurements.

- BendTT kernel verdict: blocked because the required Lean v4.34.0 was absent
- Native CPU execution: not completed; Clang was absent and the fallback GCC build rejected Clang-specific syntax
- GPU execution and performance: not run
- Array bounds: the index-wrap example is observed behavior, not a rejected out-of-bounds access

Generated JavaScript/C contains upstream runtime code with Apache-2.0 licensing. Bend 1/HVM2 and Bend 2 have different implementations and guarantees; do not combine their claims. The [pinned BendTT documentation](https://github.com/bendlang/bend/blob/79df8d9c40722ee9507a1e253f283b51025f9d6c/bend2/docs/BendTT/main.typ) also states limits around the surrounding translation/runtime pipeline.

## Platform maturity and remaining work

These records show particular Linux x86_64 toolchains and, for Bend, sequential JavaScript running in Node. They do not certify a browser shell, Windows, macOS, native mobile, GPU, or all GHC backends. Runtime adapters need their own build, input, suspension, save/recovery, and device QA evidence.

The earlier guarantee-program documents are a research plan, not evidence that every proposed technique was implemented. Their “not yet run” entries for SBV, LiquidHaskell, and TLC are superseded only by the narrow experiments above. Concurrency simulation, distributed protocols, arbitrary-size refinement, broad cross-backend parity, and independent proof-certificate checking remain separate work.

For learning, start with finite replay and a deliberately broken implementation, then read the quantity contracts, cancellation model, and save protocol. Ask of every stronger claim: what is quantified, which source was checked, how is the model connected to execution, and what remains trusted? The reference catalog gives primary material for pursuing those questions.
