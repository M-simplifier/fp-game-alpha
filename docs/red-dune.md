# Red Dune: optional colony source reference

[Red Dune 0.6](../references/red-dune/README.md) preserves selected source for an
in-progress colony simulation: production, reservations, maintenance, transport,
saves and migration. Choose a relevant technique after the human's game brief
and AI design work; this archive is not a required architecture or template.
For the active survival game, use [Red Dune live](red-dune-live.md).

## Follow a production request

Follow `OrderProduction` from [Scheduler](../references/red-dune/src/Colony/Scheduler.hs)
into [SchedulerCore](../references/red-dune/src/Colony/SchedulerCore.hs) and
[Jobs](../references/red-dune/src/Colony/Jobs.hs). Inspect admission, inventory
reservation, the receipt and resulting job phase before changing a rule. The
[Arena adapter](../references/red-dune/src/Colony/Arena.hs) invokes that same
transition rather than maintaining a second simulation. Compare a scenario in
[M1Tests](../references/red-dune/test/M1Tests.hs) with focused
[inventory checks](../references/red-dune/test/InventoryTests.hs); read their
setup and assertions, not just test names.

The terminal `demo` is synthetic evidence, not interactive play acceptance.
The archive's `ui/` is source only and has no included HTTP bridge or accepted
browser campaign.

## Verify and restore safely

From the repository root, with Python 3:

```sh
python references/red-dune/tools/test_restore.py
python references/red-dune/tools/check.py verify
python tools/test_red_dune.py
python references/red-dune/tools/check.py prepare --foundation .
```

`prepare` verifies restored inputs and exact foundation pins, then creates an
exclusive fresh work folder. It installs nothing and does not execute the game.
For executable checks, use the explicit GHC/Cabal paths in the
[archive README](../references/red-dune/README.md). The `unix` dependency and
GHC 9.6/base 4.18 bound make this a Linux-oriented route; the root project
excludes the optional package. Three-OS foundation CI is not Red Dune platform
qualification.

[CHECK-SUMMARY](../references/red-dune/CHECK-SUMMARY.md) records full executable
results on core commit `2487f7b` separately from bounded build/law results on
formatted core `84a074f`. Ormolu equivalence connects those versions, but does
not make the old full-game run an execution of new bytes. The later test-only
foundation repin is identified in [provenance](../references/red-dune/PROVENANCE.md);
it preserves the historical tested manifest rather than rewriting that receipt.
HTTP/browser, the historical full fault/mutation suite, campaign and performance
acceptance are outside those records.

## Preservation and license

The selected original game inputs remain unchanged; binary compatibility
fixtures are canonical base64 text whose raw size and SHA-256 are verified on
restoration. Public wrappers and compatibility pins are separately maintained.
The manifests and provenance identify that boundary. No build outputs,
toolchain assets or private Git history are included.

The original package declared `NONE`; the included [MIT grant](../references/red-dune/LICENSE)
is an owner-authorized public-release grant, not an inherited archive license.

The dense historical Haskell is preserved outside the active formatter roots.
Do not format it in place and invalidate its original manifests. A readability
revision needs a separate working copy, explicit transformation provenance and
behavior checks; the active continuation supplies that separate path.
