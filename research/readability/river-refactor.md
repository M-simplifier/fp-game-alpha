# River Home: naming the state used during a night

When the player sleeps after sunny day one, watered crops still grow and both
loaded wood racks still dry by 50%. The rainy morning then waters exposed
plots again. The code now names those different state values together, so a
reader can see which day's weather feeds each calculation. Initial state and
save restoration also pair each value with its private `Game` field.

This is a bounded readability revision of
[`Life.Domain`](../../references/river/src/Life/Domain.hs). The original comparison
baseline is public commit `715b1b4f44d242609c2028c5d7b68ea5e3cddb7f`.
Before publication, main `9fd07cb` was integrated, retaining its publication
selection and code-learning instructions. River's incoming sources did not
change. The existing
[Station findings](station-refactor.md) informed the focus on decisions,
state ownership and exact consumer observations.

Readability judgments here are the refactor author's assessment. No
independent beginner comprehension, human play study or transfer into newly
generated games was measured. The project remains a research/reference lane;
this revision asks whether explicit state dependencies and field assignments
reduce reconstruction work while preserving the current game's behavior.

## Follow sleeping from input to output

Start with [River's reading path](../../references/river/README.md), then trace
`Interact` near `homeCell`:

| Stage | Actual decision or result |
| --- | --- |
| `splitCommand` / `RiverArena` | `Interact` uses `InteractionBoundary` with the singleton `Villager`. Admission accepts the command; it does not choose an interaction or apply garden rules. |
| `riverStep` / `advance` | `riverStep = Step Domain.advance`. The command dispatcher sends `Interact` to `interactWorld`. |
| `interactionTarget` | The prompt and action share distance, facing and tie-breaking. `AtHome` selects `sleep`. Merely being on a new render frame cannot select sleep. |
| `wateredTonight` | Rain from `closingDay` waters its exposed nonempty plots. Existing hand watering is retained. |
| `afterNight` | Watered planted/sprouting crops grow once and their water flags reset. Loaded wood dries using the closing weather and roof coverage, capped at 7,200. The factual `NightReport` records that same day. The next day is capped at 1,000,000 and starts at tick zero. |
| `nextMorning` / `changed` | New-day rain may water exposed plots again. The returned result is the new `Game` and `[Changed message, SaveRecommended]`. Effects are host requests, not stored authority. |
| `observe` / persistence | `RiverView` and domain projections read the returned game. `encodeGame` records it; validated `decodeGame` restores it. This selected reference has no graphical host or storage executor. |

`Tick` remains separate: it saturates movement inputs before arithmetic,
resolves x then z collision, increments the in-day clock up to its cap, and
applies rain. It does not grow crops or dry wood. `Life.Clock.schedule`
allocates at most eight movement ticks per frame while retaining exact debt;
the host must consume those ticks. None of these rules changed.

## Two concrete reader difficulties

The original `sleep` mixed next-day record updates with an enclosing rain
application. Its helpers also read `g` and `rested`, requiring a reader to
reconstruct what day each value represented. Here is the complete original
result expression and its first local binding:

```haskell
sleep g =
  changed message $
    waterRain
      rested
        { gDay = min maxDay (gDay g + 1),
          gTicks = 0,
          gBeds = Map.map grow (gBeds rested),
          gWood = Map.mapWithKey dryOvernight (gWood g),
          gNight = Just night
        }
  where
    rested = waterRain g
```

The corresponding expression and state bindings now read:

```haskell
sleep closingDay = changed message nextMorning
  where
    -- Rain reaches the closing day's plots before growth consumes their water.
    wateredTonight = waterRain closingDay
    nextDay = min maxDay (gDay closingDay + 1)
    afterNight =
      wateredTonight
        { gDay = nextDay,
          gTicks = 0,
          gBeds = Map.map grow (gBeds wateredTonight),
          gWood = Map.mapWithKey dryOvernight (gWood closingDay),
          gNight = Just night
        }
    -- Apply the new day's rain only after recording the completed night.
    nextMorning = waterRain afterNight
```

The count/report/growth helpers continue below both excerpts. Their decisions
remain local and unchanged; references to `g`/`rested` now name `closingDay`
or `wateredTonight`. In particular, `dryOvernight` reads
`weather closingDay`, while the message uses `weatherFor nextDay`.
The reader no longer has to infer that distinction from an enclosing record
update. These are pure values and dependencies; `where` does not impose an
imperative execution schedule.

The second difficulty was positional construction of sixteen `Game` fields.
Several neighboring arguments were `Int`, including position, facing, day,
clock and inventory. The complete original initial construction was:

```haskell
initialGame =
  Game
    450
    650
    0
    1
    1
    0
    (Map.fromList [(c, Bed Empty False) | c <- cropCells])
    (Map.fromList [(c, Bundle 0 False) | c <- woodCells])
    Set.empty
    Set.empty
    Set.empty
    NoBuild
    0
    0
    NotPromised
    Nothing
```

The same constructor now names its existing fields:

```haskell
initialGame =
  Game
    { gPlayerX = 450,
      gPlayerZ = 650,
      gFacingX = 0,
      gFacingZ = 1,
      gDay = 1,
      gTicks = 0,
      gBeds = Map.fromList [(c, Bed Empty False) | c <- cropCells],
      gWood = Map.fromList [(c, Bundle 0 False) | c <- woodCells],
      gRoofs = Set.empty,
      gPaths = Set.empty,
      gSeats = Set.empty,
      gBuild = NoBuild,
      gTurnips = 0,
      gDryWood = 0,
      gDinner = NotPromised,
      gNight = Nothing
    }
```

`fromRaw` now uses the same form: for example `gDay = n (rDay r)`,
`gTicks = n (rTicks r)`, `gTurnips = n (rTurnips r)` and
`gDryWood = n (rDryWood r)` explicitly identify each conversion's destination.
This changes the work from counting arguments against the declaration to
reading assignments beside their roles. It adds no wrapper, helper, public
selector or new validation guarantee.

## Deliberately retained choices

- `Game` is already an effective authority boundary: its constructor and record
  selectors stay private, and ordinary public projections remain read-only.
  `Cell` intentionally stays an unvalidated input/view coordinate.
- `advance`, `interactionTarget`, construction and removal guards, and the
  shared prompt/action decision were already direct. No new dispatcher,
  wrapper family or chain of one-use helpers was added.
- `Bed`, `Bundle` and `NightReport` remain the existing private representations.
  The new local names explain the temporal distinction without a public state
  split or a type-level phase protocol.
- `RawSave`/`RawNight` declarations, serialization, parsing, enum lookup,
  validation and the ordered error list remain unchanged. Named `fromRaw`
  construction does not make that helper a new public input boundary.
- `NightReport` remains a factual snapshot. Removing a roof later does not
  rewrite the completed night. Effects remain outside `Game`.
- Dependencies, language extensions, clock, adapter, existing law expectations
  and API fixtures are unchanged. Formatter setup is reused without modification.

## Conditional guidance carried into the existing skill route

Two small additions to [`docs/haskell.md`](../../docs/haskell.md) refine its
existing “keep state evolution visible” rule. The public `haskell-excellence`
skill already routes to that guide, so no parallel skill or duplicated
instruction was needed.

| Activation condition | Operation and reason | Exception and observation limit |
| --- | --- | --- |
| A transition uses old conditions for a completed night/round and new conditions afterward. | Name the old state and useful intermediate results beside the calculations. The provenance of weather, permissions or accumulated results becomes visible locally. | A single-update rule needs no staged pipeline. Names alone prove neither evaluation order nor the correct chronology; preserve dependencies and compare boundary cases. |
| A wide existing record has multiple same-typed constructor arguments. | Construct it with its existing private field names. Readers can pair values with roles directly; reviewers can inspect restoration mappings without argument counting. | Do not manufacture records for small clear pairs, expose private fields, or claim added range safety. Field swaps still require meaningful observations and checks. |

These are source-backed reasons for a local refactor, not proof of improved
generation on arbitrary briefs. Human intent → AI reasoning → repeatable tools
remains the workflow; River's shape is not a required template.

## Verification and reproducibility

The unchanged start passed the River law suite, outside-client API check,
documentation lint and publication gate. Cabal's no-remote-server warning is
expected for the offline profile. The new comparison consumer was first compiled
against the unchanged baseline/current sources before the refactor.

Local checks use GHC 9.6.7, Cabal 3.12.1.0, Python 3.14.2 and pinned
Ormolu 0.9.0.0. Only affected Haskell files were written by the formatter,
with AST safety and idempotence enabled.

| Check | Result and scope |
| --- | --- |
| `cabal --config-file=.build/cabal.config test river-home-reference:river-laws --offline --builddir=.build/dist --test-show-details=direct` | Pass before and after: authored journey, fixed crop/wood expectations, factual report persistence, save round-trip/rejection/continuation, Step/Arena agreement, protocol failures, invariant prefixes, saturated ticks, clock debt and deleted-rule mutation. Independent expectations were not edited. |
| `python tools/test_river_api.py` | Pass before and after: external projections compile; attempted `Game` update is rejected for the record-selector reason. |
| Pinned formatter check/write/check | Pass on `Life.Domain` and the comparison probe. The final non-writing repository check also passes. |
| `python research/readability/compare_river.py 715b1b4` | Pass: 37,863 labelled observations match byte for byte, including raw serialized saves, effects, projections and continuation. |
| `python tools/docs_lint.py` | Pass after the report and guide update. |
| `python tools/publication.py snapshot`, then `check` | Pass; refreshed current hashes and new research entries retain all original source digests, licenses, maturity and existing selection rules. |

The original author-reported comparison contains 26,488,887 bytes with SHA-256
`49bede75411a57d19d195045aec41275cd133b21b483cb0530a4a89bfb3f0249`.
It is historical local evidence for that earlier integration, not an exact-head CI claim.
The current-main integration is separately reproduced below.

The first documentation check caught a local research link in the shared
Haskell guide that broke when copied into an independent generated game.
That link was removed; River's README still links to this report. The final
check covers both foundation documents and the generated-game copy.

The [runner](compare_river.py) retrieves five source modules from the fixed
public baseline with `git show` and compiles the same
[consumer](RiverProbe.hs) against them and current working sources. It uses
only Git, GHC and Python's standard library, writes temporary build artifacts
under ignored `.build/river-readability/`, and removes those artifacts on exit.
The baseline supplies expected output; the refactor does not regenerate an oracle.

The finite comparison covers five initial/authored scenes, 42 individual
commands per scene, successful/repeated construction and removal traces,
Step replay, Arena refusals and no-input ticks. Its 896 accepted save/night
fixtures cross four days (including the last two capped days), both clock
boundaries, seven crop/water states, four loaded/progress states and four roof
layouts. It compares restored observations, a continuation and an actual
walk-home/sleep path for each. Thirty additional codec cases include malformed,
oversized, numeric/enum/cross-field failures, overlapping errors and accepted
edits. Eleven clock frames exercise fractional allocation, the cap and retained
debt consumed by real domain ticks.

This is not exhaustive over River's large state space or arbitrary traces.
Graphical rendering, real-host input, storage durability, performance,
beginner comprehension and learning transfer remain unverified. The original author did not rerun unrelated
games or the whole-project suite; subsequent integration checks are listed below.


## Current-main integration (2026-10-04 UTC)

PR #24 head `76a9d71465e292088ba3c59ec8527b467f47347b` was locally
merged with public main `c44f31a522102512dcd6eca8f100ba5ab1df31ca`.
The merge retains both main's numeric-decoding prevention rule and this
revision's conditional guidance. The only conflicted file was the generated
publication manifest; it was regenerated with main's current compact generator.
No River rule, test expectation, comparator consumer, or workflow was changed
by conflict resolution.

On GHC 9.6.7 and Python 3.12.14,
`python research/readability/compare_river.py c44f31a` passes with 37,863
byte-identical observations and coverage `(5,42,896,30,11)`. This run produces
26,451,024 bytes with SHA-256
`c13f23495fbf9466224624a3397f56f88bf58a5ce7f9c2892b08a3536be4d9b7`.
The baseline and merged consumer output match exactly within this run. Its
byte count and digest differ from the historical author's run above; those
results are recorded separately rather than treated as a portable golden.

The unchanged River law suite also passes when compiled directly with
`-XGHC2021 -Wall -Wcompat -Werror`, and the external public API check passes.
These are local integrated-tree observations, not exact-head CI results.

Additional integration gates pass locally: root offline build and all nine root
Cabal test suites; documentation lint; publication snapshot/check (758 selected
files); tool tests; pinned whole-repository formatter check; formatter integration
tests (one platform-specific skip); Lantern and Station external API checks;
play tests; and generated independent-game workspace acceptance. The offline
root build used the available Cabal 3.16.1.0, not the CI baseline Cabal 3.12.1.0.
The first tool-test attempt lacked GHC on PATH; it was rerun successfully after
selecting the existing GHC 9.6.7 toolchain. No new toolchain was installed.
Paper Circuit controls and opaque-API checks, quantity source-only checks
(including eight expected type rejections and 631,024 oracle rows twice), and
bounded live-tuning semantics/CLI checks also pass. LiquidHaskell, full editor
jobs, Afterlight jobs, browser-host play, and platform-matrix CI were not run
for this local integration.
