# Headless play: let an AI make the decisions

Headless play exposes a game as observations, choices and consequences. An AI
can actually play through the original rules without driving a graphical UI.
The resulting transcript supports investigation of decision trade-offs,
confusing feedback, repeated mistakes and learning. It is not merely a suite
of scripted correctness checks, and it does not establish that humans find
the game fun.

## The first game: Station Dispatch

The initial adapter uses the six-order Station game. On each turn the player
chooses `express`, `local`, or `defer`, balancing energy, express tickets and
delivered feeling. Six successful choices produce an authored ending.
Unaffordable choices can be refused without advancing the turn.

The Haskell `station-headless` process accepts line-oriented commands and
emits JSON Lines player packets. Its player operations are observation and
`act <expected-turn> <choice>`. It runs the existing Haskell game kernel;
there is no Python reimplementation of Station's costs or endings.

`tools/play.py` provides `start`, `observe`, `act`, and `report` operations,
with an explicit `--session` JSON file. It reconstructs the session through
the Haskell kernel on each call. This makes the saved action history a
replayable input record rather than a second authoritative game state.
Use the command's help for the exact argument syntax.

### Try the bundled pilot

From the repository root, with GHC available:

```sh
python tools/play.py start --session .build/my-play.json --exposure source-informed
python tools/play.py observe --session .build/my-play.json
python tools/play.py act --session .build/my-play.json --turn 1 --choice local --request-id move-1 --reason "Save a ticket while making this delivery"
python tools/play.py report --session .build/my-play.json
```

Read the returned packet and choose the next move; do not pre-fill later turns
from a walkthrough. Replace the turn with the visible current turn. Retry a
request with exactly the same ID and payload after an uncertain response;
reusing an ID with different payload is rejected. A successful retry returns
`retry: true` and the original `observation`. Use a new session filename to start
over. `--exposure` is a provenance declaration, not verified isolation.

The helper compiles the Haskell host on first use into `.build/headless` using
GHC and its bundled packages. It downloads nothing and never calls an LLM API.
Build caches and journals are local trusted files, not signed attestations.
A leftover `.lock` after interruption requires checking that the writer stopped
before removing it. The journal replacement is atomic on the same filesystem,
but this is not a power-loss durability or multi-machine storage guarantee.

No external LLM service is mandatory. A human, a scripted policy or an AI
with tool access can operate the same session. Model access, model cost and
policy choice belong to the caller.

## A player loop

1. Start a session and record the player's prior exposure to the game
2. Read only the current player packet and the rules intended for players
3. Choose an action and optionally record a short reason or expectation
4. Submit the action with the expected turn and a request ID
5. Read the actual feedback before choosing again
6. At the ending, or at the attempt limit, inspect the report and transcript

An expectation such as “I am saving a ticket because another delivery may
need it” is useful evidence to compare with later choices. It is a report
from the policy, not proof of its internal causal reasoning. Do not ask a
player to produce or reveal private chain-of-thought; a brief decision
summary is enough.

### What the player may know

Player packets provide the current situation, intended visible options and
feedback. They must not serialize raw authoritative state or future orders.
Station's existing `StationView` already exposes the current choices' costs
and immediate resource results through `Domain.choices`; those are part of
this adapter's visible decision table, not newly granted future lookahead.

Observation is not a universal “list everything legal in the game” oracle.
In other titles, an action grammar or current affordances may be appropriate
without revealing whether an undiscovered action will succeed. Never expose
future choices, solutions or hidden conditions simply because the domain
exports a function that can retrieve them.

The saved session and report record observations, actions, reasons and
feedback. They are useful for continuing the run and reviewing what happened.
Diagnostic access to source code, tests, exhaustive state exploration or
future order definitions is a separate evaluation mode. An evaluator who
has read those materials must not describe their own subsequent run as a
fresh or blind novice run.

This transport is not an operating-system security sandbox. Restrict the
player's actual tools and files when an experiment requires enforced
information isolation. Merely telling a source-reading agent to forget the
source is insufficient.

## Replay, freshness and retries

The Python session records a source fingerprint and rejects replay against
incompatible source. Keep a session with the version that created it, or
start a new run after a relevant change. Replaying the same inputs checks
the game's continuation; it does not guarantee an LLM will independently
choose the same actions again.

`--request-id` identifies an action attempt so a retry can return the saved
result rather than dispatching twice. Reuse an ID only for the same request.
The expected turn prevents an old turn's command from being applied to a
new turn. These solve different problems: a refusal may leave the current
turn unchanged, while retry identity still distinguishes that attempted
request from a new decision.

Runs are bounded at 256 attempts. Reaching the bound is an evaluation limit,
not an authored ending. Record truncation separately from completion. Keep
protocol/transport rejection separate from an admitted in-world refusal:
`Game.Arena.play` admits the submission before invoking the domain, while
Station's `Refused` result represents a choice the game itself declined.

Session history is not permission to rewrite authority. Do not edit saved
observations to pretend a different playthrough occurred. Preserve the
original run when experimenting with a changed policy or presentation.

## Evaluate choices, not just wins

Start with explicit questions:

- Does conserving a scarce ticket create a consequential later decision?
- Does always taking the largest immediate value perform nearly as well as
  deliberate planning?
