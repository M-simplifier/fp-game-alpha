# Guarantees and their boundaries

The current implementation owns the contract. `Game.Transition` and
`Game.Arena` law tests check transition composition, admission and finite
reachability. Each game adds its current rules, save/codec round trips,
invalid-input and opaque API checks; a passing finite suite is not a proof
of every game or host.

Quantity checks compile the current Red Dune quantity module, require invalid
resource coercions and constructor access to fail, and compare finite arithmetic
inputs with an independent integer oracle. See [the checker](../tools/quantity/README.md).

Native tooling tests exercise actual generation, isolated build/check commands,
failure/cancellation, Unicode paths and source-only relocation. Editor tests
check parsing, source selection, cache lifecycle and trusted compiler inference.
Neither source inspection nor an IO label proves purity or audits dependencies.

Afterlight retains current world laws, frame-boundary and public session API
tests. Red Dune retains its current campaign, transport, construction, native
store, protocol, corruption, ownership and lifecycle tests. Save migrations are
current compatibility features, with bounded rejection and preservation tests.

Old Colony/LiquidHaskell/SBV/TLA+ experiments and whole-source comparison oracles
are retired to Git history. Their results are not claims about the current
compiler or game. [Verification](verification.md) separates actual executions
from source availability, other-host work and human play acceptance.
