# Recovered development-loop evidence

## Windows native entry

The [Windows native measurements](../evidence/native-development-windows.json)
are new 2026-10-07 observations using `tools/dev-native.ps1`, the existing
optimized Cabal project and cached dependencies. Each case was sampled once:

| Case | Command to actual GPU capture |
| --- | ---: |
| Existing build command, then separate launch | 3.66 s |
| One command, unchanged source | 4.01 s |
| Settlement food objective edited in JSON | 6.39 s |
| Visible Haskell objective label edited | 10.19 s |
| Compile failure | No launch or capture; nonzero exit in 4.52 s |
| Corrected source after failure | 7.32 s |

The new entry removes manual build/run coordination; this comparison establishes
no compiler speedup. Native input used synthetic pointer/key replay through the
ordinary hit testing and game commands, with an opt-in hidden GPU window. Every
successful run started paused, accepted time-start input and advanced real ticks.
The JSON food objective changed from 10000 to 11000 g with a changed pack identity
and unchanged EXE. The Haskell edit rebuilt the view and appeared in the capture.
The failed build preserved the previous EXE and never reached launch. Retry
rendered the corrected source. The temporarily edited source and JSON were
restored byte-for-byte without overwriting a concurrent editor's change.

Fifteen new development checkpoints were retained. Earlier development saves,
the owner's installed EXE and every existing owner-save file were unchanged.
The native store regression suite also checks immutable paused branches and
stale preview/confirm rejection. These measurements establish neither OS input
feel nor owner enjoyment, and do not reuse Linux timing data.

## Recovered Linux evidence

The unpublished working environment was replaced after the 2026-10-06 development
checks. The implementation was recovered and checked against recorded source identities. The final supervisor and DevMain match their previously recorded SHA256
hashes; the host matched its recorded intermediate hash before the recorded
quiet-startup patch was reapplied. All 47 relocated Colony modules remain
byte-identical to the original base.

The original full timing JSON and compiler logs could not be recovered. The
[transcript-derived timing summary](../evidence/development-iteration.json)
preserves recorded results and explicitly identifies that gap. It is not a
replacement for the missing raw samples. The original full patch hash is not
claimed for this recovery.

## Historical observations

The recorded native watcher policy-edit run had 20 samples, median 754 ms and
p95 884 ms from atomic source save to fresh paused HTTP-ready. The normal native
build/list-bin/launch comparison had median 7.934 s and p95 9.828 s from detection
to HTTP-ready. Those watcher timings preceded final supervisor hardening and
adoption of the development interface setting.

With package-wide `-fomit-interface-pragmas` after component `-O2`, the separate
20-sample Needs edit run recorded median 7.130 s and p95 9.131 s from save to
HTTP-ready. Only Colony.Needs recompiled; health alternated 999/1000 and authorities
were unique. The normal-interface baseline was intentionally stopped after nine
complete samples: median 84.955 s, range 74.031–114.596 s. No percentile is claimed
for that incomplete baseline. Other builds ran concurrently, so these observations
are not a controlled causal speedup or a final-code latency guarantee.

Three 1,200-tick trials using an actual active hour-36 checkpoint and the selected
development profile recorded means 10.96/12.34/11.97 ms, p99 values
23.18/43.57/28.27 ms, and 2/9/4 ticks above 50 ms. They support a development tradeoff,
not production equivalence or a strict per-tick deadline. The original optimized
acceptance project retains its previous flags.

## Verification boundary

Recorded historical verification included 12 real native/GHCi checks, 24
deterministic lifecycle/artifact cases, 20 same-process host restart cycles,
five production smoke suites, native HTTP acceptance and Node protocol tests.
[Recovery and correctness status](../evidence/development-correctness.json)
distinguishes those historical records from checks actually repeated after
recovery. Missing original logs are not presented as recovered files.

Actual browser rendering, keyboard and pointer acceptance remain unrun. HTTP
readiness and accepted HTTP commands do not establish browser acceptance. POSIX
process locks also do not prove exclusion between two manual host starts inside
the same GHCi process; the supported supervisor serializes those lifetimes.
An asynchronous host-startup exception may still surface as a safe generic
readiness timeout instead of its underlying cause.

## Reproduction

Use [the native development command](DEVELOPMENT.md). The Python programs are
independent test/measurement drivers, never the operational watcher. Run
source-mutating checks only in an isolated, quiet worktree:

```sh
python3 references/red-dune-live/tools/test_devloop.py --binary /path/to/red-dune-devloop
python3 references/red-dune-live/tools/test_devloop_lifecycle.py --binary /path/to/red-dune-devloop
```

Rebuilding recovered source and running these checks establishes new evidence;
no historical timing distribution should be attributed to that new run.
