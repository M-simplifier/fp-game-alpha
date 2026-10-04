# Haskell tooling consolidation: an incremental design

Status: source-grounded proposal plus a bounded Linux feasibility trial, 2026-10-04. This is not an implemented replacement or a claim of Python-free distribution.

## Decision

Move maintained developer-facing application logic toward Haskell. Start with an opt-in `fp-game` executable that has a typed generation plan and the existing build/check command contract. Keep the currently usable alpha available during this work. Preserve the tiny game core's independent dependency boundary.

The benefit is not merely fewer language names. The useful target is one authoritative interpretation of project configuration, supported actions, generated-file ownership, and verification results, reused by humans, AI agents and editor adapters. Haskell is already required for game development, so compiling a development tool is a reasonable supported path. It does not imply that a source-only tool can diagnose an absent compiler, or that players need GHC installed.

## Current source boundaries

### Developer CLI: first candidate

`tools/fp_game.py` owns doctor, build/test/run dispatch, compiler checks, GHCi inspection, path validation, isolated Cabal configuration and JSON output. `tools/scaffold.py` owns the optional terminal starter's generation plan: accepted names, target choice, licenses, vendored source, hashes, local configuration and CI. Neither implements gameplay.

A useful Haskell design separates:

1. External observations: requested game information, current tools, source snapshot, destination state
2. A pure planning function returning either explicit errors or a finite plan of selected source files and required operations
3. A small effect interpreter that executes argument arrays, creates exclusively, writes atomically where required, and reports actual results

The plan must explicitly distinguish text assets from binary assets and portable sources from local outputs. The PR15 scaffold incident demonstrates why: recursive directory copying admitted ignored reader binaries and caches and applied text normalization to binary bytes. Haskell types can make the intended distinction enforceable inside the tool; they do not replace filesystem validation, race handling or explicit distribution selection.

Proposed types are conceptual, not yet an API: `Command`, `ProjectLayout`, `ValidatedDestination`, `SourceAsset`, `GenerationPlan`, `ExecutionResult`, `ToolFailure`. Do not create a general orchestration framework before a concrete CLI slice needs it.

### Headless play host: second candidate

`tools/play.py` already delegates gameplay to Station's Haskell `HeadlessMain` and Arena. Its own responsibilities are source-bound replay, JSON journals, request IDs, locking, atomic writes, byte/attempt limits and reports. Porting it can remove Python from normal play tooling and share protocol types, without rewriting the game.

This is a later slice because durability semantics are consequential. Preserve replay equivalence, refusal categories, huge-turn rejection, idempotent retries, stale-source rejection, concurrent writer exclusion and byte budgets. Do not silently convert existing journals or move hidden game state into player observations.

### Haskell Design: consolidate duplicated meaning

Parsing, declaration projection, selection and pagination already live in native Haskell. Rewriting TS JSON adapters would provide little additional semantic value.

There is genuine duplication to investigate:
- `src/auditScope.ts` parses Cabal stanzas independently, whereas `native/src/HaskellDesign/Scope.hs` uses Cabal-syntax
- `src/projectConfig.ts` / `src/compiler.ts` and native `Verify.hs` overlap configuration and helper policy

A shared Haskell scope/configuration API could remove disagreement between editor audit and CLI reading. It must carry the editor's actual requirements: unsaved overlays, dependency invalidation, cancellation, batch verification, trust and clear unknown results. Current APIs are not interchangeable merely because names are similar.

### Platform boundaries to retain or narrow deliberately

- Browser DOM events, focus, resize, downloads, WebGL/WASI transport and browser storage still need host integration. Paper Circuit's rules and SVG are already Haskell; its JS is a thin host
- VSCode extension APIs and webviews naturally use its Node/browser extension host; Neovim configuration uses Lua. A Haskell backend can centralize decisions behind these adapters without replacing every callback
- C FFI and shader languages describe real native/GPU interfaces
- Afterlight asset preparation uses fontTools. Rewriting its launcher does not remove that optional Python dependency
- The independent unbounded-integer oracle and cross-language acceptance tests provide useful implementation independence. Keep them until there is a reason beyond uniformity to replace them

Maintainer-only publication scanning, documentation lint and provenance tools are portable policy and could later share Haskell manifest code. They are lower priority than everyday game-development commands and should not block public alpha use.

## Build and distribution choices

The current core and generated terminal game use GHC-bundled packages with repositories disabled. Do not add aeson, Tree-sitter or an editor tool's native dependencies to that root merely to make a CLI convenient.

Use a separate tool package/project. Prefer sound JSON/process/path libraries over hand-writing them to claim zero dependencies. Record and bound cold dependency acquisition, cache reuse and supported GHC versions. The tool compiler and a game's selected compiler may differ; ordinary CLI orchestration should not inherit the GHC-API analyzer's 9.6.x restriction.

Two distinct entry paths need honest support:

- GHC/Cabal already installed: build the pinned CLI once, then reuse the executable; Cabal supports executable targets and script build/run, so Python is not intrinsically required
- No Haskell toolchain: use an explicit minimal bootstrap or verified OS/architecture binary. A source-only Haskell doctor cannot run before GHC exists. Do not introduce opaque installers, silently change the game's compiler, or promise prebuilt releases before they exist

