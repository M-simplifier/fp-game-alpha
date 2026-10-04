# Bounded alpha DX experiment

## Source ownership and baseline

New game source, physics, level, SVG art, browser controls and tests were authored
from the Signal Courier brief. This is not an Afterlight fork. The work is an
isolated checkout with edits confined to references/signal-courier. The baseline
local commit is 21d5793090e87a1b52d0e60a1f3682653bdbf741; its tree is
98b10f200fb44a3302b90a6cedeb35e7c98daf45, independently supplied as the exact
public main 6526ef6 content tree. The public merge object itself was not fetched.

Code reused: vendored game-transition/game-arena 0.1.0.0, MIT notices, the
pinned formatter helper/lock, Paper Circuit's WASI reactor/link flags, stable
pointer/string lifecycle pattern, JS WASI loader and checked-in WASI shim.
Paper Circuit's later catalog/tuning API was deliberately removed: this game
has a fixed authored level, not a tuning system. No gameplay implementation,
world, asset or simulation code was copied from the reference games.
All art is original procedural SVG primitives. Browser/system fonts are used.

Knowledge reused: new-game intent-first workflow; haskell-excellence domain
boundaries and verification scope; fp-gamedev pure authoritative transition;
input-edge retention, fixed ticks, focus clearing and resource ownership.
Pinned public entry points (reading references, not build dependencies):
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/new-game.md
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/architecture.md
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/practice/haskell/technique-choices.md
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/practice/haskell/verification-review.md
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/practice/games/time-and-state.md
- https://github.com/M-simplifier/fp-game-alpha/blob/6526ef6/docs/practice/games/browser.md

## Form, not framework

Session and Level constructors are opaque. A closed compiled level avoids
unchecked external geometry. Room/platform records describe geometry, not an
ECS. PlayerView exposes observable state. Courier supplies Machine's associated
types; Arena only admits exactly one Rider command and calls the same step.
There is no duplicated arena physics or artificial finite-state game solver.
Every move is fixed integer arithmetic. Counters and coordinates saturate or
reset within explicit bounds. The session retains no growing input history.
The short input replay is a test artifact, not live-session storage.

Readable transition path: Tick -> clamp horizontal movement -> calculate jump
or gravity -> find descending platform crossings -> collect optional stamp ->
fall/checkpoint or delivery. Named fields distinguish grounded, parcels and
phase; ordinary ADTs/record updates suffice. List membership handles three
stamps; no generic inventory machinery is warranted. A future custom-level
editor would need a checked constructor and a newly verified witness.

## Actual checks and iteration

Native GHC 9.6.7 -Wall -Werror and actual GHC-Wasm 9.14 build. Ormolu 0.9.0.0
plan/install used a verified existing cache, then check/write/check; no global
install, new heavy dependency or editor mutation.

- Default constructive witness: 422 active ticks (7.03 simulation seconds),
  three deliveries, zero falls, final x1728/y300. Trailing commands are harmless
  after win. The test writes every command to .build/witness.txt.
- Scenic constructive witness: 605 active ticks (10.08 simulation seconds),
  all three stamps and deliveries, zero falls. Written to .build/scenic-witness.txt.
- All 8-command sequences through depth 6 from initial satisfy the supplied
  invariant (262,144 leaves); this is bounded enumeration, not induction.
- Compiler negative test rejects direct Session construction.
- Replay split at tick 100 agrees in state and chronological effects; Arena
  restart reaches initial; invalid input codes rejected; falls restore the
  last delivered checkpoint (tested beyond beacon one); idle shift saturates at 10,800 ticks and supports retry/reset.
- Node executes the actual compiled Wasm and Haskell SVG renderer: default and all-stamp wins,
  independent sessions, rejected codes, timeout/retry/restart, close/use-after-
  close and 200 allocation/render/free cycles. Host scheduler unit tests cover
  no-tick input retention, single jump edge, opposing keys, clear and long-frame cap.

Headless feedback cycle: an initially mistimed witness failed, and its jump
positions were corrected using the interpreter. A naive optional-route script
walked into a canal; the revised trace first crosses it, jumps onto the middle
roof, then ascends to the stamp. All three optional routes are now explicitly
executed. This corrects route assumptions without claiming subjective fun.

## Limits and useful workflow gaps

No actual browser UI or touch-device playthrough was performed: localhost
browser access was already blocked and that restriction was not bypassed.
Node/Wasm is not DOM event delivery, visual layout, accessibility, focus/device
behavior or subjective feel evidence. No broad performance benchmark or memory
leak proof is claimed. Generated SVG output is structural evidence only.

The skill guidance usefully prevented a terminal substitute and whole-game
copy. It did not provide a generic portable fixed-tick SVG host or fixed-point
platformer recipe; these were authored. GHC 9.14 exports foldl' from Prelude,
so qualified Data.List avoided a cross-version -Werror mismatch. Reusing the
newer Paper Circuit loader initially exposed an irrelevant catalog export;
removing that game-specific lifetime contract fixed the actual runtime test.

This is a compact vertical slice with three similarly structured rooms, not a
content-complete commercial game. Next justified acceptance is actual browser
and phone play, then tune readability/jump feel from observations. No claim is
made that all platformers are solvable, that arbitrary levels are reachable,
or that the framework proves fun. No GitHub write or deployment was performed.

## Independent review prevention changes

Two concrete boundary defects were corrected before completion:
- Multiple physical sources can own the same action. Track event.code/pointerId
  tokens and release only that token; tests cover keyboard aliases, key+touch,
  two fingers and clearing. A single Set of action names loses ownership.
- When the advertised duration includes the final tick, execute its gameplay
  before terminal timeout selection. Win takes precedence over timeout on that
  tick. Native and Wasm tests now idle 10,378 ticks then win on tick 10,800;
  idle timeout and one-past-terminal inputs remain bounded and unchanged.
These rules are conditional on the host/clock contract, not universal mandates
for all games. The copied learning guide's optional example link was pinned
publicly rather than left as a missing file in the independent game.
