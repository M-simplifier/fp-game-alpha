# Red Dune: A Settlement That Lasts

A Haskell-first colony survival campaign with a local browser command room. Forty
settlers need a physical water–farm–kitchen–pantry chain, crews across three shifts,
useful new capacity, and recovery from a real kitchen failure. The campaign tracks
freshly produced food through delivery and consumption; starting stock is not a win.

This is active game implementation. The separately preserved `../red-dune` archive
is unchanged. Native HTTP integration and pure campaign verification are separate
from browser acceptance; see [verification](docs/HOST-VERIFICATION.md).

## Play

Linux, GHC 9.6.x (base 4.18), Cabal 3.x. The host adds the official
`network-3.1.4.0` package to the two local foundation libraries. No Python runtime
or JavaScript gameplay engine is used. Node 20+ is optional for host/protocol tests.

From the repository root:

```sh
cabal update
cabal build --project-file=cabal.project.red-dune-live exe:red-dune-live
cd references/red-dune-live
cabal run --project-file=../../cabal.project.red-dune-live exe:red-dune-live
```

Open the exact URL printed by the host, normally loopback port `8787`. Run the
command from this game directory so its `ui/` assets are found. A different port:

```sh
cabal run --project-file=../../cabal.project.red-dune-live exe:red-dune-live -- --port 8888
```

The host binds only to loopback. It is a local single-player host, not a public
multiplayer service. Do not put it behind a proxy or expose it to the Internet.
The `unix` dependency means Windows/macOS distribution is not claimed for this
host. A browser on a different machine cannot reach its loopback address.

### Your first decisions

1. The game begins paused. The first tab claims control; another tab can observe
   but cannot issue actions while the owner is connected
2. Choose **生活維持の政策を設定** to staff the three shifts and enable visible
   production, replenishment and maintenance policies. They emit ordinary Haskell
   commands and cannot grant materials or finish construction instantly
3. Choose **予備倉庫と道路を計画** for guided expansion, or use the construction
   and workforce tabs for individual plans, priorities and rosters
4. Resume with the top-left time control. Inspect the map, live work list,
   inventory and policy reasons. Use 1×, 2× or 4×; one authoritative host clock
   advances every part of the colony together
5. Follow the six campaign objectives. New food must be made, carried, delivered
   and eaten; a new building must be used; the disrupted kitchen must be repaired;
   healthy residents and pantry reserves must remain stable across shifts

The UI mixes Japanese operational labels with English campaign briefs. Space
pauses/resumes when focus is outside a form; number keys 1–3 select speed. WASD
moves the map, Q/E rotates, F frames the full map. Dialogs and forms have normal
keyboard controls. Browser motion is optional and does not control simulation.

A settlement run requires 66 game hours with 24 hours of stable service. Recovery
starts with a broken kitchen and reduced rations, then requires 42 hours with 18
hours of stability. At full 20 Hz, one game hour takes one real minute at 1×, or
about 15 seconds at 4×; simulation work and pauses can make it slower. These are
substantial survival runs, not six button presses masquerading as a campaign.

## Save, resume and interruption

Checkpoints live in `.red-dune-saves/` under the game directory. Set
`RED_DUNE_STORE=/your/private/folder` before starting to use a different location.
One host process owns a save folder using a POSIX lock. Startup and restart are
saved before their new world becomes visible. Manual saves and autosaves capture
complete game state, including campaign witnesses, policies and pinned/staged
content. A success is reported only after file flush/fsync, exact readback and
validation, atomic rename, and directory fsync.

Use **保存・枝の読込** → refresh → select a checkpoint → preview → confirm.
Preview pauses time. Confirmation creates a fresh, durably allocated branch and
UUID authority; the source file remains intact. Unsaved progress needs explicit
acknowledgment. Cancel retains the current world. If cancellation wins while a
candidate is being written, that unused checkpoint may remain in the catalog.
Reloading the browser does not erase checkpoints or automatically resume time.

