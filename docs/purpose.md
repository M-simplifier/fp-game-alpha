# Research direction and the public alpha

The long-term aim is a **pure functional game engine**. Its design and APIs are
being refined by building different concrete games and comparing what those
games need. This alpha makes the useful implementation knowledge, shared code
and development workflows available while that research continues.

## Why publish an alpha now?

[Garden of Afterlight](https://github.com/M-simplifier/garden-of-afterlight)
already shares a game implementation and skills for building other games.
This foundation brings that reusable knowledge together with the subsequent
common libraries and reference games. A developer and their AI can use the
current techniques to make their own game, then improve it through play.
They do not need to wait for the eventual engine to be complete.

The immediate outcome is an independently editable game with its own rules,
working host and continuation instructions. The [new-game workflow](new-game.md)
starts from its brief. The [terminal starter](terminal-starter.md) provides one
small, tested example of that workflow; it does not define the intended range
of games.

## How concrete games shape the shared design

A shared abstraction should explain a rule or boundary that different games
actually need. Similar record layouts alone are a weak reason to share an API.
Keep each game's vocabulary and identify both the common law and the behavior
that must stay specific to it.

| Concrete problem | Current material | Boundary to retain |
| --- | --- | --- |
| Repeat inputs and compare an adapter with the original rules | [Transition and Arena](architecture.md) | One authoritative transition; chronological outputs; whole input boundaries |
| Preserve repeated commands and distinguish active from paused time | [Tapline](../references/tapline/README.md) | Ordered commands and the game's own clock semantics |
| Reject a repeated turn without confusing it with a legal failed action | [Station Dispatch](../references/station/README.md) | Protocol admission, domain refusal and observation have different jobs |
| Reconstruct a multi-day game from persisted state | [River Home](../references/river/README.md) | Validated saves and the actual rules used after resuming |
| Edit a world while maintaining derived rendering and host resources | [Afterlight](../references/afterlight/README.md) | Pure world authority and separately verified graphical hosts |

The [technical guides](practice/README.md) also retain lessons about types,
temporal composition, spatial reasoning, resource lifetimes and performance.
They explain when a technique helps and how to check it. An example need not
use every technique, and the shared core does not prescribe one renderer or FRP
network for every game.

## What counts as progress

A useful increment lets someone create or improve a real game, or resolves a
specific design question raised by one. For a new development route, record
the brief, the first playable interaction on the requested host, the change
made after playing, and how work continued in the independent project.

For a candidate shared API, record the concrete difficulty, the repeated law,
the game-specific remainder and a case where the abstraction would distort
the game. Use those observations to keep, revise or remove it. This is how the
engine design develops; it is not a requirement to finish every research
experiment before publishing the next useful increment.

Technical guarantees and the quality of play need their own evidence.
[Types, tests and formal tools](guarantees.md) establish different kinds of
claims under different assumptions. Source-informed [headless play](headless-play.md)
can examine decisions, while actual input, presentation and player experience
need their corresponding checks. More passing tests alone do not establish
that a game is enjoyable.

The [roadmap](roadmap.md) records selected work and remaining gaps. Publish each
usable result with its scope and reproducible evidence, then use new games and
user feedback to decide what the common design needs next.
