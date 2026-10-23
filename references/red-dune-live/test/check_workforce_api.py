#!/usr/bin/env python3
"""Compile real public clients: duty queries work; evidence forgery does not."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


GETTERS = """module Client where
import Colony.Workforce
import Colony.Types (EntityId, SimTick)
import Control.DeepSeq (force)
observe :: DutyEvidence -> (SimTick, WorkTarget, [EntityId], Maybe Integer, String)
observe evidence = (dutyTick evidence, dutyTarget evidence, dutyCrew evidence,
                    dutyCredit evidence, show (force evidence))
"""

GENERIC_FORGERY = """{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
module Client where
import Colony.Workforce
import GHC.Generics
class ForgeCredit f where
  forgeCredit :: f p -> f p
instance ForgeCredit f => ForgeCredit (M1 i metadata f) where
  forgeCredit (M1 value) = M1 (forgeCredit value)
instance (ForgeCredit a, ForgeCredit b) => ForgeCredit (a :*: b) where
  forgeCredit (a :*: b) = forgeCredit a :*: forgeCredit b
instance {-# OVERLAPPING #-} ForgeCredit (K1 i (Maybe Integer)) where
  forgeCredit _ = K1 (Just 130)
instance {-# OVERLAPPABLE #-} ForgeCredit (K1 i a) where
  forgeCredit = id
fabricateCreditedDuty :: DutyEvidence -> DutyEvidence
fabricateCreditedDuty evidence = to (forgeCredit (from evidence))
"""


def check(ghc, core, scratch):
    cases = [("getters", GETTERS, ())]
    for field, value in [
        ("dutyTick", "dutyTick evidence"),
        ("dutyTarget", "dutyTarget evidence"),
        ("dutyCrew", "[]"),
        ("dutyCredit", "Just 130"),
    ]:
        source = f"""module Client where
import Colony.Workforce
forge :: DutyEvidence -> DutyEvidence
forge evidence = evidence {{{field} = {value}}}
"""
        cases.append((field, source, (field, "not a record selector")))
    cases.append(("generic-credit-forgery", GENERIC_FORGERY,
                  ("No instance for", "Generic DutyEvidence")))
    for name, source, expected_errors in cases:
        directory = scratch / name
        directory.mkdir(parents=True, exist_ok=True)
        client = directory / "Client.hs"
        client.write_text(source, encoding="utf-8")
        result = subprocess.run(
            [ghc, "-v0", "-fno-code", "-Wall", "-Werror", "-XGHC2021",
             "-i" + str(core), "-outputdir", str(directory),
             "-tmpdir", str(directory), str(client)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=60, check=False,
        )
        output = result.stdout + result.stderr
        (directory / "compiler.log").write_text(output, encoding="utf-8")
        if not expected_errors:
            if result.returncode:
                raise AssertionError(f"public getters failed to compile:\n{output}")
        elif not result.returncode:
            raise AssertionError(f"evidence forgery was accepted: {name}")
        elif not all(expected in output for expected in expected_errors):
            raise AssertionError(f"{name} failed for an unrelated reason:\n{output}")
        print("PASS:", name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghc", default=shutil.which("ghc"))
    parser.add_argument("--core", type=Path,
                        default=Path(__file__).resolve().parents[1] / "core")
    parser.add_argument("--scratch", type=Path)
    args = parser.parse_args()
    if not args.ghc:
        parser.error("GHC is required")
    if args.scratch:
        check(args.ghc, args.core.resolve(), args.scratch.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="workforce-api-") as temporary:
            check(args.ghc, args.core.resolve(), Path(temporary))


if __name__ == "__main__":
    main()
