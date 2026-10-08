# Fast, checked Red Dune development

GHC 9.6.7, Cabal 3.12.1.0. These workflows play the real Red Dune campaign.
The Windows command below builds and opens the native app. The remaining
GHCi/HTTP workflow is Linux-specific.
The operational supervisor, game rules, validation and HTTP host are Haskell.
Python files under `tools/` are independent measurement/regression drivers only.
The ordinary optimized play and acceptance commands remain in `tools/check.sh`.

## Windows native editing

From the repository root in PowerShell:

```powershell
.\references\red-dune-live\tools\dev-native.ps1
# Or start the recovery scenario:
.\references\red-dune-live\tools\dev-native.ps1 -Scenario recovery
```

Save a source or data edit, close the previous development window, and run the
same command again. Existing Cabal incrementally rebuilds the changed dependency
closure, then packages and launches `.build/red-dune-native-dev/app/Red Dune.exe`.
Compilation or packaging failure stops before launch. A still-open development
window is reported before building; it is never silently reused or terminated.

The command validates `data/campaign-pack-v1.json` and starts a fresh paused
campaign using that pack. `-ContentPack PATH` selects another existing pack in
the same format. No Haskell compilation is needed for a pack edit. Invalid data
cannot initialize a new campaign. F9 retains the normal preview/confirm flow:
older saves use their own embedded pack, irrespective of the edited file.

All development checkpoints remain in `.build/red-dune-native-dev/saves/`.
The command explicitly selects this path, even if `RED_DUNE_NATIVE_STORE` points
elsewhere. It does not install over the owner's app or use their ordinary saves.
Re-running creates a new branch and retains earlier development checkpoints.

On the measured Windows host, cached unchanged launch took 4.01 s to an actual
native GPU capture, a pack edit 6.39 s, and a small Haskell view edit 10.19 s.
These are single observations, including process startup and packaging, not a
general speed guarantee. First dependency builds and large source edits differ.
The [measurement and failure checks](DEVELOPMENT-EVIDENCE.md#windows-native-entry)
keep this separate from the historical Linux reload results. There is no watcher;
the same explicit command is the edit/play boundary.

## Three useful edit boundaries

1. **Content and policy tuning:** use the existing policy forms or stage a revised
   `data/campaign-pack-v1.json` in the browser. The screen shows both current and
   staged title/revision/identity. A staged pack does not change the current world,
   running jobs, or saved campaign. Start a new campaign to adopt it. Invalid or
   stale proposals retain the previous staged pack. No new configuration DSL is
   involved and no Haskell compilation is needed.
2. **Gameplay/host source:** `src/RedDune/`, `app/`, and `dev/` are interpreted home
   modules in the explicit `red-dune-dev` Cabal component. A checked GHCi reload
   replaces them while the optimized Colony dependency stays compiled.
3. **Simulation/build configuration:** `core/Colony/`, foundation libraries, and
   Cabal files replace the interpreter and use Cabal to rebuild dependencies. This
   is deliberately a slower boundary. Changes to compiled dependency code cannot
   be picked up by simply issuing `:reload` in the old interpreter.

The original `Colony.*` module names remain available from the main library through
reexports. The directory move expresses the actual compile boundary; it introduces
no second implementation of the simulation. Production library, host, tests and
benchmark retain their original `-O2` flags.

## Source editing

From the repository root:

```sh
bash references/red-dune-live/tools/dev.sh
```

Open the printed loopback URL on the same machine as the host. The `#dev` fragment
adds an observational development status line. Edit a gameplay function, save it,
and watch the compiler log and terminal status. A successful reload starts a new,
paused, durably checkpointed campaign with a new runtime/authority and branch.
Claim control in the browser and try the rule. Unsaved live progress is discarded
on source reload; save first if it matters. Load an older checkpoint only through
the normal preview/confirm flow, which validates the complete save and allocates a
fresh authority. There is no arbitrary heap-state migration.

Development artifacts and saves live under `.build/red-dune-dev/`, separate from
normal `.red-dune-saves/`. The supervisor records detected source digest, compile,
HTTP readiness and failure phases. The running host captures its checked revision
at startup; changing an environment variable cannot relabel a running old host.
An unchanged source reload still starts a fresh paused authority.

Compilation failure leaves no newly ready game. The existing browser reports that
host confirmation is missing; detailed compiler diagnostics are in the terminal
and `compiler.log`. Correct the source and save again. Rapid edits that supersede
the compiling snapshot are retried before a new ready state is published. Ctrl-C
stops the host, joins its HTTP/checkpoint/ticker workers, then closes GHCi.

The first build compiles the optimized simulation and dependencies and can take
minutes. Cached interpreter startup is distinct from a subsequent source reload.
Edits to the supervisor itself require restarting the launcher. CSS/JavaScript
changes are served without a Haskell rebuild; reload the page to replace its code.

## Measure rather than assume

A native HTTP response is not a rendered browser frame. The `#dev` status line
shows the checked source revision and current mode. This run did not have actual
browser access, so rendered-frame and browser-input measurements remain unrun;
all machine-readable browser timing fields remain null.

The independent benchmark alternates actual policy values or an initial-resident
health value, then checks the resulting value through the real host and submits
an ordinary policy input. It keeps separate source-save/detection, compilation,
HTTP-ready and HTTP-input measurements. It restores the edited file byte-for-byte
and refuses to overwrite a concurrent editor's change. Run it only in an isolated
worktree. The checked evidence and exact measured scope are in
[development evidence](DEVELOPMENT-EVIDENCE.md).

## Why this split

[GHC 9.6.7 documents mixed compiled and interpreted modules](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html#loading-compiled-code).
The compiled dependency closure must stay compiled. [Cabal 3.12's component REPL](https://cabal.readthedocs.io/en/3.12/cabal-commands.html#cabal-repl)
provides the actual package database, language extensions, dependencies and source
roots; the launcher does not maintain a second hand-written GHC configuration.
It uses `--repl-options` for GHCi options and disables multi-repl so the simulation
package remains compiled. The development project also sets
`-fomit-interface-pragmas` for `red-dune-live`: optimized module bodies remain,
but consumers cannot inline their exported implementations or use exported
strictness information. Implementation-only edits therefore invalidate fewer
modules. This has a measured runtime cost; it is not the release profile. Every
optimized acceptance component still uses the original project. The package's printed build-profile `-O1` is not sufficient to
infer effective per-component flags: the Colony stanza explicitly retains `-O2`.

This is an experimental Linux development route, not a general hot-reload system,
a cross-platform launcher, or permission to expose the loopback host publicly.
