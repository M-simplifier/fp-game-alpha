# Red Dune live: play, change and assess the evidence

[Red Dune: A Settlement That Lasts](../references/red-dune-live/README.md) is the
active colony survival reference. Forty residents need real production,
physical delivery, staffing, expansion and recovery. The
[0.6 archive](red-dune.md) is a separate preserved input; its old checks are not
acceptance evidence for this continuation.

## Play and change

Use the game's current [Windows native instructions](../references/red-dune-live/README.md#windows-native-app)
or [Linux browser instructions](../references/red-dune-live/README.md#linux-browser-play).
Follow those instructions for requirements, commands, controls and save locations. The browser route
uses a local native HTTP host, not Wasm or an Internet multiplayer server; open
its printed loopback URL on the same machine.

For source changes, start with the [reading path and tuning exercise](../references/red-dune-live/README.md#read-and-change-the-game)
and [development loop](../references/red-dune-live/docs/DEVELOPMENT.md).
Haskell owns committed world transitions, campaign evidence and saves. A host
supplies time, input and durable effects; a UI counter or privileged material
grant cannot stand in for real production and consumption.

## Read three different kinds of evidence

- [Bounded host verification](../references/red-dune-live/docs/HOST-VERIFICATION.md)
  and [verification commands](../references/red-dune-live/README.md#verification-commands)
  cover their named native/protocol/lifecycle cases. An HTTP client or Node test
  does not exercise browser rendering, focus or device input
- [Campaign and performance evidence](../references/red-dune-live/docs/ACCEPTANCE.md)
  records the authored 66-game-hour settlement and 42-game-hour recovery runs,
  selected checkpoint continuations and actual-checkpoint measurements. These
  are CPU-running scenarios, not wall-clock waits. Keep pre-optimization full
  runs distinct from later exact-order and serialized-suffix checks
- Actual browser/native interaction and human play require their own observed
  results. Neither scripted endings nor performance samples establish usability
  or enjoyment; consult the host reports for completed and remaining checks

The bounded CI workflow does not run the long campaigns by default. A workflow
file is not evidence of a passed remote run. This active fork uses the
[pinned formatter](formatting.md); the archive-only formatting exemption does
not apply. Layout alone establishes neither readability nor correct gameplay.

## Distribution boundary

The game retains its [MIT notice and source provenance](../references/red-dune-live/PROVENANCE.md)
and [asset notices](../references/red-dune-live/ASSETS.md). Saves, caches,
downloaded dependencies, benchmark dumps and compiled outputs are private build
or runtime data, not selected source assets.

`cabal sdist` checks a source inventory; it is not a self-contained binary
release. The build still uses local foundation libraries, and Hackage upload is
not qualified. The game's host/package instructions describe runnable packages
and their dependency and licensing requirements.
