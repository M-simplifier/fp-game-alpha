# Source inventory and next milestones

| Material | Initial disposition | Scope and next acceptance |
| --- | --- | --- |
| Transition / Arena / Finite | Selected MIT kernel; executable alpha | Preserve API, test laws and document assumptions |
| Garden | Selected experimental pure-core reference | Deterministic world, event and clock adapters, pause/reset/debt and bounded input checks; no graphical host claim |
| Tapline | Selected experimental pure-core reference | Six-round trace and Step/Arena regression; exact deadline, ordered duplicate taps, reset barrier and focus pause; no graphical host claim |
| Station Dispatch | Selected experimental pure domain reference | Six orders, stale-turn rejection, Step/Arena and full 864-state finite enumeration; JSON save, asynchronous UI IDs and browser host still pending |
| River Home | Selected experimental pure-core reference | Authored multi-day journey, original simulation/clock/save, Step/Arena and finite invariant/save regressions; original QuickCheck suite and graphical host not reproduced |
| Complete Afterlight | Staged for source/license review | Full Session/Arena, native renderer/audio and Web host; original parity evidence is historical until rerun here |
| Lantern finite puzzle | Selected experimental source and executable law test | Checked board, original valid-board transition, Step/Arena agreement and a four-state fully observed reachability graph; no general-board or SMT claim |
| Red Dune 0.6 | Locally acquired; selection pending | Official Library transfer, size/SHA and metadata verified; source/license review and local validation still required |
| Red Dune 0.7 | Excluded | Work in progress; do not mix into the stable 0.6 publication |
| SMT/TLC/SBV and platform research | Deferred experimental material | Select small reproducible experiments after first-user acceptance; no universal guarantee inferred |
| LiquidHaskell / Qty | Selected source-only quantity lab; stronger proof blocked on pinned checker setup | Frozen original/annotation sources, GHC negative examples and full finite oracle route; historical selected-binder SAFE25 and mutants remain separate, pinned LH environment not yet reproduced |

The supplied Red Dune 0.6 report includes the author's suite, old 960-profile
goldens, 15 mutants, HTTP and a short S01 new-food trace. Independent final
review, S02, automatic replenishment, all campaigns, browser and D2 remain
unfinished. None of these historical claims constitutes public-clone acceptance.

The first milestone is an independent terminal game workspace, actual key
and stamina development, relocation, and ordinary Cabal acceptance. Lantern
is the first additional reference; Tapline, Garden, River Home and the Station
Dispatch domain follow as pure-core examples.
The next milestones add Station and River, then optional graphical/Web
profiles. Toolchains,
large binaries and repeated raw logs belong in reproducible downloads or
appropriate release artifacts, not in the source repository.
