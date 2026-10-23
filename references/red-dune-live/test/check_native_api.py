#!/usr/bin/env python3
"""Check ordinary consumers of the native executable's Store module."""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def cases():
    yield "queries", """module Client where
import RedDune.Native.Store
import RedDune.Game (GameState)
query :: Store -> Preview -> (FilePath, String, GameState)
query store preview = (storeRoot store, previewName preview, previewGame preview)
""", ()
    for field, kind in [("storeRoot", "Store"), ("previewName", "Preview"), ("previewGame", "Preview")]:
        yield field, f"""module Client where
import RedDune.Native.Store
attack :: {kind} -> {kind}
attack value = value {{{field} = {field} value}}
""", (field, "not a record selector")
    for kind in ["Store", "Preview"]:
        yield kind + "-generic", f"""module Client where
import RedDune.Native.Store
import GHC.Generics (from, to)
attack :: {kind} -> {kind}
attack value = to (from value)
""", ("No instance for", "Generic " + kind)


def check(ghc, scratch):
    native = Path(__file__).resolve().parents[1] / "native"
    for name, source, errors in cases():
        directory = scratch / name
        directory.mkdir(parents=True, exist_ok=True)
        client = directory / "Client.hs"
        client.write_text(source, encoding="utf-8")
        command = [ghc, "-v0", "-fno-code", "-Wall", "-Werror", "-XGHC2021",
                   "-hide-all-packages", "-i" + str(native),
                   "-outputdir", str(directory), "-tmpdir", str(directory)]
        for package in ["base", "bytestring", "containers", "directory", "filepath", "red-dune-live"]:
            command.extend(["-package", package])
        compiled = subprocess.run(command + [str(client)], capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=60, check=False)
        output = compiled.stdout + compiled.stderr
        (directory / "compiler.log").write_text(output, encoding="utf-8")
        if not errors and compiled.returncode:
            raise AssertionError("ordinary native query failed:\n" + output)
        if errors and (not compiled.returncode or not all(error in output for error in errors)):
            raise AssertionError(f"forbidden {name} was accepted or failed for an unrelated reason:\n{output}")
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
        with tempfile.TemporaryDirectory(prefix="red-dune-native-api-") as temporary:
            check(args.ghc, Path(temporary))


if __name__ == "__main__":
    main()
