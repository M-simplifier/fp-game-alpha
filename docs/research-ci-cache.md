# Editor CI dependency-cache experiment

The first bounded change caches Linux editor dependencies and cancels superseded runs of the same pull request. It keeps every validation job and test. [PR #27](https://github.com/M-simplifier/fp-game-alpha/pull/27) merged as `9d924e372f0b94bafa532db475c5a9255d12c72c`.

## Scope and isolation

The archive contains the Cabal dependency store and npm's integrity-checked `_cacache`. Project build outputs, `node_modules`, vendor source trees, compiler installations and the final editor executable remain uncached. Every run still executes `npm ci`, TypeScript checking, the native build and editor tests. Afterlight archive validation and independent-workspace tests are unchanged.

Only a main push whose editor checks pass can save through this workflow. Pull requests restore but do not save. GitHub additionally scopes PR caches to their merge refs, preventing main from restoring them. No deployment job restores this archive, and no PR deployment permissions were added. Compiled dependencies are executable input: they must remain trusted-main-produced; a cache hit is not validation.

Keys include OS/architecture, hosted-image version, resolved GHC/Cabal versions, actual Node/npm versions and a hash of Cabal manifests/project/freeze, npm manifest/lock, editor build scripts and the workflow. Optimization settings and the Hackage index-state are covered by the project/freeze files. There are no broad fallback keys. Image or dependency changes intentionally produce a cold build.

Concurrency groups use workflow, event and PR number; main receives a unique run-ID group. Thus superseded PRs can be cancelled without the single-pending-run rule discarding main validation. Existing deployment serialization and the current-main guard remain intact.

## Cold PR evidence

[PR run 37218861958](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37218861958) passed all six validation jobs. Its [editor job](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37218861958/job/111484904895) explicitly logged a cache miss and skipped the main-only save.

Whole-second GitHub step timestamps:

| Measurement | Cold PR |
|---|---:|
| Editor job elapsed, excluding queue | 395 s |
| Haskell setup/index update | 111 s |
| Dependency-cache restore attempt | <1 s |
| npm dependency installation | 6 s |
| Native build | 244 s |
| Editor tests | 23 s |

The exact requested key was:

```text
editor-deps-v1-Linux-X64-ubuntu24-20260927.320.1-ghc9.6.7-cabal3.12.1.0-nodev22.23.3-npm10.9.9-e1a803cfe9ac2f77ad4223d942c6b19d3217346d09ff2dece68b04d9340c25a2
```

## Main population and warm trial

The [first main editor job](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37219615467/job/111487119579) succeeded after another explicit miss, then saved the exact key above. It uploaded **46,160,387 bytes (44.02 MiB)**. The save action's log envelope was **2.32 s** (17:18:52.3285085–17:18:54.6440936 UTC); the jobs API rounds that step to 2 s. Main editor elapsed was 395 s: setup 110 s, npm install 6 s, native build 245 s and tests 23 s. All 61 editor tests passed, with none skipped.

This proves cold population, not warm reuse. No warm speedup has been measured. This documentation-only change is intended to exercise the same dependency key without a dummy commit; its CI must still run all checks. Record the restored key, archive size, restore/save overhead, native build and test durations, and runner image before comparing samples.

The previous [main baseline](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37217414362) took 407 s for the editor, while Windows validation took 462 s. Reducing editor work need not shorten the full workflow's critical path. Cross-platform compiler setup is a separate, still-unoptimized cost.

The runner also warned that the pinned cache v4 and existing checkout v4 actions target deprecated Node 20 and were forced onto Node 24. Both cold restore/save steps succeeded, but a separately verified current-runtime action-pin update is future maintenance, not a prerequisite for this warm trial. This experiment does not establish ongoing compatibility.

## Sources

- [Official actions/cache v4.3.0](https://github.com/actions/cache/releases/tag/v4.3.0), pinned to verified tag commit `0057852bfaa89a56745cba8c7296529d2fc39830`; split restore/save actions
- [GitHub cache isolation](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching) and [concurrency semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
- [Pinned Haskell setup outputs](https://github.com/haskell-actions/setup/blob/0f8e8c99d88aeb3fbfd523f1ef2c6f762d10d64d/action.yml), [Cabal builds](https://cabal.readthedocs.io/en/3.12/nix-local-build.html), [npm cache integrity](https://docs.npmjs.com/cli/v11/commands/npm-cache/)
