# Verification record

## Independent game development on Windows

`python tools/test_workspace.py` passed locally on Windows x86_64 with
Python 3.14.2, GHC 9.6.7 and Cabal 3.12.1.0. It generated outside the starter
in a path with spaces, checked dry-run/non-overwrite/independent licensing,
built/tested/ran via ordinary Cabal, then edited state/rules/view/save/tests
to add a key and locked exit. Real input verified the blocked and unlocked
branches plus save/load. It copied only the game, excluding build caches,
into a separate directory, rebuilt and ran it, queried types via its own CLI,
then added bounded stamina and a rest command without regeneration.
Tests/runtime verified exhaustion, recovery and deliberate save-version rejection.

The compact record is [Windows development evidence](evidence/windows-development.json).
This is gameplay/extension acceptance for that small terminal route, not an
enjoyment evaluation, a graphical route, or a proof for arbitrary extensions.
The [first-user CI run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37175110782)
passed the same development check on Windows, Linux and macOS.

Windows LLVM ar initially failed under space-containing paths. The project
sets `ar-options: --rsp-quoting=posix` only on Windows. Cabal's
`--disable-response-files` alone did not fix that archiver failure.

## Saved-source queries and editors

The compiler regression covers leading line/block comments containing fake
module declarations, a valid empty module export list, a real binding's type,
missing binding rejection and a genuine Bool/Integer error. Module/import
context comes from GHCi, not a source regex. Query/compiler failures return
nonzero even if GHCi exits zero.

Windows VSCode 1.127.0 passed an actual extension-host test: module/type queries,
an intentional compiler error, and Problems diagnostics. Neovim 0.12.4 passed
an actual headless process test with the same queries/error and quickfix output.
The compact records are [VSCode](evidence/vscode-windows.json) and
[Neovim](evidence/neovim-windows.json). A live HLS hover/diagnostic test is a
separate target; no success is yet claimed. macOS editor/gameplay hardware has
not been tested. These editor tests used isolated fixture/profile directories.
The additional local Neovim/HLS process test timed out at its 450-second
process bound. It establishes no live hover/diagnostic result; the ordinary
saved-source Neovim contract passed independently.

## Kernel bootstrap

Local compiler: Windows x86_64, GHC 9.6.7, Cabal 3.12.1.0. Both libraries
compile with `-Wall -Wcompat -Werror`. Transition laws pass 341 small traces,
all whole-input partitions, chronological output, identities and a deliberate
output mutation. Arena laws pass admission/joint control, rejection state,
hidden observations and a state-peeking mutation, finite predecessors,
deadlock distinctions and 128 subset-pair monotonicity probes.

The publication gate records one row per selected source file in
`.build/export-report.json`. That report includes the manifest digest and
bounded scan results; raw local logs and absolute machine paths are excluded
from the public source. Documentation links pass the local linter.

A clean local clone with an empty Cabal home exposed secure-repository
bootstrap even with `--offline`. The CLI now supplies an isolated repository-free
configuration and writes outputs/cache under `.build/`. This path is the
first-user build/test contract; installing a compiler still requires explicit
toolchain setup.

The initial [CI run at 235162f](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37171188543)
passed kernel/CLI/source/doc checks on Windows, Linux and macOS. It predates
the independent workspace and editor additions. The CI workflow repeats checks from
GitHub checkouts on Linux, Windows and macOS. A configured job is not a passing
job: consult its actual result before making a platform claim. Graphical,
browser, server deployment and mobile performance are outside this bootstrap
verification scope.

## Lantern reference

The Lantern source in `references/lantern/` compiles with
`-Wall -Wcompat -Werror` and its law test passes locally on Windows with the
above GHC/Cabal versions. It checks board-construction rejection, the
original rule through `Step` and `Arena`, invalid admission, and closure plus
forced reachability of one explicit four-state graph. This is a finite example
for one board, not an SMT result or a guarantee for arbitrary boards. The
[Lantern CI run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37176394511)
passed on Windows, Linux and macOS.

A later API review found that exported record selectors allowed outside state
updates despite a hidden constructor; an actual GHC client compiled and a
malformed-state move raised a list-index exception. It also found `Int`
coordinate overflow in board validation. The repaired API uses private record
fields plus ordinary projections, binds a world to its board, validates the
original state before indexing, and compares coordinates without addition.
Local GHC now rejects the external record-update fixture for the intended
reason and accepts the projection client. Tests reject `maxBound`/`minBound`
coordinates and a state from another board. The
[correction CI run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37177560148)
passed on Windows, Linux and macOS.

## Quantity source-only checks

The selected frozen `Colony.Units` source and annotation-only copy match
their recorded SHA-256 values. On local Windows GHC 9.6.7,
`python research/quantity/check.py check` passed eight intended GHC type
rejections, two positive compilations, and 631,024 oracle inputs against
both modules with identical outputs. The compact
[source-only record](evidence/quantity-windows.json) contains the case map,
category counts and output hashes. A deliberately missing compiler makes
`doctor` fail; a GHC error must match the named type/constructor diagnostic.
This is finite source-only validation. LiquidHaskell, its six proof mutants,
Z3 and the other historical research tools were not run in this checkout.
The [source-only CI run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37178075499)
passed on Windows, Linux and macOS, including independent game development
acceptance on each checkout.

## Tapline reference

The selected Tapline core compiles with `-Wall -Wcompat -Werror` on local
Windows GHC 9.6.7. Its test plays all six winning rounds and compares direct,
Step and Arena execution. It checks the exact deadline, ordered repeated
taps, reset as an indivisible batch barrier, focus-loss pause, pure render
projection, and a deduplication mutation that diverges at frame two.
`python tools/fp_game.py test` passed with the existing kernels and Lantern.
This verifies the selected pure core and small trace suite; graphical host and
device performance remain outside this reference. The
[Tapline CI run](https://github.com/M-simplifier/fp-game-alpha/actions/runs/37178602184)
passed on Windows, Linux and macOS; a public branch fresh clone also passed
the source, docs and Cabal test checks locally.

## Garden reference

The selected Garden core compiles under `-Wall -Wcompat -Werror` on local
Windows GHC 9.6.7. Its law test checks a deterministic seeded world and reset,
opaque coordinate bounds, event Step/Arena equivalence, frame-clock
Step/Arena equivalence, five ticks per frame with retained debt, pause/resume
debt clearing, extreme pixel rejection, a dropped-tick mutation and a
counterexample to splitting a frame at a control edge. The game updates and
clock remain pure; no graphical host or device-performance result is claimed.
The Garden three-OS CI result is pending.
