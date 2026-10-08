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

Use [game-experience](../.agents/skills/game-experience/SKILL.md) when choosing
what the playable slice should let someone try and enjoy. It routes separately
to experience/progression and UI/Japanese guidance; read only what changes the
current design decision, and keep human feedback separate from replay evidence.

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

Keep the relevant technical knowledge reachable from the new game's local
continuation guide. Copy selected guides with their notices, or link to a
reviewed public commit and record that revision. Include guidance for the game's
timing, input, saves, rendering or performance when those boundaries matter.
Opening the new game in a later AI session must not require private memory or
the original foundation checkout to rediscover these instructions. Public
reading links may require network access; they must not become build dependencies.

For player-facing work, keep the `game-experience` skill and its three
`docs/game-experience/` documents reachable from the local continuation guide.
Copy that small bundle with the foundation license and revision while retaining
its relative links, or link to a reviewed public commit. This is part of the
intent-driven workflow; the optional terminal scaffold does not install it
automatically. A later AI session should find the design knowledge without
private research notes or the original conversation.

Use [setup](setup.md) and [platform records](platforms.md) as evidence and recipes.
A planned or unverified route is work to perform for the requested platform,
not a reason to silently generate a terminal game. Research the required official
toolchain, choose bounded dependencies, build a tiny real host/input probe,
then connect the new core. Report actual access/installation blockers promptly;
do not claim a platform works just because a different host's core test passed.
Respect permissions for tool installation, downloads and deployment.

The native `fp-game create` command provides an **optional terminal-adventure
example**, not a universal generator or a requirement to use this workflow.
Its limited flags must not limit the AI's ability to author a different Cabal
project and host. The [native tooling](native-tooling.md) owns operational
planning, creation, doctor, build, test, check and run: diagnose before GHC,
explicitly bootstrap once, then continue with the copied native source/executable. Preserve the chosen destination and
keep tool dependencies separate from game dependencies. See [that example's commands](terminal-starter.md) when the
requested game really fits them. Compiler inspection/editor tools can also be
used independently; see [tooling](tooling.md), [editors](editors.md), and
[Haskell Design / haskell-editor-setup](haskell-design.md) for structured
map/outline/show reading and the original design-view adapters. Keep its guide
or a pinned public link reachable in the new game when using it.

When an explicit compiler choice is needed, follow the
[Windows compiler-profile recipe](native-tooling.md#windows-explicitly-select-the-installed-compiler).
Probe the actual installed executable; do not silently change versions, rewrite
PATH or bypass an alias. `-CompilerPath` selects the separate tooling bootstrap,
while the game uses its own Cabal project selection. Inspect and preserve any
existing local profile or compiler wrapper. Add a compiler-only
`cabal.project.local` exclusively when absent, using a raw forward-slash
absolute path; keep it ignored and out of copied/generated source. Recreate it
deliberately for a relocated workspace. Native doctor/check follow Cabal's
selection and fail rather than guessing another compiler. The experimental native
CLI/terminal-workspace profile passed actual three-OS CI at `be1208af`, including
Windows Japanese paths and independent continuation; the native guide links the
exact jobs. Continue the requested game's real build, tests and host-specific
play checks instead of treating that bounded profile as every game's acceptance.

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
architecture, selected technical guides and next requirement. It should continue the current project,
not repeat setup or force a reference layout. User edits are authoritative;
never regenerate over them.

Keep an optional `$learn-code` entry available in that independent workspace,
using [the code-learning guide](learn-code.md). Copy the small skill/guide bundle
with its notices and revision, or preserve an existing equivalent. It should
explain this game's actual current code to a Haskell beginner when asked;
learning is not a prerequisite for asking the AI to build or change the game.

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

## Own the formatter setup too

For a hand-authored game or the optional scaffold, carry the
[project-local formatter helper and lock](formatting.md) into the chosen game
directory, declare owned source roots, and run plan/install/check within the
user's permissions. Keep formatting separate from compiler/HLS provisioning.
Continue through actual game implementation and verification; a setup plan
alone is not the requested playable result.
