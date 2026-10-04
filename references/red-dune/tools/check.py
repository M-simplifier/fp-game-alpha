#!/usr/bin/env python3
"""Verify a text-only export, then restore and check it without modifying inputs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def safe_path(value):
    if not isinstance(value, str) or value in ("", ".", "..") or "\\" in value:
        raise ValueError("invalid path")
    p = PurePosixPath(value)
    if p.is_absolute() or value != p.as_posix() or any(
        part in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", part)
        for part in p.parts
    ):
        raise ValueError("unsafe path: " + value)
    return p


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def read_file(root, relative):
    p = root
    for part in safe_path(relative).parts:
        p = p / part
        if p.is_symlink():
            raise ValueError("symlink input: " + relative)
    if not p.is_file():
        raise ValueError("missing regular file: " + relative)
    return p.read_bytes()


def manifest(root, name):
    obj = json.loads(read_file(root, name), object_pairs_hook=no_duplicate_keys)
    if set(obj) != {"schema", "files"} or obj["schema"] != 1 or not isinstance(obj["files"], list):
        raise ValueError("unsupported manifest")
    return obj["files"]


def verify_records(root, rows, encoded=True):
    # Read and validate every byte before creating any destination.
    result = {}
    stored_paths = set()
    for row in rows:
        fields = {"path", "sha256", "bytes"} | ({"stored", "encoding"} if encoded else set())
        if set(row) != fields:
            raise ValueError("unexpected record fields")
        name = safe_path(row["path"]).as_posix()
        stored = safe_path(row["stored"] if encoded else name).as_posix()
        if name in result or stored in stored_paths:
            raise ValueError("duplicate or conflicting record")
        if name.startswith((".build/", "vendor/")) or name in {"cabal.project", "cabal.project.local"}:
            raise ValueError("reserved destination")
        if not isinstance(row["bytes"], int) or isinstance(row["bytes"], bool) or row["bytes"] < 0:
            raise ValueError("invalid size")
        if not isinstance(row["sha256"], str) or not re.fullmatch("[0-9a-f]{64}", row["sha256"]):
            raise ValueError("invalid digest")
        payload = read_file(root, stored)
        encoding = row["encoding"] if encoded else "raw"
        if encoding == "base64":
            if not payload.endswith(b"\n") or b"\n" in payload[:-1]:
                raise ValueError("base64 must be one canonical line with final LF")
            data = base64.b64decode(payload[:-1], validate=True)
            if base64.b64encode(data) + b"\n" != payload:
                raise ValueError("noncanonical base64")
        elif encoding == "raw":
            data = payload
        else:
            raise ValueError("unknown encoding")
        if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise ValueError("hash/size mismatch: " + name)
        result[name] = data
        stored_paths.add(stored)
    names = set(result)
    for name in names:
        if any(parent.as_posix() in names for parent in PurePosixPath(name).parents):
            raise ValueError("file/directory path conflict")
    return result


def write_files(root, files):
    for name, data in files.items():
        p = root / safe_path(name)
        p.parent.mkdir(parents=True, exist_ok=True)
        # The root is freshly allocated; exclusive creation also forbids overwrite.
        with p.open("xb") as f:
            f.write(data)
        if p.read_bytes() != data:
            raise ValueError("restoration readback failed: " + name)


def prepare(root, foundation):
    source = verify_records(root, manifest(root, "RESTORE-MANIFEST.json"))
    core = verify_records(foundation, manifest(root, "FOUNDATION-MANIFEST.json"), encoded=False)
    if any(not n.startswith(("libraries/game-arena/", "libraries/game-transition/")) for n in core):
        raise ValueError("foundation outside approved libraries")
    builds = root / ".build"
    if builds.is_symlink():
        raise ValueError("symlink build root")
    builds.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="check-", dir=builds))
    package = work / "red-dune"
    write_files(package, source)
    write_files(work / "vendor", core)
    project = ("packages: red-dune\n"
               "          vendor/libraries/game-arena\n"
               "          vendor/libraries/game-transition\n"
               "active-repositories: :none\n")
    write_files(work, {"cabal.project": project.encode(),
                      "cabal.config": b"active-repositories: :none\n",
                      "cabal.project.local": b"tests: False\nbenchmarks: False\n"})
    return work, package


def check(work, package, cabal, ghc_bin):
    env = os.environ.copy()
    env["PATH"] = str(ghc_bin) + os.pathsep + env["PATH"]
    env["CABAL_DIR"] = str(work / "cabal-home")
    commands = [
        ["build", "exe:red-dune", "--offline"],
        ["run", "exe:red-dune", "--offline", "--", "test-m1"],
        ["run", "exe:red-dune", "--offline", "--", "test"],
    ]
    result = {"schema": 1, "scope": "fresh isolated Cabal build and Main test-m1/test entrypoints",
              "ghc": subprocess.check_output([str(ghc_bin / "ghc"), "--numeric-version"], text=True).strip(),
              "commands": [], "limits": ["No browser or HTTP bridge checked",
              "Not the historical full shell/fault/mutation/campaign/performance suite"]}
    for index, args in enumerate(commands):
        command = [str(cabal), "--config-file=" + str(work / "cabal.config")] + args
        # Keep project discovery explicit while runtime relative fixture paths use package cwd.
        command.insert(2, "--project-file=" + str(work / "cabal.project"))
        log = work / ("command-%d.log" % index)
        with log.open("xb") as output:
            proc = subprocess.run(command, cwd=package, env=env, stdout=output, stderr=subprocess.STDOUT)
        result["commands"].append({"args": args, "exit_code": proc.returncode,
                                   "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
        if proc.returncode:
            break
    write_files(work, {"CHECK-RESULT.json": (json.dumps(result, indent=2) + "\n").encode()})
    print(json.dumps(result, indent=2))
    return all(r["exit_code"] == 0 for r in result["commands"]) and len(result["commands"]) == 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify", "prepare", "check"])
    parser.add_argument("--foundation", type=Path)
    parser.add_argument("--cabal", type=Path)
    parser.add_argument("--ghc-bin", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        files = verify_records(ROOT, manifest(ROOT, "RESTORE-MANIFEST.json"))
        print("Verified %d restored files" % len(files))
        return
    if args.foundation is None:
        parser.error("--foundation is required")
    if args.action == "check" and (args.cabal is None or args.ghc_bin is None):
        parser.error("--cabal and --ghc-bin are required for check")
    work, package = prepare(ROOT, args.foundation.resolve())
    print("Isolated work directory: " + str(work), flush=True)
    if args.action == "check":
        if not check(work, package, args.cabal.resolve(), args.ghc_bin.resolve()):
            raise SystemExit("Check failed; inspect isolated command logs")


if __name__ == "__main__":
    main()
