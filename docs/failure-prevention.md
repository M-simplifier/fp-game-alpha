# Reusable failure-prevention lessons

Choose checks for the behavior and boundaries changed. A small fix needs its
relevant regression, not a new ledger entry or a repeat of every platform,
publication and clean-clone check. Run the publication gate when publishing;
exercise clean setup or relocation when setup, source selection or portability
changes. Preserve existing required CI.

Record a lesson here only when it helps prevent a recurring class of mistake.
Name the condition, mechanism and limit; leave task-specific evidence with its
test or change. A passing example is not a general proof. The
[dated finding histories](https://github.com/M-simplifier/fp-game-alpha/blob/7682f7c620fbc03c288a501d5a9c116bbba7d999/docs/failure-prevention.md)
retain original reproductions, repairs and measured scope.

## Public construction and numeric boundaries

- A hidden constructor does not make an exported record selector read-only.
  Use ordinary projections when outside update must be forbidden; compile a
  positive client and a negative update for the intended diagnostic
- Validate relations as well as individual values: a world that belongs to one
  board must not be accepted against another merely because their shapes match
- Parse external numbers as unbounded `Integer`, check the original domain,
  then narrow. Bounded `Int` parsing can wrap before a range check; include huge
  positive/negative inputs and verify rejected commands preserve state
- Validate bounds before overflow-sensitive arithmetic. For bounded width,
  prefer `position <= limit - size` after checking `size`, and test machine
  extremes at affected external boundaries

These lessons came from Lantern, Garden, generated Model and live-tuning checks.
They do not prove every parser or internal constructor safe. See
[Haskell guidance](haskell.md) and
[verification practice](practice/haskell/verification-review.md).

## Compiler-backed inspection

Use the compiler to identify loaded modules, imports and bindings; a source
regex can mistake a comment for a module declaration. An empty export list is
valid. Establish successful loading separately from output size, and require
real compiler errors or missing symbols to fail. `tools/test_tools.py` tests
these cases; saved-source queries still do not represent unsaved editor state.

## Portable source and caches

Select generated-game inputs explicitly. Ignored binaries, build caches and
editor settings must not enter a game because a directory was copied recursively.
Test generation after build-output pollution, not just from a clean checkout.
Keep notices, source identities and enough tool source for independent continuation.

A pinned archive digest does not attest an existing writable extraction cache.
Reject linked entries and compare extracted regular-file bytes with pinned
members before use. Cache integrity tests do not protect against concurrent
replacement after verification; state that ownership assumption.

## Native tooling ownership and transport boundaries

- Captured child processes need one clear owner through success, failure and
  cancellation. Stop the managed tree before joining blocked pipe readers;
  Windows job-completion waits need a separately interruptible deadline owner
- A cancellation test must observe that the child actually started and include
  a positive completion control. A timeout or missing dependency is not proof
  that the intended cancellation path worked
- Prefer normal shell ownership for interactive POSIX jobs. Native `run` execs
  Cabal; captured `run --smoke` owns deadlines. Test actual suspend/resume when
  changing this boundary rather than inventing another foreground proxy
- Refuse linked output leaves and use fresh temporary files plus rename for
  replacement. Never truncate a potentially hardlinked configuration file
- Resolve caller-selected relative roots, but reject raw linked ancestors before
  normalization can hide `alias/..`. Generated internal names remain strict
- Keep the game's Cabal-selected compiler separate from tooling bootstrap.
  Respect existing profiles; a failed compiler query must not fall back to PATH.
  Probe actual executable/argument handling, including spaces and Unicode
- Machine-readable output needs first-use and encoding checks: configuration
  initialization prose, CRLF, malformed UTF-8 and duplicate PATH matches can
  invalidate warm-cache assumptions

The package tests in `tools/haskell/test/` and the foundation's native CLI and
terminal integration suites own these regressions. Keep skipped or inconclusive
checks visible. Passing these checks does not establish installed-editor UI,
crash durability or protection from hostile concurrent filesystem mutation.

## Event, editor and persistence boundaries

- During an active audit, queue a successor on the owning worker. Clear ownership
  inside its completion boundary so a late microtask cannot strand an invalidation.
  Use deterministic scheduling tests for the actual race
- Editor trust must cover both the selected project and file within the same
  workspace folder, using lexical and canonical paths. A globally trusted editor
  is insufficient for an unrelated project or a symlink escape
- Preserve the opened document URI across an asynchronous compiler call. Associate
  an alias only with verified nonzero device/inode identity, without rounding
  large IDs or conflating case-sensitive paths
- After UI redraw, restore the invoked control's semantic identity. Keep dynamic
  import failures inside the startup error boundary. DOM stubs do not establish
  real keyboard focus or network-failure behavior
- Bound serialized journal bytes, not character counts, and preserve the prior
  readable file on rejection. Validate untrusted turn numbers without narrowing
  them into a wrapping machine integer

These are conditional lessons, not requirements to add an editor, browser,
audit scheduler or journal to every game. Test the real boundary when it changes.
