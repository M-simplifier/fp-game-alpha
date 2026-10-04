# Continue your game

This project owns its source, tests, assets, config, docs and game specification.
The starter checkout is no longer a dependency. Begin in this directory, read
`GAME-SPEC.md`, and invoke the local `$game-dev` skill or edit ordinary Haskell.
Neither an editor extension nor an LLM is required.

## Reading path

1. `Game.Model`: vocabulary, projections, validation of persisted data
2. `Game.Rules`: one whole-turn `advance` and output descriptions
3. `Game.View`: pure board and feedback presentation
4. `Game.Adapter`: `Machine` and `Arena` witness; protocol admission only
5. `Game.Save`: versioned, validated codec
6. `app/Main.hs`: IO, config, input parsing and file storage
7. `test/Spec.hs`: playthrough, invariants, failure and save regressions

`Column` and `Row` distinguish axes; `Turn` distinguishes boundary count.
They do not by themselves enforce a range. The internal representation is a
game implementation detail; public construction checks bounds and invariants.
Study the versioned [kernel contract](architecture.md) and
[readability guide](haskell.md) only when a change needs them.
Before adding unfamiliar timing, input, rendering, persistence or performance
behavior, select the relevant [technical guide](TECHNICAL-GUIDES.md). These
pinned public references remain reachable without the starter checkout; read
only what the current change needs and preserve this game's own requirements.
For a bug found during review or play, follow the
[prevention ledger](failure-prevention.md): preserve a case regression, then
check whether a public construction path, invariant, template or systematic
test should prevent the same class of error. The starter acceptance compiles
an outside client to verify that `Game.Model` exposes read-only projections.

## Add your next mechanic

Agree a small observable requirement and edit `GAME-SPEC.md`. Change the state
vocabulary, authoritative rules, rendered feedback and regression tests
together. For example, add a collectible that unlocks the exit: check failure
at the exit without it, success after collecting it, persistence of ownership
and the invariant that a won world owns the collectible. Do not put a second
copy of the exit rule in the renderer or host.

Run build/test and a real playthrough using the README commands. Update the
smoke trace when the winning route changes. Continue with the next feature;
scaffolding is a one-time starting operation, not a regeneration workflow.

## Persistence, configuration and assets

`config/game.conf` contains the title and a relative save path. Save writes use
a nearby temporary file plus rename; there is no claim of crash durability or
cloud sync. `Game.Save` checks a version, size and game invariants. When adding
state, choose and test the legacy-save policy explicitly; migration is not
automatic. Keep fixtures for supported versions and reject unknown versions.

The terminal route renders its own text and downloads no artwork, fonts or
audio. Add licensed/original assets and their provenance when a new renderer
actually uses them. A graphics or Web build is a separate route acceptance,
not a consequence of this game's pure kernel tests.

## Foundation upgrades

`foundation.lock.json` records the exact upstream commit, package versions and
hashes of the vendored source and versioned docs. Your Cabal file pins kernel
versions exactly. Builds use these local sources, not a floating main branch,
a personal path or a sibling checkout. `scaffold-manifest.json` records the
initial files; editing your game is expected and does not invalidate ownership.

For an upgrade, inspect the source/API/law/doc difference, replace only the
chosen vendored files and pins, then run the game regressions. Preserve game
code, assets, config and save fixtures. Review save and protocol migration
separately. No command silently regenerates or upgrades your game.

## Shipping

Choose your game license independently of the retained foundation/template
MIT notices. CI uses the same standard Cabal commands as local development.
Before shipping, establish your selected renderer/runtime, gameplay scope,
save recovery, asset rights, platform/device performance and distribution
requirements. The alpha provides a path for this work; it does not certify it.

## Consistent Haskell formatting

Use the [pinned project-local formatter](formatting.md) for explicit setup,
non-writing checks, owned-source formatting and external HLS integration.
Run `python tools/formatter.py plan`, then `install` when permitted;
`check` never downloads and `write` never targets vendored source.
