# Red Dune live: source, play and acceptance

[Red Dune: A Settlement That Lasts](../references/red-dune-live/README.md) is the
active colony survival reference. Forty residents need real production, physical
delivery, three-shift staffing, working expansion and recovery. Haskell owns the
world, policy commands, campaign evidence, endings and saves. The browser is a
local command room, implemented with authored HTML/CSS/SVG and JavaScript.

The [0.6 source archive](red-dune.md) is a separate preserved input. It is not
rewritten by this continuation, and its historical checks are not transferred as
acceptance evidence for the new game. Neither reference is a required template.

## Build and play

The current native route needs Linux, GHC 9.6.x (tested compiler 9.6.7), Cabal 3.x
and the official `network-3.1.4.0` package. The normal project resolves dependencies
from Hackage; it does not bundle downloaded package sources. Node 20+ is needed
only for the smoke tests, not ordinary play. From the repository root:

```sh
cabal update
bash references/red-dune-live/tools/check.sh play
# A different loopback port
bash references/red-dune-live/tools/check.sh play --port 8888
```

Open the exact URL printed by the host using a browser **on the same machine**.
The wrapper starts the native executable in its own asset directory. The
[game README](../references/red-dune-live/README.md) explains the first observable
choices, controls, persistence, interruptions and tuning. Checkpoints are private
runtime data under the game directory's ignored `.red-dune-saves/` by default.

The isolated `cabal.project.red-dune-live` is optional. Ordinary foundation builds
remain GHC-bundled-package only; they do not silently acquire `network`, run a
campaign or start a service. The native host binds loopback only. This is neither
a Wasm game nor an Internet/multiplayer server; no tunnel or deployment is part
of this recipe. Windows and macOS host distribution have not been accepted.

## Three separate acceptance gates

1. **Bounded native smoke.** `bash references/red-dune-live/tools/check.sh smoke`
   builds the native host and explicitly runs `live-boundary`, `live-construction`
   and `live-host-lifecycle`, plus `live-tile-order` and `live-legacy`, then the Node protocol and native HTTP tests. These
   cover malformed/overflow/stale input, construction/use boundaries, save/adoption
   cancellation, transport retries, exact tile-order equivalence, and supported
   legacy checkpoint conversion with physical-state preservation. They do not
   claim full-campaign completion
2. **Long campaign.** `bash references/red-dune-live/tools/check.sh campaign`
   explicitly runs both authored scenarios: settlement (66 game hours) and
   recovery (42 game hours), with checkpoint suffix equivalence at selected cuts.
   These are substantial CPU-running tests, not wall-clock 66/42-hour waits.
   The test currently writes isolated evidence saves under the system temporary
   directory; they are not distribution assets. Benchmarking is a separate gate,
   using forced tick results at real campaign checkpoints rather than one cold tick
3. **Actual browser and human play.** Rendering, pointer/keyboard, focus/visibility,
   reload, cancellation, accessibility, responsive layout and a human playthrough
   remain **unverified**. A native HTTP client or Node protocol test is not a
   browser. See the explicit [manual checklist and host evidence](../references/red-dune-live/docs/HOST-VERIFICATION.md)

Current [scripted campaign and performance evidence](../references/red-dune-live/docs/ACCEPTANCE.md)
records both authored endings and separates pre-optimization full runs from the
exact serialized suffix and tile-order checks for the final comparator change.
It is not blind-player or human enjoyment evidence.

The [isolated smoke workflow](../.github/workflows/red-dune-live.yml) runs on main
pushes and pull requests affecting live source, its local libraries or project,
and can be dispatched manually. It caches only the Cabal dependency store using
OS image, architecture, toolchain and dependency-description inputs; PRs never
write a cache consumed by main. It excludes the long campaign and benchmark.
Adding a workflow is not evidence that its remote run has passed. Full campaigns,
performance samples and real-browser acceptance remain separate release gates.

## Read, format and change

Start with the [ordered reading path and tuning exercise](../references/red-dune-live/README.md#read-and-change-the-game),
then the [API](../references/red-dune-live/docs/API.md),
[campaign design](../references/red-dune-live/docs/CAMPAIGN-DESIGN.md) and
[save format](../references/red-dune-live/docs/SAVE-FORMAT.md). The readable
boundary is `applyAction` / `advanceGame` / `observeGame`; the host supplies time,
transport and durable file effects. New goals must derive from real committed
world transitions, not from UI counters or privileged policy grants.

The entire live `src/`, `app/` and `test/` trees are selected in `formatter.json`.
Use the [pinned Ormolu 0.9.0.0 helper](formatting.md); the archive-only exemption
does not apply to this active fork. Layout consistency does not establish source
readability or correct gameplay. See the [readability review](../references/red-dune-live/docs/READABILITY.md)
for the actual transition traced, remaining complexity and scoped result.

## Distribution boundary

The live package preserves the original MIT notice and records its exact archived
source base in [provenance](../references/red-dune-live/PROVENANCE.md). Shipped
[visuals and content](../references/red-dune-live/ASSETS.md) are authored or
procedural. Build/cache directories, toolchain/dependency downloads, benchmark
raw profiler dumps, saves and binary fixtures are ignored. No commercial game assets,
external font/audio packs or unexplained binary payloads are selected.

`cabal sdist` is a source inventory check, not a self-contained binary release:
the supported build still uses the repository's local foundation libraries.
Hackage upload is not qualified. `cabal check` rejects the development `-Werror`
policy for distribution and warns about package metadata and unconstrained
GHC-bundled dependencies; no Hackage publication is part of this reference.
