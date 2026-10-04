# Review findings and prevention ledger

A regression for one reported input proves that input stays fixed. A prevention
claim also needs a mechanism that catches the *class* of mistake at a boundary.
When review or playtesting finds a bug, record the route that exposed it, why
the previous guarantee missed it, the repair, the reusable check, its measured
evidence and what the check still cannot establish. Keep proposed checks marked
as proposals until they actually run. Consult [verification](verification.md)
for measured platform results and proof scope.

## Saved-source CLI: comment mistaken for a module declaration

- **Detection:** A real `inspect`/`context` fixture began with a comment
  containing `module Prelude`; the earlier text regex selected the comment as
  the module. A block comment containing `module Bogus` gave the same risk.
- **Missed guarantee:** The early fixture started with an ordinary module line.
  A regex over raw source did not implement Haskell comment or lexical rules.
- **Repair:** Compile the saved file and ask GHCi for its loaded modules,
  imports and type/binding information. Fail if the requested source module
  cannot be established or a requested symbol is missing.
- **Class prevention, implemented:** `tools/test_tools.py` runs the actual
  compiler query on line/block-comment decoys and checks that `Tiny`, its real
  type and its structure are returned. Compiler errors must remain nonzero.
  The CLI uses GHC/GHCi as the syntax authority, rather than another source
  regex for the declaration.
- **Limit:** Saved-source queries are not an HLS session or unsaved editor
  state. Parsing GHCi's display still has a version-specific contract; this
  fixture does not test every Haskell extension or compiler version.

## Saved-source CLI: valid empty export list treated as failure

- **Detection:** `module Empty () where` compiled but a heuristic expected a
  nonempty `:browse` result and returned failure.
- **Missed guarantee:** The earlier check equated no browse output with a
  broken module, although an empty export list is valid.
- **Repair:** Establish success from compiler load, module identity and GHCi
  command status, not from the number of exported bindings.
- **Class prevention, implemented:** `tools/test_tools.py` compiles and queries
  the actual empty module and requires success and module identity. It also
  requires a missing binding and a real type error to fail, so success cannot
  be obtained by simply ignoring GHCi errors.
- **Limit:** This covers the saved-source `inspect` contract, not all package
  visibility cases or an editor's in-memory buffer.

## Lantern: public selector enabled a record update

- **Detection:** An outside GHC client compiled `world { positions = ... }`
  although `World`'s constructor was hidden. A malformed value then reached
  `legal`, where `!!` raised an exception.
- **Missed guarantee:** Constructor hiding was reviewed, but an exported
  record selector remained an update field. A positive API test alone could
  not show that invalid construction was impossible.
- **Repair:** Keep update fields private and export ordinary projection
  functions. `legal` checks the original world before indexing; invalid moves
  preserve state and produce no transition output.
- **Class prevention, implemented:** `tools/test_lantern_api.py` compiles a
  positive outside client, then requires GHC to reject a record-update client
  *for the record-selector reason*. Lantern law tests exercise malformed
  positions and invalid admission. The generated starter has an external
  record-update rejection in `tools/test_workspace.py`. River and Station now
  have matching positive/negative outside-client fixtures in
  `tools/test_river_api.py` and `tools/test_station_api.py`; Station also
  rejects forged `TurnId` construction. Each fixture requires the relevant
  compiler diagnostic instead of accepting any compilation failure.
- **Limit:** A compile-negative test covers this public module and field, not
  every internal constructor, parser, lens, role/coercion or future export.
  Internal code and any new construction route still need review.

## Lantern: world accepted against a different board

- **Detection:** Review paired a valid world created from board A with board B;
  the old `wellFormed` checked shape but not ownership.
- **Missed guarantee:** `World` and `Board` were individually well formed, but
  the relation between them was absent from the invariant. Shape checks and
  constructor privacy alone cannot establish provenance.
- **Repair:** `World` retains its checked board, and `wellFormed b world`
  requires that board to equal `b` before `legal` or admission can proceed.
- **Class prevention, implemented for Lantern:** The law test presents a world
  to a distinct board and requires rejection. The public boundary documents
  board ownership as part of state validity.
- **Limit:** Runtime board equality is a Lantern-specific relation. A reusable
  board-indexed type or checked session capability could make mismatch harder
  to express, but no such general API is implemented or claimed here.

## Lantern: coordinate addition wrapped `Int`

- **Detection:** Review supplied extreme `Int` coordinates. `p + size`
  overflowed before a bounds check, making an out-of-board placement appear
  valid.
- **Missed guarantee:** The arithmetic was written as a familiar geometric
  condition; tests used ordinary board-sized values and did not probe machine
  bounds. An `Int` alias or `newtype` alone would not establish a range.