The host auto-saves changed, connected play roughly every 30 seconds. Closing or
hiding the owning tab releases control when delivery is possible. If heartbeat
stops, its four-second lease expires and the host pauses; there is no offline
catch-up. To return, claim control and explicitly resume. If a command response
is lost, use the recovery button: it sends the exact same command/request identity.
Do not replace an uncertain action with a new command ID.

## Content and policies

The JSON pack `data/campaign-pack-v1.json` contains both scenarios and the economic
catalog. `RED_DUNE_PACK=/path/to/pack.json` chooses a validated starting pack.
Existing checkpoints preserve their own pack. The browser can stage a full pack
(up to its bounded HTTP upload size) for the next campaign; current play remains
pinned. It sends raw text so integer content is never rounded by JavaScript.
Pack revision must increase; stale/invalid proposals leave the staged pack intact.

The policy panel exposes target stock, batch size, enabled status, actual incoming
stock and Haskell-computed blocked reasons. Change one policy while paused and
watch its next ordinary deliveries after resuming. See [the engine API](docs/API.md)
for the same actions usable by headless drivers.

## Read and change the game

For frequent source edits, use the [checked native development loop](docs/DEVELOPMENT.md).
It keeps the simulation optimized while reloading gameplay/host modules in GHCi,
and always restarts into a fresh paused campaign. Content staging and policy
forms remain the no-compilation tuning path.

1. `src/RedDune/ContentPack.hs`: authored scenario/economic input and validation
2. `src/RedDune/Game.hs`: `GameState`, `applyAction`, `advanceGame`; the pure entrypoints
3. `src/RedDune/Policies.hs`: enabled policies become ordinary commands
4. `src/RedDune/Campaign.hs`: evidence from committed physical transitions and endings
5. `core/Colony/Scheduler.hs`, `Arena.hs`: the underlying world boundary and receipts
6. `src/RedDune/GameSave.hs`: complete framed checkpoint encoding/validation
7. `app/RedDune/Host.hs`: one clock, ownership, HTTP, durable files and async adoption
8. `ui/`: projection rendering, input envelopes and response/retry guards only

For example, a production click previews `OrderProduction` in Haskell, returns
its full controller/epoch/sequence/boundary envelope, and commits that envelope
through the same command decoder used by headless play. Inputs are reserved and
workers carry out the job over ticks. A fresh ration contributes to campaign
progress only after its real later movement and consumption. The browser never
calculates an objective or performs a second economic simulation.

For a small tuning exercise, copy the pack, increase its revision and modestly
change a recipe's work time. Stage it, inspect its identity, restart, then compare
observations. Running jobs and saved campaigns keep the original pinned catalog.

## Checked campaign evidence

The [acceptance report](docs/ACCEPTANCE.md) records scripted 66-hour settlement
and 42-hour recovery endings, save-continuation comparisons and actual-checkpoint
CPU/allocation measurements. Full campaigns were run before the exact-order tile
optimization; its separate ordering and serialized-suffix checks are explicit.
These finite scripted results do not establish human enjoyment or browser play.

## Verification commands

```sh
# From repository root: bounded native and host tests, without the long campaign
bash references/red-dune-live/tools/check.sh smoke
# Explicit longer gates: physical 66-hour settlement and 42-hour recovery runs
bash references/red-dune-live/tools/check.sh campaign
# Run the local host (starts in the correct asset directory)
bash references/red-dune-live/tools/check.sh play
```

The HTTP test launches an isolated server/save folder and removes only that test
folder afterward. It does not drive a browser. See the verification report for
passed cases, review findings and remaining device/input coverage.

The isolated [CI workflow](../../.github/workflows/red-dune-live.yml) runs the bounded
smoke checks when live source or its dependencies change, and by manual dispatch.
It never runs the full campaign by default. See [technical acceptance](../../docs/red-dune-live.md)
for long-run gates, formatting/readability scope and publication restrictions.
All shipped visuals are authored/procedural; see [asset notices](ASSETS.md).
