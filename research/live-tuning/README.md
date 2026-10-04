# Validated live tuning: a bounded Haskell change → play prototype

Local research prototype, 2026-10-04. Independent seven-cell route game; **not a modification or benchmark of Paper Circuit, a browser game, or a production feature**. Integrated against main `0dbda032` using the pre-existing GHC 9.6.7 toolchain and only `base`. See [the preceding iteration experiment](../../docs/research-iteration-latency.md).

## Result

A narrow data parameter can change while the compiled host stays running, with typed validation, an explicit session boundary and real game feedback. Ordinary Haskell edits can instead use GHCi reload, which was much faster than build/link/relaunch in this tiny example. Neither mechanism establishes general state-preserving hot reload or browser performance.

Recommendation: use a small validated record for genuinely designer-tunable values; keep algorithms/types as Haskell. Try persistent GHCi for the pure-core edit/observe loop. Do not introduce a configuration language or universal reload framework on this evidence.

## Play it

From this folder:

```sh
export GHC=ghc # GHC 9.6.7 on PATH, or set the executable path
python check.py
.build/game
```

Reach G by entering `r` six times. `l` moves left. `show`, `restart`, `new`, `load FILE`, `quit` are the other commands. The feedback shows the position, moves, phase, active session revision/budget and staged revision/budget, for example:

```text
[.@....G] PLAYING | moves=7 session=r0/8 staged=r1/5
```

To change the budget, write a complete plain-text record and atomically replace the file, then enter `load rules.txt` in the running game:

```sh
printf 'revision 1 moveBudget 5\n' > rules.tmp
mv rules.tmp rules.txt
```

`new` now begins with five moves, making this six-step route unwinnable. A later `revision 2 moveBudget 6` permits an exact final-move win. This intentionally makes the effect visible; validation ensures bounded, well-formed rules, **not solvability or good game design**. No recompilation occurs when loading data. This is explicit reload, not a filesystem watcher; save → load → new is the intended interaction.

## Exact state policy

- Config/Revision/World/Runtime constructors are private; data admission constructs them through a bounded decoder
- Format is exactly `revision INTEGER moveBudget INTEGER` with whitespace separators; no unknown fields, expressions, code evaluation or plugins
- Input is limited to 128 characters; revision is 1..1,000,000,000 and must be strictly newer than the staged revision; budget is 1..30
- A successful load returns one new Runtime value with staged rules replaced and the existing World unchanged
- Bad/malformed/oversized/missing files and stale/duplicate revisions leave **both** staged rules and World unchanged
- `restart` resets position/moves using the active session's original rules
- `new` resets position/moves and adopts the latest staged rules
- No migration, existing-session rebudgeting, undo history or persistence is implied; revisions restart at zero when the process restarts
- Host is a single-threaded command loop. Atomic acceptance means one pure whole-runtime result and one host state replacement, not a multi-process transaction. File producers should use temp-file + rename; an arbitrary concurrent in-place writer is not supported as a consistent snapshot protocol
- File loading supports ordinary local regular text files only. The character limit is not a time limit: FIFOs, devices, slow/network filesystems or adversarial path replacement can block. The CLI does not police arbitrary paths or claim a security sandbox.
- Integer input is parsed into unbounded `Integer`, range-checked, and only then converted to `Int`; see the review regression below.
- Core contains no IO or unsafe functions. Bounded strict file IO and exception handling live in Main.hs

## Verification actually run

`python check.py`: GHC `-O0 -Wall -Werror`, 13 pure checks and real CLI integration checks pass. Pure checks cover state preservation, staged replacement, restart/new boundaries, exact final-move win, loss, terminal/boundary input refusal, stale revisions, malformed/range/oversized records and atomic failure. The CLI check exercises valid load, restart/new, seven failures (invalid, partial, oversized, missing, duplicate, positive overflow, negative overflow), unchanged state after every failure, recovery via newer valid data, final-move win and repeated terminal input.

`check.py` writes the actual integration transcript to ignored `.build/host-check.log`; generated logs and executables are not distributed. There is no browser UI, screenshot, Wasm test, cross-platform test or Paper Circuit law-suite claim.

## Repeatable benchmark

```sh
python bench.py
# optional: SAMPLES=15 GHC=/path/to/ghc python bench.py
```

The harness copies source into a fresh temporary directory, deletes that scratch directory on completion, and never edits the deliverable source files or a repository; it replaces its own measurement outputs. It atomically saves each edit, then starts the clock. Seven samples alternate budget 6/7. Every measured changed-run result checks the exact expected changed budget after a **new session and one accepted rightward input**, forcing the whole rendered board string through stdout. Data revisions differ, but board position/moves/outcome are equivalent. GHCi is an existing process using bytecode; native timing includes compiler invocation, compilation/linking and a new process; data timing uses an existing compiled host. This compares user workflows with different costs, not equal compiler operations.

