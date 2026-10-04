"""Run the source-only GHC checks; this does not invoke LiquidHaskell.

Outputs live in the ignored .build directory. Exit 0 requires the named
compiler rejections, the independent Python oracle, and exact annotated-source
runtime agreement. A historical LiquidHaskell SAFE result is never inferred.
"""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import oracle


ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / ".build" / "quantity"
FIXTURE_HASH = "082f8af0cb1a2de3e4faa62753b31a2d263e232fd729f318ac9d58a813f9ef75"
ANNOTATED_HASH = "d90d4fce3bf1d6220a4366b4d05316002919b5c6e50b7d4b9e43ef9571c8d46d"
TESTED_GHC = "9.6.7"
NEGATIVE = {
    "RejectConstructorImport": ("Qty", "does not export"),
    "RejectCrossAdd": ("Qty", "WaterTag", "OreTag", "Couldn't match"),
    "RejectCrossCoerce": ("WaterTag", "OreTag", "Couldn't match"),
    "RejectCrossSub": ("Qty", "WaterTag", "OreTag", "Couldn't match"),
    "RejectHiddenConstructor": ("Qty",),
    "RejectPromotedCoerce": ("Water", "Ore", "Couldn't match"),
    "RejectRawCoerce": ("Qty", "Couldn't match"),
    "RejectRepresentationalTagCoerce": ("WaterTag", "OreTag", "Couldn't match"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(command, *, timeout=240, stdin=None, stdout=None):
    return subprocess.run(command, cwd=ROOT, stdin=stdin,
                          stdout=subprocess.PIPE if stdout is None else stdout,
                          stderr=subprocess.PIPE, timeout=timeout, check=False)


def tool(name, flag):
    executable = shutil.which(os.environ.get(name.upper(), name))
    if executable is None:
        return None, None
    result = subprocess.run([executable, flag], capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=20)
    return executable, result.stdout.strip() if result.returncode == 0 else None


def doctor():
    ghc, version = tool("ghc", "--numeric-version")
    liquid, liquid_version = tool("liquid", "--version")
    z3, z3_version = tool("z3", "--version")
    report = {"ghc": version, "tested_ghc": TESTED_GHC,
              "source_only_checks_ready": version == TESTED_GHC,
              "liquidhaskell": liquid_version if liquid else None,
              "z3": z3_version if z3 else None,
              "liquidhaskell_result": "not_run"}
    print(json.dumps(report, indent=2))
    return ghc if version == TESTED_GHC else None


def compile_module(ghc, name, source, module_root, *, code_only=False):
    output_dir = OUT / "build" / name
    output_dir.mkdir(parents=True, exist_ok=True)
    command = [ghc, "-fforce-recomp", "-fdiagnostics-color=never",
               "-i" + str(module_root), "-i" + str(source.parent),
               "-outputdir", str(output_dir)]
    if code_only:
        command += ["-fno-code"]
    else:
        command += ["-O1", "-o", str(output_dir / "quantity-runner")]
    command.append(str(source))
    result = invoke(command, timeout=180)
    log = (result.stdout or b"") + result.stderr
    (OUT / "logs" / (name + ".log")).write_bytes(log)
    return result.returncode, log.decode("utf-8", errors="replace"), output_dir / "quantity-runner"


def static_checks(ghc):
    checks = []
    fixture = ROOT / "fixture"
    static = ROOT / "static"
    cases = [("Positive", True, ())] + [(name, False, markers) for name, markers in NEGATIVE.items()]
    cases += [("ExposedRoleCaveat", True, ())]
    for name, should_compile, markers in cases:
        source = (ROOT / "model-caveat" if name == "ExposedRoleCaveat" else static) / (name + ".hs")
        code, diagnostic, _ = compile_module(ghc, "static-" + name, source, fixture, code_only=True)
        expected = (code == 0) == should_compile
        expected = expected and all(marker in diagnostic for marker in markers)
        if not should_compile:
            expected = expected and ("error:" in diagnostic or "error [" in diagnostic)
        checks.append({"case": name, "expected_compiles": should_compile,
                       "actual_compiles": code == 0, "diagnostic_matched": expected})
        print(f"{name}: {'PASS' if expected else 'FAIL'}")
    if not all(case["diagnostic_matched"] for case in checks):
        raise RuntimeError("Compiler case mismatch; inspect ignored .build/quantity/logs")
    return checks


def write_vectors():
    counts = Counter()
    requests = OUT / "requests.tsv"
    expected = OUT / "expected.tsv"
    with requests.open("w", encoding="ascii", newline="\n") as req, expected.open("w", encoding="ascii", newline="\n") as exp:
        for category, command in oracle.vectors():
            counts[category] += 1
            req.write(command + "\n")
            exp.write(oracle.expected(command.split()) + "\n")
    if sum(counts.values()) != 631_024:
        raise RuntimeError(f"Oracle vector identity changed: {sum(counts.values())} rows")
    return requests, expected, counts


def verify_output(name, executable, requests, expected):
    observed = OUT / (name + ".tsv")
    with requests.open("rb") as req, observed.open("wb") as out:
        result = invoke([str(executable)], stdin=req, stdout=out, timeout=240)
    if result.returncode != 0:
        raise RuntimeError(f"{name} runtime exited {result.returncode}: " +
                           result.stderr.decode("utf-8", errors="replace")[-500:])
    with expected.open(encoding="ascii") as wanted, observed.open(encoding="ascii") as got:
        for row, pair in enumerate(zip(wanted, got, strict=True), start=1):
            if pair[0].rstrip("\r\n") != pair[1].rstrip("\r\n"):
                raise RuntimeError(f"{name} differs from independent oracle at row {row}")
    return digest(observed)


def check(ghc):
    if sys.flags.optimize:
        raise RuntimeError("Run without Python -O; the supplied oracle uses assertions")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "logs").mkdir(exist_ok=True)
    fixture = ROOT / "fixture" / "Colony" / "Units.hs"
    annotated = ROOT / "annotated" / "Colony" / "Units.hs"
    if digest(fixture) != FIXTURE_HASH or digest(annotated) != ANNOTATED_HASH:
        raise RuntimeError("Frozen source digest mismatch")
    cases = static_checks(ghc)
    requests, expected, counts = write_vectors()
    output_hashes = {}
    for name, source_dir in (("fixture", ROOT / "fixture"), ("annotated", ROOT / "annotated")):
        code, _, executable = compile_module(ghc, "run-" + name, ROOT / "runtime" / "Main.hs", source_dir)
        if code != 0:
            raise RuntimeError(f"{name} runner failed to compile; inspect ignored .build/quantity/logs")
        output_hashes[name] = verify_output(name, executable, requests, expected)
    if output_hashes["fixture"] != output_hashes["annotated"]:
        raise RuntimeError("Original and annotation-only output bytes differ")
    report = {"status": "PASS", "scope": "finite GHC type checks and runtime oracle; no LiquidHaskell proof",
              "ghc": TESTED_GHC, "fixture_sha256": FIXTURE_HASH, "annotated_sha256": ANNOTATED_HASH,
              "vectors": sum(counts.values()), "categories": dict(counts),
              "static_cases": cases, "output_sha256": output_hashes,
              "liquidhaskell_result": "not_run"}
    (OUT / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("quantity source-only checks: PASS (8 expected type rejections, 631024 oracle rows x 2; LiquidHaskell not run)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["doctor", "check"])
    action = parser.parse_args().action
    ghc = doctor()
    if ghc is None:
        raise RuntimeError("GHC 9.6.7 is required for this validated source-only route")
    if action == "check":
        check(ghc)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"quantity check: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
