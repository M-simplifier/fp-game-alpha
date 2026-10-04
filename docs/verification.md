# Verification record

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

The CI workflow repeats build/test, source export and document checks from
GitHub checkouts on Linux, Windows and macOS. A configured job is not a passing
job: consult its actual result before making a platform claim. Graphical,
browser, server deployment and mobile performance are outside this bootstrap
verification scope.