- Does feedback make a refused action understandable, or does the player
  repeat it without learning?
- Do materially different strategies remain viable?
- Does replay improve planning, or merely memorize the fixed six-order script?

Keep three kinds of evidence distinct:

- **Fresh-context play:** a new policy context receives only permitted player
  information and declared rules. This does not prove the underlying model
  never encountered a public game during training
- **Learned play:** a policy deliberately retains prior player transcripts or
  lessons. Record which material was retained
- **Diagnostic analysis:** source-aware/exhaustive inspection studies the
  rules and possible outcomes. Its conclusions may explain a run afterward,
  but must not be supplied as hints to a run labelled fresh

Record model/policy identity, prompt or policy version, visible-information
profile, source version, exposure, attempts, outcomes and completion status.
Compare policies using the same information contract and budget. A cheap
random or immediate-value-greedy baseline helps distinguish genuine planning
from a game that rewards almost every choice. Do not treat the proportion of
winning terminal histories in an exhaustive tree as the win probability of
a random policy; paths need not have equal probability.

A report can document strategy differences and observable mistakes. An
omniscient optimal route is a diagnostic upper bound, not a fair definition
of what an uninformed first-time player should have known. Small batches
are exploratory evidence, not population estimates of human difficulty.

## Costs and limits

This interface avoids screenshot interpretation and UI manipulation, but no
general speedup is asserted. The Python wrapper replays earlier actions on
each call, trading implementation simplicity and inspectability for repeated
kernel work. A sequence of growing histories can therefore require quadratic
total replay work in its number of attempts. Station's tiny bounded episodes
make that a reasonable initial trade-off; longer games may need a persistent
host or validated checkpoints.

Measure protocol calls, kernel execution, replay cost, model latency and
observation/token volume separately. They are different quantities. A
benchmark of this six-turn protocol is not a benchmark of graphical
performance, the entire framework, or AI gameplay in general.

Headless evidence can reveal trivial strategies, weak trade-offs, confusing
rules and tedious repetition. It omits embodied controls, animation timing,
visual discovery, sound, emotional response and much of pacing. AI completion
or self-reported enjoyment does not establish human enjoyment. Validate
experience hypotheses with human players and the intended presentation.

## Architecture and future adapters

The reusable seam already exists:

- `Game.Arena.observe` provides the participant view
- `admit` compiles a checked submission and context into the original input
- `play`/`attempt` preserve original transition and rejection semantics
- `Game.Transition.trace`/`replay` support recorded kernel inputs

Do not duplicate game rules in the transport or add a mandatory reward
function to `Arena`. Games own their endings, objectives and scoring. The
current `Arena` class does not define generic reset or terminal methods.

Lantern is a natural second adapter for visible spatial planning. Present its
board geometry and current positions clearly; keep exhaustive successor
search in the diagnostic interface. Its arena is explicitly fully observed.

River is a later test of exploration and longer-horizon planning. Its current
`RiverView` omits some spatial/crop/wood information that a graphical player
may see, so establish a fair player-view contract before blaming confusion
on the rules. Movement uses 30 Hz logical boundaries. Bounded, interruptible
macro-actions can expand into ordinary ticks, retaining every original
boundary for replay and stopping at relevant discoveries. Teleportation or
loading authored scenario endpoints is not equivalent to playing there.

For simultaneous or hidden-information games, collect submissions without
revealing another participant's current choice, and filter outputs and
rejection messages as carefully as observations. Keep host-owned clocks,
randomness and future external context out of player packets. A recorded
seed alone may be insufficient to reproduce external events; record the
actual consumed context when adding such games.

## Prior art

[OpenSpiel's official concepts](https://openspiel.readthedocs.io/en/latest/concepts.html)
distinguish game/state objects, player observations or information states,
actions, terminal states and chance transitions. This project reuses the
observation/action discipline without requiring its games to adopt a complete
search-tree framework.

[TextWorld's official API](https://textworld.readthedocs.io/en/stable/textworld.html)
provides command-driven environments and configurable returned information.
Optional fields include admissible commands, world facts and winning command
sequences. That is a useful reminder to declare the exact observation profile:
a debugging aid can silently change the difficulty of a gameplay experiment.

See also [the local architecture](architecture.md) and
[Station's reference documentation](../references/station/README.md).

## Checked evidence and current limits

[One actual source-informed AI episode](../research/headless/README.md) records
six decisions and a later replay after transport validation fixes. This is not
a blind trial or a speed benchmark. The local end-to-end contract suite checks
visibility, narrative, idempotency, stale and oversized turns, affordability,
terminal behavior, source/replay drift, locking and journal budgets.

Run `python tools/test_play.py` to exercise the actual Haskell process. CI includes
it on Windows, macOS and Linux; inspect the current run before claiming a platform
passed. `refusal_kind` separates `protocol`, `domain`, and `none` in packets.
The report keeps protocol mistakes distinct from in-game affordability refusals.

The player bridge is currently Station-specific. A common Arena already supplies
the shared semantic boundary, but every new game still needs an intentional
observation/command projection. The skill does not pretend that arbitrary new
projects automatically have a working headless adapter.
