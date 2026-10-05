# Save lifecycle: optional TLC + real Haskell replay

[日本語](README.ja.md) · [Guarantees and limits](../../docs/guarantees.md#save-lifecycle-with-tla-and-haskell-traces)

This is a reproducible, bounded protocol laboratory. It keeps the frozen Colony
0.2 implementation, TLA+ model, all 13 trace fields, and original fixtures
unchanged. It is separate from the normal game build and is not a proof of the
current game, its UI, or every possible execution.

## Quick start

On Linux/POSIX, install Python 3.10 or later, GHC **9.6.7** (with its bundled
packages), and **Java 21**. No Cabal package installation is needed. The public
runner intentionally uses a newly checked compiler route; the historical
experiment used GHC **9.6.6**, not 9.6.7. Do not report the new run as a byte-for-byte
replay of that historical toolchain.

```sh
# No download or build: validate the frozen input identities and prerequisites.
sh research/save-lifecycle/scripts/reproduce.sh doctor

# Python-only runner/parser tests, including intentional failures and timeouts.
sh research/save-lifecycle/scripts/reproduce.sh self-test

# Choose a new, writable run directory. All outputs/dependencies remain there.
RUN_DIR="$PWD/.build/save-lifecycle-01" \
  sh research/save-lifecycle/scripts/reproduce.sh check

# Recheck input/log/artifact hashes and each named result after completion.
RUN_DIR="$PWD/.build/save-lifecycle-01" \
  sh research/save-lifecycle/scripts/reproduce.sh verify
```

The scripts locate their source directory independently of the caller's current
working directory. `PYTHON`, `GHC`, `GHC_PKG`, and `JAVA` accept individual
executable paths (not shell commands or arguments). `--run-dir PATH` overrides
`RUN_DIR`. Without either, the default is the ignored repository directory
`.build/save-lifecycle`.

`check` rejects a directory that already contains a run. Choose a fresh directory
for each attempt, including after a failed attempt. A directory containing only
`tools/tla2tools-v1.7.4.jar` can be used; this supports offline runs and verified
cache reuse. Existing evidence and source fixtures are never overwritten.

The only download is the official
[TLC v1.7.4 release jar](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4),
which reports TLC 2.19. It is downloaded to `RUN_DIR/tools`, never committed or
installed system-wide. The required SHA-256 is:

```text
936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
```

An existing or downloaded jar with another hash is rejected. A network failure
is a blocker, not a passed check. For an offline machine, download the same
release jar on an authorized connected machine and place it at the path above;
the runner still verifies it. `scripts/fetch-tlc.sh` exposes the fetch/verify step.

## What a complete run establishes

All **42 named subprocess outcomes** must match both their required exit code
and diagnostic markers. A complete run includes:

- Correct-model safety: **583,932 generated / 79,227 distinct / 0 queued states**
- Fair liveness: settlement under per-request weak fairness for storage outcome
  and callback delivery; terminal failure is allowed
- No-fairness control: the expected temporal counterexample, TLC exit **13**
- Epoch, Active, and Persist mutants: the specifically named `NoStaleSaved`,
  `UniqueResponse`, and `NoFalseSuccess` invariant counterexamples, exit **12**
- Replaying all three counterexamples through actual Haskell source and native
  save/load calls, comparing **all 13 fields** at every state
- Matching the deterministic generated counterexamples to the frozen fixtures;
  corrected callbacks reject the final mutant acceptance
- Eight normal Haskell traces, **78 states**, checked against the existing TLA+
  `Init`/`Next` relation; two corrected traces are also checked
- Three mutant Haskell traces rejected by correct `Next` with deadlock exit **11**
- A ticket-freshness probe documenting that reusing an identical completed ticket
  allows an old duplicate to match a new active request
- Missing fields, booleans in integer positions, optimized Python (`-O`), and
  invalid typed reference traces are rejected

The Persist correction is a laboratory caller gate. Its rejected callback is
an observational no-op that is not an enabled model event, so its corrected
trace is **not** falsely advertised as checked by `Next`. The mutant trace is
checked and rejected. The epoch mutant uses serial-only identity matching;
it does not show that a redundant production condition was removed.

The finite bounds remain two epochs, two fresh request IDs per epoch, at most
one edit per epoch, and one active request per epoch. TLC flags are fixed at
`-workers 1 -seed 1 -fp 0`, with a recorded 512 MiB maximum Java heap. Each
subprocess has a 180-second wall-clock timeout; timeout kills its process group.
Python optimization is unsupported because the byte-identical trace bridge
contains assertions.

## Reading and retaining results

`RUN_DIR/evidence.json` contains the new result, actual tool versions/package
list, commands with machine paths replaced by placeholders, exit codes, timeouts,
individual classifications, input/runner hashes, artifact hashes, and limits.
`logs/` holds redacted logs; `work/` holds isolated copies and generated trace
modules; `build/` holds binaries and TLC state; `storage/` holds per-request files.
The source tree and shared Haskell toolchain are never changed by the runner.
The 26-test self-test suite uses disposable temporary directories and does not
require TLC or GHC. After a complete run, the additional 12 verifier controls
check altered copies (wrong invariant/version, missing results/artifacts, changed
core/jar, invalid typed trace, unknown, timeout, and unexpected acceptance):

```sh
python3 -B research/save-lifecycle/tests/verify_receipt_controls.py \
  --run-dir "$PWD/.build/save-lifecycle-01"
```

They leave the original run unchanged, use temporary directories under RUN_DIR,
and write `RUN_DIR/verification-negative-controls.json`.

`passed-scoped` means all intended bounded checks and negative controls matched.
It does not convert expected counterexamples into safety proofs. Individual
outcomes distinguish `expected-counterexample`, `unexpected-acceptance`,
`unknown`, `timeout`, and `tool-error`. A failed or interrupted run does not
produce a passed receipt. The verifier refuses incomplete named-run sets,
changed inputs/runner/logs/artifacts, unexpected exits, missing markers, or a
changed jar.

The committed [public validation receipt](evidence/public-validation.json) is a
separate, sanitized new execution record. It is not a replacement for reproducing
and retaining your own complete `RUN_DIR`. It does not contain the historical
private environment or logs.

## Input identity and boundary

[provenance.json](provenance.json) records byte length, SHA-256, and Git blob SHA-1
for **49 immutable selected inputs** (25 core files, 7 model/config files, 14
fixture files, 2 Haskell drivers, and the trace bridge). They match source commit
`5335bb14f9ca644fbdc62a00be892f33ad590ba6`; the embedded core originates from
snapshot `f6b8c3e5da1e8b577eb8f32ec5bbff63bcceb00e`. Public runners, tests, and these
documents are adaptations with their own hashes, not unchanged historical files.
No historical README, import metadata, machine paths, generated traces, jar,
build cache, or raw historical evidence is exported here.

This is one serialized caller with per-request isolated native storage.
Shared-writer races, queue/coalescing behavior, process/power loss, reconnect,
browser/mobile lifecycle, current production integration, all model sizes,
independent proof certificates, and universal Haskell refinement remain outside
the result. TLC fingerprinting, translation/parser correspondence, compiler,
storage abstraction, and fairness assumptions remain trusted.
