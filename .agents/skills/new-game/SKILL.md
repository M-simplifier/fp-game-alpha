---
name: new-game
description: Turn a game brief and platform requirements into a new playable pure functional Haskell game using the shared core and relevant technical knowledge; continue beyond setup into actual gameplay implementation.
---

Read [the intent-first workflow](../../../docs/new-game.md), then the relevant
[core API](../../../docs/architecture.md) and [platform evidence](../../../docs/platforms.md).
Use `$haskell-excellence`, `$fp-gamedev` and `$game-platform` for the relevant
implementation decisions, without loading unrelated guides.
Use [game-experience](../game-experience/SKILL.md) for the desired play, later
choices, UI/help and Japanese copy; read only the reference needed now.
Use `$haskell-editor-setup` when structured code reading or an editor setup is
needed; [Haskell Design](../../../docs/haskell-design.md) supports independent games.
Reuse known decisions and ask only for missing game-changing requirements.

Design this game's domain types, rules, observations and host from its brief.
References teach techniques; they are not mandatory generation templates.
The terminal scaffold is optional and must not substitute for another target.
Use the [native tooling](../../../docs/native-tooling.md) for create-plan/create,
doctor/build/test/check/run: check prerequisites, bootstrap explicitly once, then
use the local binary. On Windows, use `.build/tools/fp-game.exe` and its explicit
compiler recipe when needed:
probe the actual installed executable, preserve existing Cabal settings/wrappers,
and distinguish bootstrap `-CompilerPath` from the game's own compiler profile.
Never overwrite `cabal.project.local`, rewrite PATH or silently switch versions.
Keep that ignored machine-local profile out of generated source and recreate it
deliberately after relocation. Native doctor/check honor Cabal selection and
fail without a PATH fallback; a bounded compiler probe is not full acceptance.
Keep the chosen game folder independent and retain copied continuation source.
The separate `tools/inspect_haskell.py` needs Python and PATH GHC/GHCi for
inspect/context; formatter, player and reader tools retain their own setup.
Own environment preparation, implementation and verification within permissions.

Deliver a real playable slice on the requested host, then revise it from play.
Keep an independent workspace, pinned core, game spec and local continuation
entry. Stop at a genuine blocker, not merely at a route marked unverified.
Use [headless play](../../../docs/headless-play.md) for abstract decision feedback
and real-host checks for presentation and input. Never claim checks not run.

Make [learn-code](../../../docs/learn-code.md) reachable in the independent game
so the user can later understand its actual types and rules. Preserve the small
skill/guide bundle, notices and source revision without overwriting existing work.

For every new Haskell workspace, own the [pinned formatter setup](../../../docs/formatting.md):
copy the reusable helper/lock, choose owned source roots, inspect the plan and
explicitly install within permissions. Run check/write/check and game tests.
This applies to games authored from a brief; the template is optional.
Propose editor-local external Ormolu settings without overwriting existing files.
When the helper has no platform route, investigate an official installation or
build within permissions and verify it before extending the repeatable helper.
A missing tool route does not narrow the game brief or end authorized work.