Post-format integration rerun on a Linux executor, GHC 9.6.7, `-O0 -Wall -Werror`. The pinned repository Ormolu 0.9.0.0 changed source layout; tests and all timings below were rerun against the distributed source hashes in `measurements.json`:

| Operation | n | Median ms | Range ms |
|---|---:|---:|---:|
| Data saved → read/validate/stage/new/input/board output | 7 | 0.284 | 0.265–0.443 |
| Haskell saved → persistent GHCi reload/new/input/board output | 7 | 58.820 | 45.264–86.604 |
| Haskell saved → warm compile/link/launch/new/input/board output | 7 | 960.813 | 873.105–1167.488 |
| Unchanged warm native build only | 7 | 170.005 | 138.738–261.584 |
| Cold-artifact native probe build only | 1 | 929.183 | single observation |
| Interactive host initial build | 1 | 1019.678 | single observation |
| Interactive host launch → initial board | 1 | 3.702 | single observation |
| GHCi startup/load → first accepted input board | 1 | 234.340 | single observation |

“Cold” means empty output artifacts with the compiler already installed; OS/page caches were not flushed. Timings exclude human typing, file save duration, editor propagation, terminal painting, browser input/render and UI first frame. The sub-millisecond data result is pipe-observed machine latency, not perceived human latency. Compilation and linking are combined, not separately instrumented. No dependencies downloaded. Sequential samples on one host are illustrative, not portable speed promises. Full sample outputs, compiler/OS/CPU, UTC timestamp and source hashes are in `measurements.json`; exact commands and protocol are in `bench.py`. Scratch benchmark builds are removed; local check executables remain under ignored `.build/`. The earlier corrected, pre-format run observed medians of 0.227 / 43.610 / 863.988 ms for data / GHCi / native (n=7 each). Those are historical observations, not measurements of these formatted bytes; the rerun above is the reproducible source-matched record.

## Official sources checked

- [GHC 9.6.7: changes and recompilation](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html#making-changes-and-recompilation): `:reload` recompiles as needed, reusing the recompilation checker
- [GHC 9.6.7: loading compiled code](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html#loading-compiled-code): normal GHCi source handling is bytecode, with compiled-code options. The prototype uses the bytecode path; it does not benchmark object-code GHCi

These docs support the mechanism, not the local numerical results or a guarantee of preserving running game state. All data-admission/state semantics above are explicit prototype choices, supported by its source and tests.

## Review regression and prevention

Independent review found that parsing a budget directly as `Int` allowed the positive literal `18446744073709551622` to wrap to 6 on this 64-bit host before the range check. The corrected decoder explicitly parses both numeric fields as `Integer`, checks the allowed interval, and only then narrows the validated budget to `Int`. Positive and negative overflow literals (including 32-bit-size cases and very large values) now have rejection/state-preservation regression checks; the CLI tests cover the reported positive literal and a negative overflow literal. Negative signs are already disallowed by the grammar. Tests and all benchmark samples were rerun after the fix; measurement hashes describe the corrected source.

Prevention rule: validate numeric input in an unbounded representation before any bounded conversion. Successful parsing into a machine integer does not establish that the original textual value was in range.

## Reading path, ownership, and provenance

Start with `Game.hs`: `Runtime` contains staged `Config` and an active `World`.
`admit` decodes a complete record, rejects non-newer revisions, and returns a
whole replacement runtime with the same world. `move` spends one move only for
an accepted in-bounds step; reaching cell 6 wins even when the last move is spent.
Then read `Main.hs` for bounded file reading and the command loop, `Tests.hs` for
13 pure checks, and `check.py` for the real CLI interaction. `Probe.hs` is only
the native benchmark observation entrypoint; `bench.py` contains exact commands.

Human intent → AI judgment → repeatable tools remains the ownership order.
A human chooses which parameter should be tunable and when it takes effect;
AI reasoning chooses the smallest boundary, and tests exercise that choice.
This evidence motivates the next change → play experiment, not a framework.
Measure a real game's data edit, GHCi edit, and native edit before adopting a
workflow; browser/Wasm and subjective editor/play latency remain unmeasured.

All source and harness files in this directory were newly authored for this
research and are distributed under the repository [MIT license](../../LICENSE).
No external game's implementation or assets were copied. The linked GHC manuals
are mechanism references, not incorporated code. Source formatting follows the
repository's pinned formatter and `formatter.json` includes this directory.
