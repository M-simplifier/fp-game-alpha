# Measured Haskell iteration and Afterlight parity

Measured 2026-10-04 against public source `9fd07cb3b34d7bcb04602070def197e68373099f`;
reviewed test optimization integrated after `d666a504c6a48672740f75f727fdb78158544e37`.
The priority is shorter checked iteration without weakening guarantees. These are
bounded observations, not a general hot-reload architecture or promised CI speedup.

## Locate the cost before changing the build

In [PR #22's successful run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37211157907),
the Afterlight job took 684 seconds. Its check-core step envelope was 579.8 seconds;
parity RUNNING to PASS was 513.5 seconds (88.6% of that envelope). Before-parity
setup, downloads, compilation and linking shared approximately 54.9 seconds.
Timestamp boundaries include runner/process gaps. Compiled-artifact caching cannot
remove the dominant observed test runtime. This is one PR run, not a CI distribution.

The route already advances both simulations incrementally. Profiling identified
repeated structural equality of unchanged 280,361-cell terrain maps, three times
per frame: complete World, exact SceneView and interpolated SceneView. This is
O(frames × terrain size), not demonstrated quadratic replay cost.

## Reviewed test-only optimization

The long IO route now retains one successful structural-equality certificate for
an actual pair of terrain objects. Both evaluated maps must match their respective
StableName identities for a cache hit; hashes, revisions, sizes and edit lists are
never sufficient. A miss performs complete structural Map equality. Strong
references retain both certified maps; only one successful pair is kept.
[The official StableName contract](https://hackage.haskell.org/package/base/docs/System-Mem-StableName.html)
permits identity equality to establish sameness; unequal stable names need not mean
unequal values, which is why a miss still compares the full maps.

World and enclosing SessionView derived equality still check every non-terrain
field, including future fields. Exact and interpolated terrain are certified
against their own oracle counterparts. Terrain edits invalidate identity hits;
mismatches never replace the successful certificate. Cue ordering, pilot checks,
failing-frame diagnostics, generated pure cases, complete WAV comparisons,
milestone saves, cross-decodes and resumed traces remain unchanged.

| Full local suite | Elapsed | Before tour | Tour and milestone saves |
| --- | ---: | ---: | ---: |
| Unchanged cached baseline executable | 763.82 s | 8.03 s | 755.79 s |
| Optimized candidate | 38.54 s | 8.88 s | 29.66 s |

Both passed 5,580 frames, 9,067 ticks, terrain revision 10 and Pilot 4 0.
All 162 original assertion/milestone output lines were identical in order. The
candidate adds 22 cache assertions covering left/right operand changes, changed
terrain with unchanged revision, reconstructed equal maps, scalar changes, exact
and interpolated views, and explicit garbage collection. QuickCheck seed 20261003
and all 160 generated cases remain unchanged. Independent static review found no
blocking issues; its regression-hardening suggestions preceded the final run.

These are one-shot Linux x86_64 observations on an Intel Xeon Platinum 8573C with
GHC 9.6.7 and -O2, not statistical benchmarks. Other local compilation/execution
overlapped the runs. The baseline reused an existing executable; the candidate
rebuilt test/oracle modules against byte-identical cached core/dependencies.
A 240-frame diagnostic measured full World/SessionView equality envelopes of
9.981/20.222 seconds before and 0.270/0.003 seconds after. Laziness can charge
transition/projection work to equality; these are forced-operation envelopes,
not allocation or cost-centre profiling. Prefixes do not replace the full suite.
Raw executor logs are not published with this source note. No public CI timing
for this successor, clean dependency rebuild, native graphical or browser result
is claimed here.

Historical FORMAT-MANIFEST hashes remain intact. The separate
[TEST-OPTIMIZATION-MANIFEST](../references/afterlight/docs/TEST-OPTIMIZATION-MANIFEST.json)
links the previous formatted Parity hash to the exact semantic successor and
locks its helper and Cabal registration. The source audit consumes that record
explicitly; its fixed allowlist cannot exempt runtime or oracle files. The
BASELINE-MANIFEST and all 18 frozen oracle hashes remain independently checked.

Reproduce from the repository root with the documented existing toolchain:

    python references/afterlight/scripts/test-audit-source.py
    python references/afterlight/scripts/audit-source.py
    python references/afterlight/scripts/check-core.py --download

The explicit download option fetches hash-pinned source dependencies, not a
compiler. Run the previous public commit in a separate worktree with the same
toolchain/flags to compare; do not replace frozen oracle modules or reduce tests.
Record host load, cache state, elapsed boundaries and complete assertion output.

## Smallest next playtest experiment

A separate six-module Paper Circuit native probe, using an already-installed
GHC 9.6.7 with -O0, observed 1.729 s for empty-output compile/link, 0.151 s for
an unchanged build, and 1.128 s after changing the Haskell move budget 18 to 19.
The textual observations changed from (18,Playing,7316) to (19,Playing,7316),
with executions of 0.012/0.013 s. A forced no-code check took 0.301 s. A combined
GHCi startup/load/evaluate/unchanged-reload/evaluate took 0.499 s; that is not
reload latency alone. One sample each; no browser first-frame, input response,
Wasm build, changed-code GHCi reload or full law-suite measurement is implied.
The rule edit was restored byte-for-byte. Rules are Haskell source, not evidence
of external-data hot reload.

Next, compare native incremental build, separately timed persistent GHCi reload,
and the existing Wasm path against the same changed-rule/scripted-action sequence.
Keep fresh or explicitly replayed sessions and source-fingerprint checks; a cache
hit is acceleration, never proof of validation. Measure host first-frame/input
response before choosing a workflow. Do not build a new DSL on these samples.
See the [GHC 9.6.7 GHCi guide](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html)
and [Cabal component commands](https://cabal.readthedocs.io/en/3.12/cabal-commands.html).
