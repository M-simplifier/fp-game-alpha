# Third-party source snapshots

`recovered/metadata/trusted-source/liquidhaskell-0.9.6.3.1/` contains the
specific upstream LiquidHaskell assumptions for `Data.Int`, `GHC.Int`,
`GHC.Num`, `GHC.Real`, `GHC.Classes`, and `Data.Either`.

`recovered/metadata/trusted-source/liquidhaskell-boot-0.9.6.3/include/CoreToLogic.lg`
is the corresponding upstream liquidhaskell-boot mapping snapshot.
These source snapshots are separately attributed third-party material,
distributed under the upstream BSD-3-Clause license. The included
[`LIQUIDHASKELL-LICENSE`](recovered/metadata/trusted-source/LIQUIDHASKELL-LICENSE)
retains the upstream copyright and license notice. The inspected boot package
declares BSD-3-Clause but had no separate license file at its extracted root;
the supplied upstream notice is retained here alongside the snapshots.

The project-authored quantity fixture, annotations, mutants, formulas, and
capture script are selected technical source transferred for this repository.
The maintained portable runner, tests, and current explanation are adaptations.
The repository MIT license does not replace third-party notices. No GHC, Cabal,
Z3 binaries, dependency archives, or built dependencies are included.