Windows, macOS and Linux binaries are separate deliverables. Dynamic libraries, executable permissions, architecture and relocation require actual checks. The recent Linux inference-helper change is a concrete caution: dynamically linking the GHC API improved the tested build, but adds a dependency on that selected compiler's shared libraries. That optional helper is separate from compiler-free native syntax reading.

## Review refinements

A second review of the proposal identified four requirements to carry into the trial:

- Measure CLI acquisition with GHC/Cabal installed but no dependency cache separately from later game builds. Until consumers switch, the current VSCode/Neovim wrappers and copied game tools still invoke Python; an opt-in Haskell command does not eliminate that dependency by itself
- Give the tool installation, template/source distribution and target game separate roots. Respect explicit `--project`, document current-directory behavior, and keep relocated games usable without the foundation. On Windows avoid rebuilding or overwriting an executable while it is running
- A typed plan proves properties of its input snapshot. Applying it must still exclusively create the destination and reject pre-existing files or changed conditions. Differential tests compare against intended specifications as well as the current implementation; known bugs are not compatibility requirements
- Unify reader scope results, configuration/source dependencies, watcher inputs, exclusions, limits and fingerprints together. Never present saved-disk verification as proof of an unsaved editor buffer

## First implementation slice and acceptance

Start beside the current tools, not by deleting them:

1. `plan`: construct the optional starter's file plan and typed validation errors
2. `build` / `check`: dispatch to the selected compiler/Cabal with the existing argument and JSON contract
3. `scaffold`: apply the validated plan only after the pure output and failure behavior match

Keep plan/scaffold explicitly optional. This must not make arbitrary new-game creation depend on a fixed starter or genre.

Acceptance compares old and new behavior on the same fixtures:
- Commands, JSON schema, stdout/stderr separation and nonzero exit handling
- Generated file bytes and LF hashes, with only explicitly documented metadata normalization
- Invalid names, unsupported combinations, missing tools, path escapes, existing destinations and linked inputs
- Spaces, Japanese text, CRLF, Windows drive/case behavior and executable paths
- Cancellation/timeouts and no detached compiler/linker work continuing unnoticed
- Reader build products, caches and local configuration do not change generated contents
- Relocate the new game, remove access to the original foundation, then change and run the game again
- Cold setup, warm startup, dependency/disk cost and OS-specific behavior are measured, not estimated as universal results

Only switch the ordinary entry when this concrete slice works. Preserve existing CLI wrappers during migration. Migrate play after its persistence contracts have parity; consolidate editor scope/configuration as a separately scoped change.

## Evidence and primary references

Source inspected: public alpha PR15 (including explicit scaffold selection fix), current Python tools, Haskell Design TS/native implementation, and browser/editor adapters. A separate Linux-only build/check feasibility probe was subsequently implemented; it is not the maintained replacement CLI.

- [Cabal 3.12 command and script support](https://cabal.readthedocs.io/en/3.12/cabal-commands.html)
- [GHCup installation and toolchain management](https://www.haskell.org/ghcup/guide/)
- [VSCode extension host environments](https://code.visualstudio.com/api/advanced-topics/extension-host)
- [Reader restoration and bounded current verification](https://github.com/M-simplifier/fp-game-alpha/pull/15)

## Executable feasibility trial

The [source-only probe](probe/README.md) implements just build/check orchestration in
Haskell. Its [aggregate evidence](probe/SUMMARY.json) records 64 checked invocations
against the Python contract and independent assertions: actual offline base-only game
builds, invalid inputs, Unicode/metacharacter paths, explicit project roots, relocation,
JSON/exit behavior and POSIX timeout/cancellation cleanup. The default project root
is deliberately caller cwd, unlike the old copied script's location; parity comparisons
pass explicit project paths. No normal CLI, editor wrapper or generated-game entrypoint
was switched.

A fresh tool build using already-cached pinned dependencies took 6.907 seconds here;
the unstripped executable is 21.2 MB. The cached non-bundled dependency closure has
41 units totaling about118.6 MB of apparent files. These are local observations, not
download sizes or cold-install measurements. Plain offline resolution initially chose
uncached versions and failed; a separate freeze file made the cached build reproducible.
This supports feasibility while exposing setup cost that language uniformity alone
does not remove.

The probe explicitly depends on unix for process groups. Windows/macOS cancellation,
clean-machine distribution and a binary dependency-license audit remain unfinished.
Only reviewed text source and path-free summary data belong here; no binary, cache or
raw machine log is distributed. Cold-cache acquisition remains unmeasured. The next
step is a portable opt-in package and consumer/cold-start validation, not an automatic
replacement of all Python tools.

Independent review also found that the initial prototype did not clean up child
processes on SIGTERM. An explicit main-thread termination path now performs cleanup
and exits143. Separate SIGINT/SIGTERM regressions check descendant termination and
immediate temporary-directory removal. SIGKILL, crash and power-loss cleanup are
not claimed. This is another reason to validate process semantics before replacing
existing consumers.
