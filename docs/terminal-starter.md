# Optional terminal-adventure starter

Use this example when the requested game fits a turn-based terminal adventure,
or when you deliberately want to study a small independent workspace. It can
be created with the CLI and ordinary Cabal commands without an assistant.
For a different brief or platform, follow [the new-game workflow](new-game.md).
`$new-game` starts from that workflow and selects this example only when useful.

Choose the game name, destination and any requested license using decisions
already made. The commands below implement native/terminal only; their flags
do not constrain which games the broader development workflow may create.
Unspecified licensing remains **unlicensed for user additions**; original
foundation/template MIT notices remain separate.

## Executable path

The maintained terminal template provides
one complete turn/input/view loop, an explicit Machine/Arena adapter, validated
versioned saves, config, regressions and independent build/CI. Its acceptance
record applies to this example's development route.

First follow [native bootstrap](native-tooling.md) once in the clone. Then,
from that clone on Linux/macOS:

```sh
.build/tools/fp-game doctor
.build/tools/fp-game create-plan my-game "../My Game" --title "My Game"
.build/tools/fp-game create my-game "../My Game" --title "My Game" --dry-run
.build/tools/fp-game create my-game "../My Game" --title "My Game"
.build/tools/fp-game build --project "../My Game"
.build/tools/fp-game check --project "../My Game"
.build/tools/fp-game test --project "../My Game"
.build/tools/fp-game run --smoke --project "../My Game"
.build/tools/fp-game run --project "../My Game"
```

On Windows use `./.build/tools/fp-game.exe` and the native guide's explicit,
separate tool/game compiler selections. To continue from the game folder,
bootstrap the copied source once and use its local executable. Relocation does
not carry build output or machine-local compiler profiles; deliberately recreate
the required selections on the destination machine.

`create-plan` and `create --dry-run` perform no filesystem writes. `create` rejects an existing
destination, including an empty directory or symlink, and reserves a new
directory exclusively. A failed write leaves an explicit incomplete marker,
never a success report. The defaults are native/terminal and unlicensed
additions; `--target` and `--rendering` cannot make an absent route work.
An explicit MIT game license uses `--license MIT --author "Your credit"`.

## Continue into the user's actual game

Write the agreed mechanic and next observable result in the generated
`GAME-SPEC.md`. The game owns editable `src/`, `app/`, `test/`, `assets/`,
`config/`, `docs/` and a local `.agents/skills/game-dev/` entry. Continue from
that directory with `$game-dev` and its versioned development guide.
The local technical-guide index also links to selected public game-development
knowledge at a fixed revision. These reading links do not affect offline builds.

Implement a real change after scaffolding: for example a collectible that
unlocks the exit. Change the state, authoritative rule, feedback/view, save
policy and blocked/unlocked regressions. Build/test/play that change. Then
continue with the next requirement. Do not end at a renamed template or a
demonstration run when the user asked for game development.

The generator vendors kernel source pinned to exact package versions and an
immutable upstream commit, with per-file hashes and versioned canonical docs.
The game directory builds after the starter clone is unavailable. There are no
required absolute paths, floating main refs or sibling checkouts. Framework
updates cannot rewrite user game code. Review API/contracts, pins, docs and
save migrations explicitly when upgrading; no automatic migration is promised.

## Acceptance

The maintained end-to-end check generates outside the starter clone, adds a
key/locked-exit mechanic, verifies both branches and persistence, copies only
the game into an isolated path with spaces, builds/runs using its own files,
then adds and tests a second gameplay change without regeneration. That
sequence establishes a development route on each host where it actually runs.
Consult [native tooling](native-tooling.md#verified-ci-and-local-measurements) for measured results; a configured
workflow or planned renderer does not count as completed acceptance.
