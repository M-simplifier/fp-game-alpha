# Opt-in Haskell build/check feasibility probe

**Linux-only feasibility prototype: a useful bounded success, not a replacement release.** This standalone executable proves that the current Python build/check orchestration can run in Haskell without adding dependencies to a game. Keep the usable alpha and its Python/editor entrypoints unchanged. The next worthwhile step is review and a deliberately scoped portable build/check package, not a whole-tool rewrite.

Historical scope: the recommendations below describe the 2026-10-04 experiment,
not the current product entrypoints. The former Python reference is preserved
only as a [frozen test oracle](../../../tools/acceptance/fixtures/python_cli/README.md).

For the maintained successor, use the [native tooling guide](../../../docs/native-tooling.md).
This frozen feasibility evidence is not substituted for that package's current
Linux/Windows/macOS acceptance results.

## Scope and layout

- `app/Main.hs`: typed `Command` (`Build` / `Check`), project-root wrapper, typed source-config decoder and `Result` (`Executed` / `Failed`); effectful interpreter and aeson JSON encoder
- `fp-game-probe.cabal`, `cabal.project`, `cabal.project.freeze`: independent tool dependency boundary
- `bin/fp-game-probe`: locally built Linux x86_64 executable, **not installed**
- `tests/contract.py`: independent fixtures and differential reference checks; Python is a test oracle, not a runtime dependency of the executable
- `evidence/`: local-only exact build logs, measurements, result records, dependency closure and hashes (excluded from a source-only copy; tests recreate their results directory)

There is no `plan`, `scaffold`, `test`, `run`, `doctor`, play protocol or editor rewrite. Unsupported commands exit 2 with usage. During the isolated trial, no foundation repository or user machine was changed and no downloads were performed. This directory publishes only the reviewed research sources; the normal game-development tools remain unchanged.

## Use

```sh
# Installed toolchain plus existing pinned dependency cache only:
export PATH=/path/to/ghc/bin:/path/to/cabal/bin:$PATH
export CABAL_CONFIG=/path/to/existing/cabal/config
./build-offline.sh

./bin/fp-game-probe build --project /path/to/game --json
./bin/fp-game-probe check src/Main.hs --project /path/to/game --json
cd /path/to/game
/path/to/fp-game-probe check --json
```

The example paths must be replaced with your existing toolchain/cache; this is not a redistributable bootstrap. The executable subsequently selects the **game's** `ghc` / `cabal` from PATH; it does not embed or silently replace the compiler used for game work. It can return a clean missing-tool error even when no GHC/Cabal is on PATH. Building it from source still requires a Haskell compiler and cached dependencies. No compiler-free installer or supported binary release has been created.

### Root semantics and compatibility

`--project` is resolved relative to caller cwd, canonicalized, and wins over cwd. Unlike the Python script's default of its own repository root, this standalone executable deliberately defaults to caller cwd. Its installation/source directory is never treated as a game root; it has no template root. Python comparisons always pass an explicit project. This is an intentional opt-in interface difference, not a drop-in-allcommands claim.

- `build` and argument-less `check` dispatch `cabal --config-file=... build all --offline --builddir=...`
- File `check` dispatches GHC with existing `-fno-code -fforce-recomp -XGHC2021 -Wall -fdiagnostics-color=never` flags and local include directories
- All children use argument arrays and target-project cwd, never a shell command string
- Game Cabal state is target-local `.build`, with repositories disabled and its own store/cache; the aeson tool store never enters the game project
- Existing `.hs` files and source directories must canonicalize inside the selected project, including symlink resolution
- `fp-game.json` source_dirs are decoded as UTF-8 JSON and `[FilePath]`; missing config uses the Python default directories
- JSON result field sets, exit status, stdout/stderr separation, child nonzero propagation and replacement decoding of malformed output bytes match the tested Python contract. Whitespace/key order and operating-system exception wording need not match
- Validation errors use `status:error`, `exit_code:1`, empty stdout and a descriptive stderr; spawn errors retain the executed-command result schema
- Text mode writes captured stdout/stderr to their respective streams
- Temporary check directories are removed. On POSIX, a dedicated process group is killed and reaped on timeout, SIGINT or SIGTERM, including descendants that retain the output pipes. SIGTERM is explicitly translated to a main-thread exception so cleanup finishes before exit 143; external cancellation does not emit a JSON result
- Default timeout is 180 seconds, as in Python. A probe-only `FP_GAME_PROBE_TIMEOUT_SECONDS=1..180` setting permits bounded timeout tests

Safety improvements over current Python behavior: malformed config shapes fail cleanly instead of uncaught TypeErrors; external `.build` symlinks, linked Cabal config files and line-breaking project paths for Cabal config are refused. These are not an adversarial filesystem race-proof sandbox; the project remains trusted developer input.

## Measured evidence (2026-10-04, Linux x86_64)

Toolchain: GHC 9.6.7, Cabal 3.16.1.0. Build flags `-O1 -Wall -Werror -threaded`. No GHC API dependency.

| Measurement | Observed |
|---|---:|
| Final source, fresh tool build directory, **warm pinned dependencies** | 6.907 s |
| Peak child RSS during that build | 318,200 KiB |
| Executable size, unstripped | 21,211,112 bytes |
| Warm missing-tool dispatch, median of 20 | 12.47 ms |
| Warm missing-tool dispatch, minimum of 20 | 12.24 ms |
| Independent base-only game, fresh `.build` | 1.993 s |
| Same game, warm `.build` | 43.1 ms |
| Non-bundled dependency units in resolved tool closure | 41 |
| Existing cached unit directories, summed apparent regular-file bytes | 118,632,423 bytes |

