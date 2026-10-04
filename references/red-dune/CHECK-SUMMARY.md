# Fresh source-reference check: 2026-10-04

## Full executable checks with pre-format core

Core: public commit 2487f7b31f75af65fa430123efbc4b67ca883b93, pinned in FOUNDATION-TESTED2487-MANIFEST.json.

Environment: Linux, GHC 9.6.7, Cabal offline with no remote repositories, isolated freshly restored inputs and pinned public foundation libraries. This is a fresh check, not the historical GHC 9.6.6 LOCAL-CHECK result.

| Actual command | Result |
| --- | --- |
| cabal build exe:red-dune --offline | exit 0 |
| cabal run exe:red-dune --offline -- test-m1 | exit 0 |
| cabal run exe:red-dune --offline -- test | exit 0 |
| Python restoration regression suite | 8 tests passed |
| Final manifest verification | 181 restored inputs verified |

The 181 restored inputs comprise the 178 selected originals plus LICENSE, Cabal package metadata, and the replacement migration-scope note. All 178 originals match their prior exact-source records. After the executable tests, all 181 restored inputs still matched their raw hashes and sizes; all nine isolated foundation files also matched the historical tested-core manifest. Original prep inputs were independently re-read and remained unchanged.

Both test-m1 and Main test reported 28,843 native/Arena parity boundaries for bounded S01, final tick 36,020, and final state SHA-256:

9185102a1a58d534aafc5abb8f4d19e888374a5a89a874dbdc892e8a287c581e

Main test additionally reported 43 legacy/current migration fixture files and 450,000 actual pureStep suffix ticks; supply-chain coverage reported 16,000 NativeInput boundaries and a 14,780-frame canonical suffix replay. These are scoped test observations, not a completed campaign or performance qualification.

Raw private build/test logs are excluded from publication. Their SHA-256 values:
- Build: cfa719edb7dbc694b6795dea456015d4f4a452f6ba07b5dbaeb3b9bff09bca88
- test-m1: 12395b5b0b56035f19c114da75aeed45374998bc3501a7981037b76ea67006ce
- Main test: 985664e1c7aa5b8c1c249c217331288ca279d3b1fc4c3f3f338c758fdbbb2e57

Restoration regressions cover binary NUL/CRLF preservation, exclusive-create refusal to overwrite, corrupt/invalid/noncanonical base64, hash/size mismatch, unsafe/traversing paths, duplicate/conflicting records, and source symlinks. The selected export was also checked for UTF-8 text without NUL and bounded private-path/credential patterns.

An earlier superseded build completed but its test run was intentionally stopped (exit 130). It is not counted as a test pass. Only the final fresh run above supplies the reported executable results.

Not claimed: browser or HTTP bridge operation; the historical full shell/fault-injection/mutation suite; full campaign/gameplay/usability acceptance; platform qualification beyond the observed Linux environment; or performance acceptance. Some focused fault assertions occur within Main test; that does not establish the omitted historical full fault suite.

## Bounded integration with current formatted core

Current core: public commit 84a074f37dca7ea1b81c6d1535c070d3e3201222, tree 6a9f0c86f037896f5b69b4b1100499ac2a23fc18, pinned by the active FOUNDATION-MANIFEST.json.

The five changed Haskell files exactly match output from verified pinned Ormolu 0.9.0.0 applied to the historical tested bytes, with its safety checks and --check-idempotence enabled and GHC2021 selected. The four package/license files are byte-identical. This establishes the reviewed formatting relationship without treating changed bytes as previously executed bytes.

A new isolated restoration using the active manifest was checked on Linux/GHC 9.6.7:
- cabal build exe:red-dune --offline: exit 0
- cabal test game-transition:transition-laws game-arena:arena-laws --offline --enable-tests: exit 0; both law suites passed
- Post-run readback: all 181 restored inputs and all nine current foundation files matched their manifests

These are core package test-suite stanzas, not a nonexistent Red Dune test-suite stanza. Full Red Dune test-m1/Main test was not repeated against formatted core. The full game results above remain specifically on the earlier 2487 bytes.

Private bounded-check log SHA-256 values:
- Formatted-core executable build: b8a788013165f30deab4b0355c2459f65252eee361087e2813af8273cc06063e
- Core law suites: 477c3f168b8a87db37e6c52dd1f41fd3990c5add6f38596bb46bd9db4feff5fd

The helper has one active exact foundation manifest and no profile-selection/fallback mechanism. Its ordinary check action still runs the full executable checks for whichever explicitly pinned current core is supplied.
