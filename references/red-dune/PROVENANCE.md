# Provenance and publication boundary

Original supplied Red Dune 0.6 archive SHA-256:
07737dae742b86542046525e6f15f189a9d7c71ea0682af8a78a830f40b49968

The prior preparation selected 99 source inputs and 79 compatibility inputs. Each of those 178 files was hash-checked against its original selection record before this export. Their contents are unchanged: 107 remain raw text and 71 CBOR fixtures are represented as canonical one-line base64 with a terminal LF. Raw paths, sizes, and SHA-256 values are explicit in RESTORE-MANIFEST.json. Encoding is packaging, not a game-code change.

The original package metadata declared license NONE. The included MIT LICENSE, copyright 2026 Masaya Shirasawa, is the owner-authorized public-release grant prepared for this export. It is not an inherited license notice from the original archive. Public package metadata uses MIT and refers to that grant.

Prepared Cabal metadata retains the existing array dependency correction and uses public game-arena/game-transition packages instead of a duplicate vendored source tree. FOUNDATION-MANIFEST.json pins the explicit nine public library source/package/license/test files from formatted public commit 84a074f37dca7ea1b81c6d1535c070d3e3201222 (tree 6a9f0c86f037896f5b69b4b1100499ac2a23fc18). These are copied to an isolated vendor directory only for checking; they are not duplicated in this export.

FOUNDATION-TESTED2487-MANIFEST.json preserves the exact pre-format core files from public commit 2487f7b31f75af65fa430123efbc4b67ca883b93 used for the completed full executable checks. Five Haskell files subsequently changed formatting; four package/license files are identical. Each new Haskell file was verified to equal pinned Ormolu 0.9.0.0 output from the tested bytes, with safety and idempotence checks enabled. This is format-equivalence evidence, not a claim that the full game tests ran again against the formatted bytes. The active helper accepts only the current exact manifest; it does not automatically fall back to old or unverified source. See CHECK-SUMMARY.md for separate full-game and bounded formatted-core results.

New materials: README, this provenance note, migration-scope documentation, restoration/base64 manifests, foundation manifest, wrapper/regression tests, optional project layout, and publication selection. No game source semantics were changed.

Only SOURCE-ALLOWLIST.json entries are intended for publication. The reference remains optional; no root package or publication-policy changes are requested. Encoded fixtures are a specifically reviewed export mechanism, not an exception that permits binary artifacts through the global publication gate. They are compatibility data, not commercial game/media assets. The bounded content scan and exact-origin audit are not a warranty that every conceivable secret can be detected.

Prior LOCAL-CHECK.json was not copied. Its GHC 9.6.6 results are historical and distinct from the fresh GHC 9.6.7 run documented in CHECK-SUMMARY.md. No prior full-suite result is silently promoted to the scope of this export.
