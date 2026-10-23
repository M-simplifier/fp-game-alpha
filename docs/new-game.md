# From a game brief to a working game

Invoke `$new-game` in this clone with a game idea and target platform. The AI
builds an independent game around that brief and the small `game-transition` /
`game-arena` core, then plays and revises its first usable slice. References such
as Afterlight demonstrate techniques; they do not determine the new game's
world, genre or renderer.

## Choose the first playable result

Reuse decisions already made. Resolve only missing choices that affect what the
player can do, the required device/input, or the first observable result that
will tell us whether the idea works. Destination and licensing need a decision
when they affect the work being created, not a repeated questionnaire.

Write the agreed loop, platform constraints and a concrete acceptance in
`GAME-SPEC.md`. Use [game-experience](../.agents/skills/game-experience/SKILL.md)
for choices, progression and feedback. Revise uncertain design choices through
play; keep human feedback separate from deterministic replay evidence.

## Write the game's own rules

Use [the kernel contract](architecture.md), [Haskell guidance](haskell.md) and
only the [technical practice](practice/README.md) relevant to the next boundary.
Define this game's state, inputs, effects and observations. `Step` / `Machine`
can express its transition; `Arena` adds participant admission and observations
when needed. Neither requires an ECS, an FRP network or a scoring scheme.

Apply [readable rules from the first slice](haskell.md#write-readable-rules-from-the-first-slice)
while writing the first mechanic. A reader should see which state a decision
uses, which refusal wins, and where one rule can change. Keep rules in the pure
core; input, clocks and resources belong to the host, and rendering projects
the result. A helper or abstraction needs a concrete responsibility.

Pair a new rule with checks that distinguish a plausible wrong version: verify
the result, ordered feedback and retained state on refusal. Choose invariant,
property, replay or compiler/API checks where they add evidence; see
[verification practice](practice/games/verification.md). Treat supported saves
as a compatibility boundary and test the chosen migration/refusal policy.

## Prepare the requested host and an independent workspace

Create the game outside this checkout unless the user chose otherwise. Pin the
shared core to a reviewed revision or vendor its source with versions, hashes
and notices. Keep editable game source, host, tests, assets and continuation
instructions inside the game. An accidental sibling checkout is not a dependency.

Use [setup](setup.md) and [platform records](platforms.md) for the actual host.
Investigate an unverified route, build a small real input/rendering probe, then
connect the core. Report actual installation/access blockers. A terminal test
does not satisfy a graphical or browser request. Keep build, real input/display,
deployment and device-performance evidence distinct.

The CLI's [terminal-adventure starter](terminal-starter.md) is optional. Its
flags do not limit a hand-authored game or justify substituting its platform.
[Native tooling](native-tooling.md) owns bootstrap and operational commands,
including the separate tool/game compiler choices and the Windows profile
recipe. Preserve existing settings and wrappers. Machine-local profiles and
build output must be deliberately recreated after relocation.

Carry the [formatter helper and lock](formatting.md), select owned source roots,
and verify setup plus the game checks. Use [editor wrappers](editors.md) or
[Haskell Design](haskell-design.md) when needed; editor/HLS integration is a
separate check from a CLI build. Do not make every optional tool a prerequisite
for a small playable change.

## Implement, play and continue

Implement the first meaningful rule, connect actual host input and visible or
audible feedback, and run it. Play the slice, fix its most consequential gap,
and rebuild the changed path without regenerating the workspace. Procedural
or self-authored assets can keep the slice small; record third-party asset
origins and redistribution obligations when used.

[Headless play](headless-play.md) can test abstract decisions once this game has
an action/observation adapter. The Station pilot is an example, not a universal
adapter. Source-informed analysis is not a blind novice trial; headless play
does not replace target-host input, graphics or audio checks.

Add a local `$game-dev` entry pointing to the current spec, commands, selected
guides and next requirement. Keep technical knowledge reachable by copying
needed guides with notices or linking to a reviewed public commit. For
player-facing work, retain the `game-experience` entry and its three linked
documents, or their pinned public links. Make [learn-code](learn-code.md)
available for later explanations of this game's actual code. None of these
routes should require private memory or the original conversation.

Record what ran, what changed through play and the remaining limits. A scaffold
smoke test proves its example route; successful development means the user's
brief became a game on the requested host with a meaningful revision cycle.
