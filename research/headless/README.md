# Station: one actual AI play episode, not a fun benchmark

A source-informed AI made six sequential choices through `tools/play.py`, reading
each observation before the next decision. The sequence was express, local,
express, defer, express, local. It ended at **19 delivered feelings**, one energy,
zero tickets and **やさしい一日**. This is a single anecdotal episode, not a
blind-player experiment, optimization result or statistical evaluation.

- [Original journal](station-original-source-informed.json) preserves the exact
  source fingerprint and player packets captured during those decisions. It is
  historical evidence and is deliberately rejected by the current replay helper
  because transport validation changed afterward.
- [Final-transport replay](station-source-informed.json) re-executes the same
  actions through the current Haskell Arena. All player packet fields matched
  the originals, except for the newly added `refusal_kind` classification.
  Replaying old decisions is not a second independent AI playthrough.

From the repository root:

```sh
python tools/play.py report --session research/headless/station-source-informed.json
```

Do not extend the checked-in example in place; use a fresh local session for play.
The helper rejects a source fingerprint change rather than silently rewriting
history. Later source revisions may require a separately documented replay.

## Observations and hypotheses

- At turn 4, express delivery was unaffordable after earlier choices. Defer
  restored energy and advanced to the next order. This is a concrete consequence,
  not merely narrative feedback.
- At turn 6, no express tickets remained. Earlier dispatches constrained the last
  decision, while local delivery was still possible.
- The player's short decision summaries referred to warm bread and a music event.
  This suggests retaining authored narrative in the abstract view can matter to
  evaluation. It does not prove that narrative caused the choices; a controlled
  numeric-only comparison has not been run.
- “Next service” may suggest that the same order can be retried after resting,
  but the rule advances to the next order. That is a usability hypothesis worth
  testing with fresh players, not a reported misunderstanding in this
  source-informed run.

The prototype measures choices and outcomes. Graphics, input feel, audio,
long-term engagement and human enjoyment remain outside this episode.
