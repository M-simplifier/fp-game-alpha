# Red Dune: play, change and assess the evidence

[Red Dune: A Settlement That Lasts](../references/red-dune/README.md) is the
active colony survival reference. Forty residents need real production,
physical delivery, staffing, expansion and recovery.

## Play and change

Use the game's current [Windows native instructions](../references/red-dune/README.md#windows-native-app)
or [Linux browser instructions](../references/red-dune/README.md#linux-browser-play).
Follow those instructions for requirements, commands, controls and save locations. The browser route
uses a local native HTTP host, not Wasm or an Internet multiplayer server; open
its printed loopback URL on the same machine.

For source changes, start with the [reading path and tuning exercise](../references/red-dune/README.md#read-and-change-the-game)
and [development loop](../references/red-dune/docs/DEVELOPMENT.md).
Haskell owns committed world transitions, campaign evidence and saves. A host
supplies time, input and durable effects; a UI counter or privileged material
grant cannot stand in for real production and consumption.

## Choose checks for the change

The [verification guide](verification.md) gives the current bounded checks.
[Host boundaries](../references/red-dune/docs/HOST-VERIFICATION.md) explain the
protocol, ownership, checkpoint and HTTP contracts those checks protect.
An HTTP client or Node test does not exercise browser rendering, focus or device input.

[Campaign scenarios](../references/red-dune/docs/ACCEPTANCE.md) provide commands
for the authored 66-game-hour settlement and 42-game-hour recovery scenarios,
checkpoint continuations and performance measurements. Run the relevant cases
when changing their rules; record the actual toolchain, inputs and observed
results. These are CPU-running scenarios, not wall-clock waits. They are not
part of the bounded CI default, and an available command is not a passed run.

Actual interaction and human play require their own observations. Scripted
endings and performance samples do not establish usability or enjoyment.
Current source uses the [pinned formatter](formatting.md).

## Distribution boundary

The game retains its [MIT notice and source provenance](../references/red-dune/PROVENANCE.md)
and [asset notices](../references/red-dune/ASSETS.md). Saves, caches,
downloaded dependencies, benchmark dumps and compiled outputs are private build
or runtime data, not selected source assets.

`cabal sdist` checks a source inventory; it is not a self-contained binary
release. The build still uses local foundation libraries, and Hackage upload is
not qualified. The game's host/package instructions describe runnable packages
and their dependency and licensing requirements.
