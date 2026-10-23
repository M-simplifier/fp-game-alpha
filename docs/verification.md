# Find and read verification evidence

A result belongs to the source revision, inputs, toolchain and environment that
actually ran. A configured workflow, recovered source or successful tool build
is not a passing execution of the game or checker.

## Check the current checkout

Use [native tooling](native-tooling.md) for bootstrap, build/test commands and
its required CI contract; use [tooling](tooling.md) for saved-source inspection
and [editor setup](editors.md) for actual editor consumers. The
[core workflow runs](https://github.com/M-simplifier/fp-game-alpha/actions/workflows/ci.yml)
and [native-tooling runs](https://github.com/M-simplifier/fp-game-alpha/actions/workflows/native-tooling.yml)
show results for exact commits. Inspect those results before claiming a platform
pass; one job does not certify another host or optional research toolchain.

The [transition laws](../libraries/game-transition/test/Laws.hs),
[arena laws](../libraries/game-arena/test/Laws.hs) and each reference's tests
are the maintained behavior checks. Start from the affected game's README for
its build, API and host checks rather than copying a historical command here.
The [acceptance criteria](acceptance.md) distinguish generated-game continuation,
editor integration and actual player experience. For formal experiments, use
[research reproduction](research-reproduction.md) and read their
[assumptions and failure cases](guarantees.md).

## Dated records

These receipts retain earlier observations. They are not new runs of this
checkout, and the commands embedded in them may describe retired entrypoints.

| Record | What it records |
| --- | --- |
| [Windows development](evidence/windows-development.json) | Generated terminal game, feature edits, save/load and independent relocation |
| [VSCode](evidence/vscode-windows.json) and [Neovim](evidence/neovim-windows.json) | The tested Windows saved-source query/diagnostic paths |
| [Native tooling on Linux](evidence/native-tooling-linux.json) and [CI](evidence/native-tooling-ci.json) | Native command and consumer executions at their recorded revisions |
| [Windows quantity](evidence/quantity-windows.json) | Finite runtime/oracle comparison and GHC API checks; no LiquidHaskell or Z3 run |
| [Historical research](evidence/historical-guarantees.json) | Curated 3–4 October 2026 checker, model and counterexample results |
| [Linux research integration](evidence/formal-research-linux-20261005.json) | Separate 5 October 2026 public-runner results |

The [original chronological verification record](https://github.com/M-simplifier/fp-game-alpha/blob/06923e727c0229eb36daeba6bab789ca32333406/docs/verification.md)
preserves the earlier per-game runs, CI links, commands and failures. In
particular, an unsuccessful HLS probe supplies no hover/diagnostic success, and
finite pure-core traces supply no graphical or device-performance result.

Reusable causes and repairs live in [failure prevention](failure-prevention.md):
constructor/update loopholes, numeric overflow, compiler-backed module queries,
portable source selection and process ownership. The current setup recipes live
with their tools. Keep a new run's logs and source identities separate from
these historical records; never update an old receipt to imply it just passed.
