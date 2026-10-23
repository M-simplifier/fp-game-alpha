---
name: new-game
description: Turn a game brief and target platform into an independent playable pure functional Haskell game; use the terminal scaffold only when it fits the brief.
---

Follow [the intent-first workflow](../../../docs/new-game.md). Reuse the user's
brief and existing decisions; ask only about missing choices that change the game.
The references teach techniques, not mandatory genres, hosts or layouts.

Use `$fp-gamedev`, `$haskell-excellence` and `$game-platform` for the implementation
and actual target host. Use [game-experience](../game-experience/SKILL.md) when
choosing player actions, feedback, progression or copy. Read only the guidance
needed for the next decision.

Apply [readable rules from the first slice](../../../docs/haskell.md#write-readable-rules-from-the-first-slice)
while writing the first mechanic. Expose which state each decision sees and
where one isolated rule can be tuned. Test the result, effects and state retained
on refusal; do not postpone clarity to a later cleanup.

Use [native tooling](../../../docs/native-tooling.md) for the optional terminal
scaffold and operational commands. Preserve the game's compiler/profile; the
CLI bootstrap selects its own compiler. Formatting and editor setup have separate
requirements in [formatting](../../../docs/formatting.md) and
[Haskell Design](../../../docs/haskell-design.md).

Deliver and play a real slice on the requested host, revise it, and verify the
changed path. Keep an independent workspace with its spec, notices, pinned core
and local continuation entry. Carry the selected guides and optional
[learn-code](../../../docs/learn-code.md) entry with it as the workflow describes.
A renamed template or an unverified host route does not complete game development.
