# Start and continue an independent game

Launch Codex in this clone and invoke `$new-game` with your game idea. The
project-local skill routes to this document. Codex searches repository
`.agents/skills` locations; see [the official skill discovery guide](https://learn.chatgpt.com/docs/build-skills).
An assistant is optional: the CLI and normal Cabal commands also work directly.

## Only ask for missing decisions

Use the request, existing project data and doctor output first. Ask at most
four compact questions, combining related decisions when useful:

1. Game name and the smallest interesting player action/feedback loop
2. First target/rendering route, selected from the actual support contract
3. Independent destination directory, usually beside this foundation clone
4. Game license/credit, only if the user wants to choose it now

Detect the OS/tools instead of asking again. Keep VSCode, Neovim or terminal
editing optional. Do not ask about scores, engines, networking or deployment
before the requested loop needs them. If the user requests an unverified
graphics/Web/mobile route, disclose the gap and choose it for explicit route
development only with their instruction. Never silently substitute terminal.
Use the [guarantee scope](guarantees.md) when a game's requested invariant
needs stronger evidence than finite gameplay tests.
Unspecified licensing remains **unlicensed for user additions**; original
foundation/template MIT notices remain separate.

## Executable path

The initial maintained template is a native terminal adventure. It provides
one complete turn/input/view loop, an explicit Machine/Arena adapter, validated
versioned saves, config, regressions and independent build/CI. It is the first
development route, not the full platform ambition or a commercial certification.

```sh
python tools/fp_game.py doctor
python tools/fp_game.py plan my-game "../My Game" --title "My Game"
python tools/fp_game.py scaffold my-game "../My Game" --title "My Game" --dry-run
python tools/fp_game.py scaffold my-game "../My Game" --title "My Game"
cd "../My Game"
python tools/fp_game.py build
python tools/fp_game.py check
python tools/fp_game.py test
python tools/fp_game.py run --smoke
python tools/fp_game.py run
```

Plan and dry-run perform no filesystem writes. Scaffold rejects an existing
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
Consult [verification](verification.md) for measured results; a configured
workflow or planned renderer does not count as completed acceptance.
