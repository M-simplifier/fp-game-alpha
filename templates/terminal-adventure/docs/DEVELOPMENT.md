# Continue your game

This directory owns the game source, tests, assets and `GAME-SPEC.md`.
Start here with `$game-dev` or ordinary Haskell editing. The foundation checkout,
an editor extension and an LLM are not build dependencies. Never regenerate
over this game's edits.

## Build, test and play

Follow the [README commands](../README.md) and [native setup](native-tooling.md).
Bootstrap the copied `tools/haskell/` source once, then use `.build/tools/fp-game`
(`fp-game.exe` on Windows) for `doctor`, `build`, `test`, `check` and `run`.
Ordinary Cabal is also supported. Core commands do not require Python.

Keep tooling bootstrap and the game's Cabal compiler choice separate. Preserve
existing profiles and wrappers. After relocation, rebuild the copied tooling
and deliberately recreate any machine-local compiler selection; never copy
`cabal.project.local` as portable source. Optional inspection, formatter and
editor helpers have their own prerequisites in the linked guides.

## Read and change one interaction

1. `Game.Model`: vocabulary, projections and validated state
2. `Game.Rules.advance`: the authoritative whole-turn decision
3. `Game.View` and `Game.Adapter`: presentation and protocol adaptation
4. `Game.Save`: versioned codec; `app/Main.hs`: input, config and IO
5. `test/Spec.hs`: playthrough, invariant, failure and save checks

For the next mechanic, name the observable requirement in `GAME-SPEC.md`.
Change the relevant state, rules, feedback and tests together. For example, a
key-and-locked-exit feature needs both refusal without the key and success with
it, plus save/load of ownership. Keep the exit rule out of the renderer.
Run the affected tests and a real playthrough; update the smoke trace if the
winning route changes. Small changes do not require every optional tool or guide.

Use the [kernel contract](architecture.md), [readability guide](haskell.md),
[prevention lessons](failure-prevention.md) and [technical guide index](TECHNICAL-GUIDES.md)
when the changed boundary calls for them. For explanations, `$learn-code` reads
this game's current source through the local [learning guide](learn-code.md).

## Saves, assets and upgrades

`config/game.conf` owns the title and relative save path. Saves use a nearby
temporary file plus rename, with version, size and invariant checks; this does
not promise crash durability or cloud sync. When state changes, choose and
test the old-save policy. Keep fixtures for supported versions and reject others.

The terminal game downloads no artwork, fonts or audio. Add asset provenance
and notices when a renderer uses them. Graphics, browser input and device
performance need their own host checks.

`foundation.lock.json` pins vendored source, tool source, guides and kernel
versions. `scaffold-manifest.json` describes the initial files; later edits are
expected. Upgrade chosen files deliberately, compare API/save implications,
and run the affected game regressions without replacing game-owned work.
Retain the foundation MIT notices and choose the game additions' own license.

For formatting, use the [project-local helper](formatting.md): `plan`, explicit
`install` when permitted, and `check`/`write` for owned source. A check never
downloads, and formatting does not establish behavior or editor integration.
