# Source inventory and next milestones

| Material | Initial disposition | Scope and next acceptance |
| --- | --- | --- |
| Transition / Arena / Finite | Selected MIT kernel; executable alpha | Preserve API, test laws and document assumptions |
| Garden | Selected for next reference milestone | Pure rules, clock/input/view; preserve pause/reset and scheduler boundaries |
| Tapline | Selected for next reference milestone | Ordered taps, exact deadline, reset precedence and six-round regression |
| Station | Selected for next reference milestone | Turns, stale rejection, saves and asynchronous UI IDs |
| River Home | Selected for next reference milestone | Original pure simulation and invariant/save regressions |
| Complete Afterlight | Staged for source/license review | Full Session/Arena, native renderer/audio and Web host; original parity evidence is historical until rerun here |
| Lantern finite puzzle | Selected for finite example milestone | MIT kernel and board; reachable-state test; SMT evidence stays scoped to its finite model |
| Red Dune 0.6 | Blocked, no files exported | Official Library materialization is incomplete on the Windows consumer; source/license review and local validation still required |
| Red Dune 0.7 | Excluded | Work in progress; do not mix into the stable 0.6 publication |
| SMT/TLC/SBV and platform research | Deferred experimental material | Select small reproducible experiments after first-user acceptance; no universal guarantee inferred |

The supplied Red Dune 0.6 report includes the author's suite, old 960-profile
goldens, 15 mutants, HTTP and a short S01 new-food trace. Independent final
review, S02, automatic replenishment, all campaigns, browser and D2 remain
unfinished. None of these historical claims constitutes public-clone acceptance.

The next milestone is a working terminal/native template and CLI, followed by
auditable reference games and optional graphical/Web profiles. Toolchains,
large binaries and repeated raw logs belong in reproducible downloads or
appropriate release artifacts, not in the source repository.
