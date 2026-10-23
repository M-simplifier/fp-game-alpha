# Afterlight: complete source, separately verified hosts

This package retains the original game's complete pure world, input/session,
renderer, procedural audio, native runtime and browser host source. It is not
a small substitute for the original game. The original source baseline is
`6367b56e3ff2042199667f2a5bfa50695f4aaf2f`; the Session/Arena adaptation and the
frozen oracle are recorded in `docs/BASELINE-MANIFEST.json`.

## Read and develop

Start with `src/Garden/Types.hs`, `World.hs` and `Rules.hs`, then `Arena.hs` and
`Session.hs`. The session turns an ordered frame into simulation input while
retaining clock debt, pending edges, pilot state and interpolation. The native
and browser hosts own resource handles and perform effects; they do not replace
the authoritative pure transition. Rendering/audio source is in `runtime/`.

This is an optional package, not part of the dependency-free terminal profile.
Use the foundation's common libraries; no private repository is needed to
inspect or test the imported source.

## Pure-core and original parity checks

With Python 3.12+, GHC, ghc-pkg and Cabal on PATH, from the foundation root:

    python references/afterlight/scripts/check-core.py --download

This explicit download option fetches five version- and SHA-256-pinned Hackage
source archives into `.build/afterlight-core/archives`. It does not install a
compiler or change global configuration. Later runs can omit `--download`.
An offline archive directory can instead be supplied using `--archives DIR`.
The test route builds the complete pure game, the original QuickCheck and parity
suites, and `frame-boundaries`. It also compiles public-package clients: ordinary
session reads/transitions must work, while direct world/pilot record updates
must fail. Dependency tests and raylib are not enabled.

The archived Linux GHC 9.6.6/Cabal 3.16.1.0 check covered the two original suites,
including 5,580 frames / 9,067 ticks of original parity; see
[the scoped record](docs/qa/PUBLIC-CORE-CHECK.json). It predates the additional
frame-boundary and public-client checks.

Native graphical and browser execution are separate routes. Passing these
checks does not verify GPU output, OS input, sound playback or browser behavior.
The checked-in historical documents describe the original baseline and earlier
hosts; their past measurements are not fresh public-clone results.

## Optional full native host

From this directory, standard Cabal uses `cabal.project` and the shared libraries:

    cabal build all -fnative
    python scripts/prepare-native.py
    cabal run afterlight-native -fnative

The native route additionally needs h-raylib 5.6.0.0 and its platform libraries.
The font preparation command explicitly downloads fixed Noto CJK 2.004 and
checks its hash and license; it never installs a system font. Audio is generated
by the Haskell source (`tools/GardenAudio.hs`). No downloaded font, recorded
music, SDK, dependency tree or compiled executable is committed here.

Native host commands are supplied for continuing the full source. Their
public-clone execution status must be recorded independently from pure-core
checks. See the renderer and Web documents for platform-specific prerequisites.

## Optional browser host and redistribution

Run Web commands from `references/afterlight`, not the foundation root.
Prepare runtime assets first (font download is explicit):

    cd references/afterlight
    python scripts/prepare-native.py
    cabal run afterlight-audio -fnative
    bash web/build.sh --assets assets

The last command requires the pinned cross-toolchain described in
`web/README.md`; it is not an automatic compiler installer. That preserved
document uses “repository root” to mean this game directory.
`web/README.md` documents the pinned GHC-Wasm/Emscripten toolchain and build.
`web/build.sh` uses this repository's shared libraries. Browser preparation,
actual play, deployment and device performance remain distinct acceptance
steps. Existing host tests do not stand in for a browser playthrough.

The source license is in `LICENSE`; see [third-party notices](THIRD-PARTY.md). Downloaded dependencies retain their own
licenses. In particular, a compiled Web distribution must include appropriate
third-party notices, matching source and applicable relinking materials for
its actual build. This source import alone does not certify binary distribution
compliance. Do not ship a binary merely because source tests passed.

## Preservation and limits

Run `python references/afterlight/scripts/audit-source.py` from the foundation
root to compare the pinned source/oracle. Public layout changes are explicit;
original gameplay source and oracle are retained. The original README is stored
as `docs/baseline/README.original.txt`: its historical relative links are evidence,
not navigation for this public layout. Use this README for current entrypoints. Historical GPU and Web
comparisons are not rerun by that audit. No claim of bug-free play, performance
on all devices, or compatibility with arbitrary future changes is made.

## Consistent source formatting

Live Haskell sources use pinned Ormolu 0.9.0.0. `docs/FORMAT-MANIFEST.json` records
exact before/after hashes; the original `BASELINE-MANIFEST.json` and frozen oracle
remain intact. Six definitions contain mid-declaration CPP, which Ormolu cannot
parse directly. Their bodies are formatted by a branch-aware weave using the
same pinned Ormolu; the narrow formatter-control blocks remain. Check them with:

    python references/afterlight/scripts/check-cpp-format.py

Use `--write` to reproduce their formatting. This needs the verified formatter
cache (`python tools/formatter.py install`) and `cpp` on PATH. The script formats
both native and Wasm branches, rejects disagreement in shared text, and compares
both complete preprocessed modules with the reviewed canonical hashes before
writing anything. It refuses to relock semantic drift as formatting.

The historical format manifest retains all six native/Wasm module projections
from public pre-format commit `2487f7b`. The current Runtime projections have
explicit successors in `docs/FRAME-BOUNDARY-MANIFEST.json`; the four renderer
projections still match the historical hashes. The formatter checks that chain
without rewriting its history. This does not establish native GPU or browser
execution.

The long parity route's reviewed, test-only terrain equality optimization is
recorded in [the bounded measurements](../../docs/research-iteration-latency.md).
`docs/TEST-OPTIMIZATION-MANIFEST.json` explicitly links the semantic test successor
to its previous formatted hash; historical formatting and oracle records remain
unchanged. The source audit checks that exact successor, and
`python references/afterlight/scripts/test-audit-source.py` verifies its narrow
scope and rejection of tampered test, runtime and oracle source.

The movement readability revision is recorded separately in
`docs/READABILITY-REFACTOR-MANIFEST.json`. Its three exact source paths name
their predecessor and current hashes; the original baseline, oracle and
formatting manifests remain intact. These sources were unchanged originals
before the refactor, so their predecessors are baseline hashes. The audit also
rejects extra paths, false predecessors, altered current bytes and missing
reasons. In `Garden.Rules`, start with `movement`, then `jumpVelocity` and
`movePlanar`: jump grace, buffered input, launch speed and X/Z/vertical collision
order have distinct names, while `Motion` and `Journey` retain their meanings.

`docs/FRAME-BOUNDARY-MANIFEST.json` records the frame-boundary revision separately.
`Garden.Runtime.Control` owns simultaneous pause/photo/capture/save-exit decisions;
the host retains polling and effect order. The tests cover all 512 combinations
and authored priority cases. The clock caps its Double tick quantity before Int
conversion, so repeated admitted extreme durations cannot overflow the eight-tick
batch limit. The elapsed-input rejection boundary is unchanged. `Simulation`
retains the same read functions and Show/Eq observations, with private fields:
use `beginSimulation` to reconstruct a world coherently instead of updating only
its world or pilot while retaining an unrelated clock and interpolation history.
