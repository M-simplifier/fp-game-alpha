# Checked live-campaign acceptance

Recorded 2026-10-04 on native GHC 9.6.7, Linux, `-O2 -Wall -Werror`, one RTS
capability. This is source-informed scripted engineering acceptance. It is not a
blind AI-player trial, a human enjoyment study or proof of novice completion rate.

## Actual endings

Both runs started from their authored opening world. The player commands configured
survival policies, queued the reserve warehouse, then resumed. Every subsequent
production, delivery, repair, roster and construction change used ordinary kernel
commands and elapsed ticks. No test grants or direct world mutation completed an
objective.

| Evidence at the ending | Settlement | Recovery |
| --- | ---: | ---: |
| Elapsed game hours | 66 | 42 |
| Minimum health, all 40 residents | 1000/1000 | 1000/1000 |
| Newly cooked ration actually eaten | 234,000 g | 150,000 g |
| Water actually extracted | 1,680,000 ml | 1,140,000 ml |
| Consecutive stable hours | 39.58 | 22.23 |
| New warehouse built and physically used | Yes | Yes |
| Actual broken-kitchen repair completed | Yes | Yes |
| Retained production jobs / delivery requests | 57 / 139 | 39 / 99 |
| Final live-save size | 175,315 bytes | 149,679 bytes |

Opening ration consumption did not advance the fresh-food witness. Fresh food had
to be made, carried, delivered and physically consumed. The settlement repair was
fenced to the announced disruption; an older repair could not count. The recovery
opening had no warehouse ration reserve and an already broken kitchen.

The repeated settlement run checked full serialized equality of one-hour
continuations after saves at hours 1, 3, 6, 24, 36, 51 and 65. Recovery checked
hours 1, 3, 6, 24 and 36. These cuts span production, loaded transport, construction,
disruption, recovery and the final objective transition. The repeated settlement
ending was byte-for-byte identical to the first completed run.

Full campaigns were completed before the comparator-only optimization described
below. That mathematically order-preserving optimization has its own exact-order,
serialized-suffix and native timing checks; this report does not claim a further
full campaign after that optimization.

[Machine-readable hourly observations and save hashes](../evidence/campaign-acceptance.json)

## Bounded correctness checks

- Functional construction/extraction/production, exact material escrow, named
  workers, cancellation, physical storage/service/housing and power commissioning
- Initial/staged pack identity, stale and invalid atomic rejection, running-session
  pinning, exact integers beyond 2^53 and checked Word64 overflow
- Checksum damage and independently re-checksummed malformed saves, revision
  exhaustion, missing policy targets and invented counter rejection
- Positive and negative campaign witnesses, including hourly needs-counter reset
- Actual schema-3/4 legacy decoding; S01/profile-6 import with live production,
  loaded cargo, partially built road and planned pump. Exact physical preservation,
  explicit snapshot conversion, unchanged source bytes, save/resume and no campaign
  credit. Other supported archive profiles are previewed and import-rejected
- Host-owned durable save/readback/activation/cancellation, stale callbacks, fresh
  authorities and bounded retry identities, covered in the host suites

Checkpoint schemas 1 and 2 are unsupported by the original archived decoder. They
must not be confused with historical rules-profile numbers. Import scope remains
explicit rather than guessing old progression.

## Forced-tick measurements

Each sample loads an actual active checkpoint, forces 1,200 individual ordinary
ticks and measures process CPU time. The early cut is hour 6; the late cut is hour
36. Other task processes were active. CPU timings are distinct from browser/network
latency. Hardware reported Intel Xeon Platinum 8573C.

| Sample | CPU mean | CPU p95 | CPU p99 | Maximum | Ticks above 50 ms | Allocated incl. load |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Early, before | 7.76 ms | 11.78 ms | 14.70 ms | 33.30 ms | 0 / 1200 | 17.48 GB |
| Early, after | 5.72 ms | 8.13 ms | 12.53 ms | 34.44 ms | 0 / 1200 | 12.24 GB |
| Late, before | 11.10 ms | 17.08 ms | 27.19 ms | 150.03 ms | 2 / 1200 | 21.98 GB |
| Late, after | 9.16 ms | 12.93 ms | 17.23 ms | 25.03 ms | 0 / 1200 | 16.05 GB |

Allocation profiling of a separate instrumented hour-24 sample attributed 50.8%
of allocation to spatial validation, which rebuilt every other placement's
footprint for each placement. `tileIndex` arithmetic in Map/Set ordering accounted
for 25.4% by itself. Save encoding/decoding was not the dominant path.

The bounded optimization compares valid tiles by `(y,x)` instead of allocating
`y*512+x` intermediates. Every invalid/negative/extreme coordinate retains the
original total-order fallback. Exact tests cover 83,521 boundary/extreme pairs,
all 262,143 adjacent valid tiles and 199,998 generated mixed pairs. No validation,
serialization schema or simulation rule was removed. The before/after 1,200-tick
continuations have identical full save bytes.

This lowered late-sample allocation by 27.0%. It does not solve the remaining
quadratic spatial rebuild. These finite samples are not a worst-case real-time
proof. The final long settlement test, including seven pairs of save continuations,
allocated 1.703 TB cumulatively but retained at most 6.80 MB. History grew modestly;
no speculative history compaction was introduced.

[Exact measurements and scope](../evidence/performance.json) ·
[Instrumented cost-centre excerpt](../evidence/allocation-profile-top.txt)

## Reproduce

From the repository root, using GHC 9.6.7 and the pinned official dependencies:

```sh
cabal test --project-file=cabal.project.red-dune-live live-boundary live-construction live-legacy live-tile-order live-host-lifecycle
cabal test --project-file=cabal.project.red-dune-live live-campaign --test-option=settlement
cabal test --project-file=cabal.project.red-dune-live live-campaign --test-option=recovery
cabal run --project-file=cabal.project.red-dune-live red-dune-tick-bench -- /tmp/red-dune-settlement-cut-36.save 1200 +RTS -s
```

The long campaign test writes active cuts to `/tmp` for the benchmark. Run it
explicitly; it is intentionally not a quick CI smoke gate. Runtime-generated saves,
profiles, build trees and downloaded dependencies are not publication inputs.
