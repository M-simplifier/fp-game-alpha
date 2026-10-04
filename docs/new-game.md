# From a game brief to a working game

Invoke `$new-game` in this clone and give the AI your game idea and target
platform. The goal is a **new game designed for that brief**, normally built
from scratch around the small `game-transition` / `game-arena` core. Afterlight
and the other references are sources of tested ideas, not mandatory templates,
genres, renderer choices or inherited worlds.

The AI should own the technical preparation and implementation loop so the
user can concentrate on the game. A generated directory or an inventory of
unsupported platforms is not the requested outcome.

## 1. Recover the intent, ask little

Reuse what is already known. Ask only about decisions that change the game:

- What does the player do, and what makes that decision interesting?
- Required platform and interaction: browser, desktop, phone, controller,
  mouse, touch, multiplayer, or a particular visual/HTML presentation
- The first playable result that will tell us whether the idea works
- Destination or license only when it must be chosen now

A full brief can answer all of these; do not repeat a fixed questionnaire.
Record a short `GAME-SPEC.md` with the intended player loop, necessary platform
constraints and a concrete observable acceptance. Keep uncertain design choices
explicit and revise them through play, not through an ever-growing preflight.

## 2. Design this game's types and boundaries

Read [the core API](architecture.md), [Haskell practice](haskell.md) and the
[relevant game-development guidance](practice/README.md). Define domain vocabulary, authoritative
state, inputs, effects and observations for this game. Reuse `Step` / `Machine`
and add `Arena` where participant actions and observations need it. The core
must not force a particular ECS, FRP network, scoring scheme, renderer or
representation.

Keep gameplay rules in the Haskell core; adapt platform input to those rules
and interpret their outputs at the shell. Rendering is a projection, not a
second simulation. Choose additional mathematical structure when it helps a
real invariant or composition; do not add abstractions just to resemble a
reference.

Inspect only relevant reference modules for a concrete problem: ordered input,
fixed ticks, saves, asset ownership, browser ABI, or another needed boundary.
Copying a whole existing game and changing its title does not satisfy a new
brief. Any reused implementation must keep its notices and be justified by
this game's requirements.

## 3. Prepare an independent workspace and its actual platform

Create the game outside this foundation checkout unless the user chose otherwise.
Use ordinary Cabal packages and pin the shared core, either as a fixed source
revision or vendored source with package versions, per-file hashes and notices.
The game must own its editable source, platform host, tests, assets, spec and
continuation instructions. It must not depend on an accidental sibling checkout.

Use [setup](setup.md) and [platform records](platforms.md) as evidence and recipes.
A planned or unverified route is work to perform for the requested platform,
not a reason to silently generate a terminal game. Research the required official
toolchain, choose bounded dependencies, build a tiny real host/input probe,
then connect the new core. Report actual access/installation blockers promptly;
do not claim a platform works just because a different host's core test passed.
Respect permissions for tool installation, downloads and deployment.

The current `fp_game.py scaffold` command is an **optional terminal-adventure
example**, not a universal generator or a requirement to use this workflow.
Its limited flags must not limit the AI's ability to author a different Cabal
project and host. See [that example's commands](terminal-starter.md) when the
requested game really fits them. Compiler inspection/editor tools can also be
used independently; see [tooling](tooling.md) and [editors](editors.md).

## 4. Implement a real playable slice, then continue

1. Implement the brief's first meaningful rule and its domain tests
2. Connect actual input and a visible or audible consequence on the target host
3. Build and run that slice; inspect the result instead of stopping at compilation
4. Play it, identify the highest-impact gap, and change the game
5. Rebuild and verify the changed path without regenerating the workspace

Use procedural/self-authored assets when practical; record third-party provenance
and redistribution obligations when needed. Add saves, networking, performance
work and deeper guarantees when the slice actually requires them. Do not wait
for every engine experiment to finish before delivering a working increment.

Add a local `$game-dev` entry routing to that game's `GAME-SPEC.md`, commands,
architecture and next requirement. It should continue the current project,
not repeat setup or force a reference layout. User edits are authoritative;
never regenerate over them.

## 5. Build the harness around the game

Pair the behavior with useful checks: invariant-preserving constructors,
compiler/API rejection tests, property tests, deterministic replay and appropriate
formal tools. See [guarantee scope](guarantees.md) and
[the prevention ledger](failure-prevention.md). Review/playtest findings should
lead to a mechanism preventing their class where feasible, not just a patch.

For abstract play, add a player projection and action adapter and use
[headless gameplay](headless-play.md). The supplied Station pilot is an example;
it is not automatically an adapter for every new game. Keep source-informed
analysis separate from fresh-player evaluation. Headless play complements
real-host checks for controls, graphics, sound and device performance.

When game rules change, update their own tests and save compatibility deliberately.
Historical parity with an old game is useful to preserve that reference; it is
not a requirement that a new game's intentional behavior remain identical.

## Acceptance of this development experience

Success means a concrete brief became its own game, using the shared core and
relevant knowledge, on the requested target, with one meaningful play/feedback/
revision cycle. Record what ran, what changed, and the remaining limits. A template
smoke test, terminal-only check for a graphical request, copied demo or a polished
research catalog is not a substitute. Existing evidence for the optional terminal
starter remains useful but does not establish this broader workflow on every
platform.
