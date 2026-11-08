<a id="technical-practice-and-research-sources" name="technical-practice-and-research-sources"></a>

# Technical practice and source guides

Use this guide to find implementation techniques and the work that informed
them. [The reading guide](../../research/README.md) and
[catalog](../../research/catalog.json) connect current implementations, examples,
experiments, open questions and historical results. Select knowledge for the
problem in front of you; there is no obligation to read every document before
writing a game. The [game-research skill](../../.agents/skills/game-research/SKILL.md)
helps an AI follow that question to source and evidence without choosing one
engine or representation for your game.

The Haskell and game practice guides below preserve the technical substance of
the original public `haskell-excellence` and `fp-gamedev` reference guides. Their
import provenance remains distinct from the newer authored guides.

Source: [public Afterlight skills](https://github.com/M-simplifier/garden-of-afterlight/tree/6367b56e3ff2042199667f2a5bfa50695f4aaf2f/.agents/skills).
The MIT notice is retained in [LICENSE.upstream](LICENSE.upstream).
[PROVENANCE.json](PROVENANCE.json) records source paths/hashes and adaptations.
The new routers are authored for this foundation; old project-specific defaults
and confirmation scripts are not inherited as universal instructions.

## Reach the newer studies

- Procedural nature, streamed worlds, typed graphics and GPU ownership:
  [Stillroom](../../research/stillroom/README.md)
- Continuous composition, finite sounding tails and path-dependent ambience:
  [music and time](../../research/stillroom/music-and-time.md)
- Function, array and relation models of game rules, including their different
  legality/reachability questions: [three Tetris studies](../../research/frontiers/README.md)
- Free interpreters, composition and counterexamples to stronger architectural
  claims: [interpretation and composition](../../research/frontiers/composition.md)
- Earlier transitions, participant observations, formal work and failed transfer
  assumptions: [earlier work and findings](../../research/history/README.md)

These are reading routes, not required dependencies for a game. The catalog's
status describes what exists; its evidence and limits say what was actually
checked. Read the selected implementation and its assumptions before reuse.

## Choose by the current design problem

- Haskell types, errors, effects, cancellation, laziness and abstractions:
  [technique choices](haskell/technique-choices.md)
- Totality boundaries, independent oracles, generators, shrinking, resource tests:
  [verification and review](haskell/verification-review.md)
- Input edges, held controls, tick scheduling, FRP continuation and save meaning:
  [time and state](games/time-and-state.md)
- Coordinates, rendering projections, geometry/cache and resource ownership:
  [space and resources](games/space-and-resources.md)
- Multiple actors, reservations, moving frames, rollback and numerical physics:
  [simulation](games/simulation.md)
- Allocation, profiling, semantic preservation, FFI/native optimizations:
  [performance](games/performance.md)
- Packaging and actual host checks: [stack](games/stack.md)
- Browser event loop, input, persistence, Wasm ABI and rendering:
  [browser](games/browser.md)
- Game-level verification: [verification](games/verification.md)
- Selective implementation reading: [code reading](games/code-reading.md)
- Editor setup: [historical guidance](games/editors.md) and
  [current alpha capabilities](../editors.md)
- A concrete illustration, not a template requirement:
  [Afterlight source map](games/afterlight.md)

- Colony simulation, save compatibility, long sessions and physical policies:
  [Red Dune source and check route](../red-dune.md)

## Read the evidence at its actual scope

The preserved guides and newer studies make the material readable and
discoverable. Their presence does not by itself port the original Haskell Design
reader/editor executable, run new browser/device checks, or demonstrate a fresh
arbitrary game brief end to end. The original
`map`/`outline`/`show` reader and the current saved-source `inspect`/`context`
helper are different capabilities. Do not claim they are equivalent.

Some source-map links pin an older Afterlight example commit explicitly. They
remain historical illustrations. Use the imported reference's current README
for its current alpha layout and commands. No original gameplay structure,
raylib default, tick frequency or project-specific constant is required for a
new game. A new design uses the shared core and whichever knowledge is relevant.
