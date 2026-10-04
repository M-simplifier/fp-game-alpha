# Red Dune: optional colony source reference

[Red Dune 0.6](../references/red-dune/README.md) is selected source for an
in-progress colony simulation. It demonstrates ordered simulation boundaries,
production, stock reservations, maintenance, transport, saves and migration.
Choose a relevant technique after the human's game brief and AI design work;
this source is not a mandatory architecture or mass-scaffolding default.

## Read one boundary

1. Read [World](../references/red-dune/src/Colony/World.hs): `World`, `Command`,
   `NativeInput` and `ColonyOutput` define the state/input/output vocabulary.
2. Follow `OrderProduction` through [Scheduler](../references/red-dune/src/Colony/Scheduler.hs)
   into [SchedulerCore](../references/red-dune/src/Colony/SchedulerCore.hs)
   and [Jobs](../references/red-dune/src/Colony/Jobs.hs). Inspect the guards,
   inventory reservation, receipt and resulting job phase before changing a rule.
3. [Arena](../references/red-dune/src/Colony/Arena.hs) connects that same pure
   transition to `Machine`, validates boundary/submission context in `admit`,
   and projects a participant view in `observe`.
4. [Main](../references/red-dune/app/Main.hs) selects the demo, test and stdin/stdout
   UI shell routes. [UIShell](../references/red-dune/src/Colony/UIShell.hs) and
   [Save](../references/red-dune/src/Colony/Save.hs) own external interaction and
   persistence; the `ui/` browser source has no included HTTP bridge.
5. Use [M1Tests](../references/red-dune/test/M1Tests.hs) for the bounded scenario
   and [InventoryTests](../references/red-dune/test/InventoryTests.hs) for focused
   inventory behavior. Read the tested setup and assertions, not just test names.

The intended player activity is managing colony resources and production. This
export does not provide an accepted browser play experience or complete campaign.
The terminal `demo` is a synthetic fixture, not interactive play acceptance.

## Verify and restore safely

From the repository root, with Python 3:

```sh
python references/red-dune/tools/test_restore.py
python references/red-dune/tools/check.py verify
python tools/test_red_dune.py
python references/red-dune/tools/check.py prepare --foundation .
```

`prepare` verifies 181 restored inputs (178 original inputs plus three packaging
files) and nine pinned foundation files, then creates an exclusive fresh work
folder. It does not install dependencies or execute the game. For a full check,
use the explicit GHC/Cabal paths in the [reference README](../references/red-dune/README.md).
The `unix` dependency and GHC 9.6/base 4.18 bound make this a Linux-oriented route;
the repository's three-OS core CI is not Red Dune platform qualification.
The root `cabal.project` deliberately excludes this optional package.

[CHECK-SUMMARY](../references/red-dune/CHECK-SUMMARY.md) distinguishes the full
`test-m1`/`test` results on core commit `2487f7b` from executable build and both
core-law suites on formatted core `84a074f`. Verified Ormolu equivalence connects
the two source versions; it does not mean full game tests ran on the new bytes.
HTTP/browser, historical full fault/mutation, full campaign and performance
acceptance are still outside the claim.

## Preservation, readability and license

All 194 selected paths are imported byte-for-byte. The 178 original inputs are
107 text files and 71 canonical base64 fixtures; restoration validates raw size
and SHA-256. There are no published raw CBOR, build outputs or toolchain assets.
The JavaScript/HTML/CSS are source, and the encoded fixtures are compatibility
data, not third-party artwork or media. See [provenance](../references/red-dune/PROVENANCE.md)
and the repository publication manifest for exact origins.

The original package declared `NONE`; the included [MIT grant](../references/red-dune/LICENSE)
is an owner-authorized public-release grant, not a pre-existing archive license.

The historical Haskell payload is still densely laid out and is not claimed to
meet the [readability rubric](haskell.md). `formatter.json` records this as a
preserved source root outside the active formatter `source_roots`; routine
formatting must not silently invalidate the original manifests. A future
readability revision needs a separately reviewed working copy, explicit changed
source provenance, and behavior checks. The current import changes no game rules.