The cache footprint includes existing library artifacts, not a measured download size, minimum installation size, or additional runtime requirement. Shared cache data existed before this experiment. Cold-cache acquisition time, dependency download bytes and source-build time for dependencies were **not measured**. GHC/Cabal installation cost is excluded. Individual wall times are local observations, not universal benchmarks.

`ldd` reports libc, libm, libgmp and the system loader; no path into GHC's library tree. Relocation was tested on this machine, not on a clean distribution/architecture.

### Important bootstrap failures retained as evidence

1. Setting `active-repositories: :none` for the tool made the cached third-party packages unknown to Cabal's solver (`bootstrap-none.log`). This is fine for the base-only game, not the tool dependency setup.
2. Plain `--offline` with the cached index selected newer uncached transitive versions and refused to download (`bootstrap-unpinned.log`). It did not fetch them.
3. Pinning cached versions/flags in the separate freeze file produced a fresh successful tool build entirely offline. This demonstrates a meaningful version/cache-management burden that a production release must solve. A source package alone is not “no setup.”

## Tests and reproducibility

```sh
FP_GAME_REFERENCE=/path/to/reference/tools/fp_game.py python tests/contract.py
```

The harness requires an existing FP_GAME_REFERENCE file and ghc/cabal on PATH; optional FP_GAME_GHC_BIN / FP_GAME_CABAL_BIN variables add their bin directories. It creates fixtures only in this probe directory. `evidence/contract-results.json` contains 64 recorded CLI invocations, plus the harness separately checks usage, SIGINT and SIGTERM cancellation. The 64 include 20 repeated startup probes; they are not 64 independent test scenarios. All passed on the final implementation:

- Python/Haskell exact validation JSON comparisons: nonexistent source, wrong suffix, absolute escape, linked source escape, escaped declared directories, missing GHC/Cabal, nonexistent project
- Fake executable paths containing spaces/Japanese: argument arrays, literal semicolon in project name, UTF-8 output and replacement for invalid bytes, exit 7, argument-less check as build
- Real GHC/Cabal on a tiny independent project using only bundled base: build, whole-project check, file check and real compiler type-error exit
- CRLF source containing Japanese text; explicit project from unrelated cwd; standalone cwd default
- Malformed JSON, invalid UTF-8 and wrongly typed source_dirs
- Relocated project and copied executable both work from the new location, with old project path absent during the checks
- Plain text stdout/stderr separation; unsupported commands refused
- Timeout, SIGINT and SIGTERM with an actual spawned descendant: delayed-write marker never appears; check temporary directories are asserted absent after each case. SIGTERM exits 143
- A found executable with an invalid interpreter produces a clean command-result spawn failure
- External build-state and Cabal-config symlinks are refused without overwriting the linked file

Reference: inspected Python source is hashed in local-only `evidence/sha256.txt`. It is supplied read-only through FP_GAME_REFERENCE. Fixtures are authored here and do not copy the alpha or invoke scaffold.

## Limits and recommendation

This is Linux/POSIX-only today (`unix` is a declared dependency). Windows process/job cleanup, Windows drive/case/Unicode behavior, macOS packaging, fresh-machine relocation, compiler version breadth, hostile concurrent path replacement, output-size limits and very large logs are untested or unimplemented. Whole-project builds do not inspect source_dirs, matching Python's Cabal dispatch. Child output is fully captured in memory, also matching Python. This is not a secure execution sandbox. SIGKILL, abrupt runtime crashes and power loss cannot run cleanup; no cleanup guarantee is made for them.

The tool's current base bound/freeze is intentionally pinned to the measured GHC 9.6.7 environment, not a claim that orchestration requires GHC 9.6.x. A portable release should broaden and test tool compiler support independently of a game's selected compiler.

Proceed only with an opt-in reviewed build/check slice if the ~21 MB executable and reproducible dependency-bootstrap work are acceptable. Keep game core offline and wrappers unchanged until release packaging, cross-platform cleanup and acceptance are established. Scaffold planning and durable play/editor semantics deserve separate trials; this result does not establish their migration safety.

## Source-only distribution boundary

`SOURCE-FILES.txt` is an exact allowlist for a possible later source-only research copy. Never recursively copy this directory: `bin/`, all build directories, generated fixture work, raw `evidence/`, caches and local configuration are private working products and excluded. `SUMMARY.json` contains only path-free aggregate observations from this measured run. The source-only research copy does not publish a binary release.

This implementation derives the command contract and some orchestration logic from the MIT-licensed fp-game-alpha tools; `LICENSE.upstream` preserves that original notice. New probe source is distributed under the accompanying MIT LICENSE; retain LICENSE.upstream for the derived command contract. No third-party Haskell source or binary is included by the allowlist. Before distributing a compiled executable, audit and fulfill notices/licenses for the exact aeson/temporary transitive closure and linked runtime/system libraries; this prototype has not completed a redistributable-binary license audit. The freeze file identifies package versions, not a license clearance.

Portable cancellation requires deliberate platform-specific design and testing. The current `unix`/process-group approach does not implement Windows Job Objects, Windows console/control events, or a tested macOS process strategy; removing the unix dependency alone would not establish parity.
