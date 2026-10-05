# Third-party notices

Project-authored laboratory examples, tests and frozen game fixtures follow the
repository's MIT license. The source transfer does not replace third-party licenses.

The retained `metadata/*_LHAssumptions.hs`, `SpecFinder.hs` and `ToFixpoint.hs`
are attributed LiquidHaskell or liquidhaskell-boot snapshots. Preserve
`metadata/liquidhaskell-LICENSE`; the pinned official Cabal files retain their
upstream author and BSD-3-Clause license declarations.

`metadata/hackage/*.cabal` are official Cabal revision metadata. Each package's
own license applies to its separately downloaded source archive. The runner
restores the verified official source and license files under `RUN_DIR/lab/vendor`.
GHC, Cabal, Z3, source tarballs and compiled dependencies are not bundled here.

## License map for copied revision metadata

`metadata/licenses/index.json` maps all 121 copied Cabal files to their exact
verified source archive, declared license and retained license file hashes.
There are 119 package-local license files copied unchanged from those archives.

Two upstream archives do not include a separate license file:

- `monad-loops-0.4.3` declares `PublicDomain` in its retained official Cabal metadata
- `liquidhaskell-boot-0.9.6.3` declares `BSD-3-Clause` and copyright
  2010–19 Ranjit Jhala, Niki Vazou, Eric L. Seidel, University of California,
  San Diego, in its retained official Cabal metadata. The separately supplied
  same-project LiquidHaskell license notice remains at
  `metadata/liquidhaskell-LICENSE`; its provenance is not represented as a
  license file found in the boot archive

These exceptions are explicit in the map. They are not replaced with invented
license files, copyright holders or a blanket relicensing statement.
