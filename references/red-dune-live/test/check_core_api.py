#!/usr/bin/env python3
"""Check public package clients; run with cabal exec after building the library."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def cases():
    result = [(
        "session-queries",
        """module Client where
import Colony.Session
import Colony.Types (Epoch)
query :: Session -> (String, Epoch)
query value = (sessionAuthority value, sessionEpoch value)
""", ())]
    for field in ["sessionAuthority", "sessionEpoch"]:
        result.append((field, f"""module Client where
import Colony.Session
attack :: Session -> Session
attack value = value {{{field} = {field} value}}
""", (field, "not a record selector")))
    result.append(("session-generic", """module Client where
import Colony.Session
import GHC.Generics (from, to)
attack :: Session -> Session
attack value = to (from value)
""", ("No instance for", "Generic Session")))
    if sys.platform != "win32":
        result.append(("snapshot-queries", """module Client where
import Colony.Save
import Colony.Codec (CheckpointMeta)
import Colony.Types (SimTick)
import Data.ByteString (ByteString)
query :: CapturedSnapshot -> (SaveTicket, CheckpointMeta, SimTick, ByteString, String)
query value = (capturedTicket value, capturedMeta value, capturedTick value,
               capturedStateHash value, show value)
""", ()))
        for field in ["capturedTicket", "capturedMeta", "capturedTick", "capturedStateHash"]:
            result.append((field, f"""module Client where
import Colony.Save
attack :: CapturedSnapshot -> CapturedSnapshot
attack value = value {{{field} = {field} value}}
""", (field, "not a record selector")))
        result.append(("snapshot-generic", """module Client where
import Colony.Save
import GHC.Generics (from, to)
attack :: CapturedSnapshot -> CapturedSnapshot
attack value = to (from value)
""", ("No instance for", "Generic CapturedSnapshot")))
    for module in ["Colony.Codec.Instances", "Colony.Transport.State", "Colony.Transport.Dispatch"]:
        result.append((module, f"module Client where\nimport {module} ()\n",
                       (module, "hidden module")))
    return result


def check(ghc, scratch):
    for name, source, expected_errors in cases():
        directory = scratch / name
        directory.mkdir(parents=True, exist_ok=True)
        client = directory / "Client.hs"
        client.write_text(source, encoding="utf-8")
        command = [ghc, "-v0", "-fno-code", "-Wall", "-Werror", "-XGHC2021",
                   "-hide-all-packages", "-package", "base", "-package", "bytestring",
                   "-package", "red-dune-live", "-outputdir", str(directory),
                   "-tmpdir", str(directory), str(client)]
        compiled = subprocess.run(command, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=60,
                                  check=False)
        output = compiled.stdout + compiled.stderr
        (directory / "compiler.log").write_text(output, encoding="utf-8")
        if not expected_errors and compiled.returncode:
            raise AssertionError(f"ordinary public query failed: {name}\n{output}")
        if expected_errors and not compiled.returncode:
            raise AssertionError(f"private construction/update/import was accepted: {name}")
        if expected_errors and not all(error in output for error in expected_errors):
            raise AssertionError(f"client failed for an unrelated reason: {name}\n{output}")
        print("PASS:", name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghc", default=shutil.which("ghc"))
    parser.add_argument("--scratch", type=Path)
    args = parser.parse_args()
    if not args.ghc:
        parser.error("GHC is required")
    if args.scratch:
        check(args.ghc, args.scratch.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="red-dune-core-api-") as temporary:
            check(args.ghc, Path(temporary))


if __name__ == "__main__":
    main()
