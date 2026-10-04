---
name: play-game
description: Play and evaluate an implemented pure functional game through player observations and actions, recording evidence about choices and experience rather than merely running tests.
---

Read [the player workflow](../../../docs/headless-play.md). Start with the
Station pilot and the user's evaluation question. Record prior exposure honestly;
a player who read the implementation is source-informed, not a blind novice.

Use tools/play.py start → observe → act → report. Decide from the current player
packet, submit its visible turn with a unique request ID, and read the consequence
before deciding again. Brief optional decision summaries are enough; do not ask
for private chain-of-thought. Never fabricate a completed playthrough or a score.

Distinguish authored endings from host truncation. Report concrete choice points,
confusing feedback, repetition and trade-offs with turn/request references.
Separate measured outcomes, player interpretation and human-playtest hypotheses.
Replay/solver analysis is a separate diagnostic activity, never a blind run.
