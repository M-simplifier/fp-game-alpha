# Technical guidance for continuing this game

To understand this game's actual code, start with the local
[learn-code guide](learn-code.md) or ask your AI for `$learn-code`.
It traces a chosen action through the real types, rules and checks, assuming
no prior Haskell experience. The copied guide does not depend on the starter checkout.

Use the local [Haskell technique guide](practice/haskell/technique-choices.md)
and [verification guide](practice/haskell/verification-review.md) for types,
errors, effects and meaningful checks. The following public references cover
game-specific decisions when the project grows beyond its initial loop.

These reading links pin foundation commit
`dba7da9e3162a0b1c0a59cfe138142d063ef0cfc`, where the original technical guides
were restored. They require network access and are not build dependencies.
The vendored code's revision is recorded separately in `foundation.lock.json`.

| Current problem | Read |
| --- | --- |
| Input edges, fixed ticks, clocks, FRP or save meaning | [Time and state](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/time-and-state.md) |
| Coordinates, collision, derived render data or native resources | [Space and resources](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/space-and-resources.md) |
| Multiple actors, moving frames, reservations or rollback | [Simulation](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/simulation.md) |
| Allocation, caches, FFI or measured performance | [Performance](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/performance.md) |
| Trace tests, independent models, real-host checks or proof scope | [Game verification](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/verification.md) |
| Native builds, resources or packaging | [Stack and packaging](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/stack.md) |
| Browser loop, input, storage, Wasm or WebGL | [Browser boundaries](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/games/browser.md) |

The [full knowledge index](https://github.com/M-simplifier/fp-game-alpha/blob/dba7da9e3162a0b1c0a59cfe138142d063ef0cfc/docs/practice/README.md)
includes source provenance, notices, implementation examples and limits of the
historical editor guidance. Examples do not determine this game's genre or host.
For offline reading, retain selected documents with their MIT notice and check
their local links. When updating these references, review the new guidance and
record the new commit deliberately; do not silently follow a moving branch.
