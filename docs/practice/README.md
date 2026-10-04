# Technical knowledge preserved from the original skills

These canonical documents preserve the technical substance of the public
`haskell-excellence` and `fp-gamedev` reference guides, instead of reducing them
to a short readability checklist. Thin project skills select the relevant guide;
there is no obligation to read every document before writing a game.

Source: [public Afterlight skills](https://github.com/M-simplifier/garden-of-afterlight/tree/6367b56e3ff2042199667f2a5bfa50695f4aaf2f/.agents/skills).
The MIT notice is retained in [LICENSE.upstream](LICENSE.upstream).
[PROVENANCE.json](PROVENANCE.json) records source paths/hashes and adaptations.
The new routers are authored for this foundation; old project-specific defaults
and confirmation scripts are not inherited as universal instructions.

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

## What this restoration does and does not establish

It restores documentation and discoverable skill routes. It does not by itself
port the original Haskell Design reader/editor executable, run new browser/device
checks, or demonstrate a fresh arbitrary game brief end to end. The original
`map`/`outline`/`show` reader and the current saved-source `inspect`/`context`
helper are different capabilities. Do not claim they are equivalent.

Some source-map links pin an older Afterlight example commit explicitly. They
remain historical illustrations. Use the imported reference's current README
for its current alpha layout and commands. No original gameplay structure,
raylib default, tick frequency or project-specific constant is required for a
new game. A new design uses the shared core and whichever knowledge is relevant.