- **Repair:** Validate the cart size first, then compare `p >= 0` and
  `p <= 6 - size`; subtraction is bounded by the validated size. The same
  pattern checks Garden pixel bounds before coordinate subtraction.
- **Class prevention, implemented in these boundaries:** Lantern tests reject
  `minBound` and `maxBound` coordinates; Garden tests reject extreme pixels.
  [Haskell guidance](haskell.md) now asks reviewers to locate overflow-sensitive
  arithmetic at every external construction boundary.
- **Limit:** These cases do not prove all arithmetic in all reference games
  overflow-safe. A general property suite or checked numeric representation
  remains future work and must name its units and range explicitly.

## Procedure for the next finding

Add a row or section with a minimal reproduction and an acceptance command.
Identify whether the new test merely freezes a case or changes the construction
path, type/API boundary, template, or systematic check. Route the lesson into
the canonical guide and generated development path when a first user can
benefit. Re-run the relevant actual compiler/runtime test, source publication
gate and clean-clone route; keep untested proposals labelled as such.

## Pinned source archives are not a verified extraction cache

The Afterlight source-check helper originally verified archive hashes and
extracted file names, but that did not establish extracted file contents.
An existing cached symlink or hardlink could alias two expected paths: an
extraction overwrite could leave both names present with the wrong bytes.
This was found in a pre-publication review, not an observed compromised cache.

The helper now rejects linked cache entries before writing, rejects archive
links, and compares every extracted regular file with its pinned archive
member before invoking Cabal. Cache tests cover hash mismatch, extra files,
regular-file repair, hardlink rejection and symlink rejection. Compiler calls
are mocked in those cache tests; the complete Haskell suites are separate.

Apply this boundary whenever a version/hash-pinned archive is reused through
a writable extraction cache. A passing archive digest alone does not attest
installed/extracted bytes. This mechanism is not protection against another
process mutating the files concurrently after verification; builds assume
exclusive control of their local cache.

## Headless transport: preserve turns and readable journals

- Failure class: decoding untrusted decimal turns directly into bounded `Int`
  can wrap an enormous number into the current turn, accepting a stale/invalid
  transport request. Decode to `Integer`, compare to the exact visible turn,
  and never narrow the request. Positive and negative wrap aliases are tested
  in `tools/test_play.py` against the actual Haskell executable.
- Failure class: a character-count limit permits multi-byte reasons whose saved
  journal exceeds its own read-size limit. Check the serialized UTF-8 byte count
  before replacing the previous journal. An oversized write must leave the
  prior episode readable; the regression uses multi-byte text.
- Scope: Station's headless transport and local Python journal. These checks do
  not prove all codecs safe or turn the local files into an adversarial sandbox.

## Scratch browser host: controls retain identity across redraws

Paper Circuit's first Undo handler refreshed the SVG then focused Restart.
A keyboard user's next activation could therefore restart the game. The
production input router now returns the invoked control's semantic selector,
which the host focuses after redraw. Its DOM-stub regression checks Undo,
Restart, tile selection and invalid input. This checks routing identity;
actual browser focus/keyboard behavior remains a separate pending check.

Static ES-module imports also execute before an enclosing startup `try` body.
A failed engine/shim import could leave the preparation message indefinitely.
The host now awaits dynamic imports inside the startup error boundary. This
structurally includes dependency loading in error handling; actual browser
network-failure injection has not been run.

## Build outputs must not become generated-game inputs

Review of the Haskell Design integration exposed a distribution boundary error:
terminal scaffolding recursively copied all editor files. After building the reader,
ignored binaries, dependencies and local configuration could enter a new game; the
text newline conversion could also modify binary bytes. Clean-checkout CI missed
this usage-order problem.

The generator now selects four reviewed wrapper source files explicitly, refuses
linked wrapper sources, and leaves the optional reader distribution to its own setup
route. A regression fixture adds binary outputs with NUL/CRLF, dependency/vendor/build
folders and local settings, then asserts the entire generated file map is unchanged.
Future distribution additions need an explicit source or binary selection contract;
Git ignore status and a clean checkout are not sufficient export boundaries.

## An active audit owns its rescan requests

An earlier Linux CI attempt reported one unexpected audit event during an
excluded-file test. Investigation found a deterministic scheduling defect:
invalidating an active scan could leave a debounce timer alive after that worker
had already processed the new generation, producing another cache-only scan.
The old log does not prove that interleaving caused its event, so that attribution
remains a hypothesis; the scheduler defect itself was reproduced.

Invalidations during work now request a successor from the same worker. Idle
invalidations debounce; explicit refresh cancels pending debounce. Fake-timer and
deferred-scan regressions cover the trailing timer, late invalidation during cache
persistence, coalescing and disposal without relying on wall-clock sleeps. The
original excluded-file integration assertion remains intact. The old scheduler
fails the deterministic trailing-timer check (three scans instead of two).
