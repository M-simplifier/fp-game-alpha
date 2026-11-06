# PURE / FALL independent semantic audit

Read-only review, observed 2026-10-26 22:42 JST. No production or test edits;
no native windows or host input were launched or controlled by this reviewer.

Source snapshot under `snapshot/PureFall`:

- Core.hs SHA-256 `D48E9E0A7D96388D2BE0CE713B3477D23A4E086C0EDC1F7F00F2604D2190A522`
- Session.hs SHA-256 `68F60EB71B2643C3EA0C47E50A83131CFCA71FA3B77F29FC01A975BB4E1E8E6C`
- Existing Spec.hs observed hash `396CAA17CEDAD35EA48C5627D41E3BAF0026CAA5A607DD73927EBBC33E3F26B6`

The executable scratch probes use GHC 9.14.1 `runghc -XGHC2021`, with `-i`
arguments for the snapshot and unchanged vendored game-arena/game-transition
sources. They do not import the implementation's private constructors.

## Findings communicated to parent and main implementer

1. Short horizontal taps can disappear before the first semantic tick.
   Native `Main.readInput` supplies horizontal direction only as `Held`.
   `advanceFrame 5000 [] (Held Leftward False)` followed by
   `advanceFrame 11667 [] (Held Neutral False)` executes one tick but leaves
   the initial I at x=3, instead of x=2. Adding an edge alone also fails:
   `[MoveLeft]` plus `Held Leftward False` moves to x=1 due to age-zero repeat.
   The edge queue and initial-repeat policy must be repaired together.

2. Failed hold discards the ordered remainder of a tick input.
   After using hold, `[SwapHold,HardDrop]` locks zero pieces, while
   `[HardDrop]` alone locks one. `Core.applyCommands` stops for every SwapHold,
   even when it fails. The same sequence can accumulate across zero-tick
   native frames, so a later drop disappears after an unavailable hold.

3. Session restore accepts invalid rewind metadata and impossible cues.
   After HardDrop then MoveLeft, replace history with the current saved game
   at `length trace`. `restoreSession` accepts it, and rewind no longer goes
   back at all. Prefix equality does not establish a piece boundary or proper
   history order. Separately, a fresh empty-trace session accepts
   `[Finished Won,Cleared(Clear [23,23] NoSpin 12345 True True)]` as its cues.
   These violate the promised validation of temporal contradictions.

`Audit.hs` reproduces each case. It additionally records an exposed Session
closure gap: tickSession records an admission-rejected 33-command input, so
its own checkpoint subsequently rejects restoration. This was provided as
supporting boundary evidence, not a separate player-facing priority.

## Independent rule check

`RotationOracle.hs` uses an explicit 28-orientation cell table and separate
down-positive SRS constants, independent occupancy checks, and six fixed
boards. At the above Core snapshot:

- 9,408 oriented-cell probes: zero mismatches.
- 57,502 rotation probes from legal states: zero mismatches.

Existing collapse tests use a separate row-grid model; witness and replay
equalities use production transitions and alone cannot validate the meaning
of those transitions. The independent boundary cases above target that gap.

## Final independent retest: closed

All findings above were repaired by the main implementer. One adjacent
counterexample in the first repair showed an age-8 DAS timer firing in the
same tick as a fresh left press after a zero-tick release: x=2 moved to x=0
instead of x=1. `RepeatProbe.hs` records the exact 16667/133333/5000/11667 us
frame partition. The final repair restarts DAS age at the new press.

Final snapshot taken 2026-10-26 22:56:19 JST:

- Core.hs SHA-256 `D24A697E6343F8839C2D285B08748CE245E20ED5988441851F112687E96C88C3`
- Session.hs SHA-256 `4725CE4E7BE95C69C3E32F51F417FE8B972A8EC52808296C618A0B8FD5FBC870`
- Main.hs SHA-256 `48D945FB660504A6C0B67B5F3841040096840A721B3CBCFF3046964E6A6CA926`
- Spec.hs SHA-256 `99AC754C22E9FC2E1BB7710301593A7A7BF8C40E04DB0D453B395327C82FA2F0`

The snapshot is retained in `final/PureFall`, with host source in
`final/Main-host.hs`. Native `readInput` now actually emits horizontal press
edges, matching the repaired protocol checked below. This was source
inspection; no native input was controlled by the auditor.

`Retest.hs` passes all 10 focused checks: sub-tick tap retention, edge+held
single movement, constant-held frame partition, release/repress DAS restart,
failed hold/drop order, invalid history rejection, impossible cue rejection,
admission rejection/codec closure, rewind branch restore, and branch replay.
Output is retained in `final-retest-output.txt`.

The independent rotation oracle was rerun on the final Core: all 9,408
oriented-cell and 57,502 rotation probes still match. Output is retained in
`final-rotation-output.txt`. No unresolved material finding remains in this
bounded audit.

From this exported source folder, reproduce the current-code checks with:

```powershell
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/Retest.hs
runghc -XGHC2021 -isrc -ivendor/game-arena/src -ivendor/game-transition/src comparison/audit/RotationOracle.hs
```

The original audit examined its dated final-source snapshot. The paths above
examine the exported current source; record new source hashes when testing edits.
Private raw audit logs are not part of this public source selection.

The useful causal result is that the original replay/path equalities could
remain true while a physical input was never represented, or while a saved
prefix was mislabeled as a piece boundary. Explicit input observations and
independent invalid examples distinguished those errors. The first repair's
sibling DAS case shows why the behavioral condition mattered more than only
the first failing sequence. No new global rule or memory promotion is needed.

This is bounded rule/input/codec evidence; it does not establish native feel,
human enjoyment, complete Guideline compliance, or a full formal proof.
