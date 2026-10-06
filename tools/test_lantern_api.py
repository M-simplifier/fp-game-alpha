"""Exercise the public Lantern API with actual GHC compilation.

The negative fixture must fail for a record-update reason, after a positive
consumer and the Lantern dependencies have compiled successfully.
"""

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "references" / "lantern" / "test"
OUT = ROOT / ".build" / "lantern-api"


def compile_fixture(ghc, name):
    build = OUT / name
    build.mkdir(parents=True, exist_ok=True)
    command = [ghc, "-fno-code", "-fforce-recomp", "-XGHC2021",
               "-fdiagnostics-color=never",
               "-i" + str(ROOT / "libraries" / "game-transition" / "src"),
               "-i" + str(ROOT / "libraries" / "game-arena" / "src"),
               "-i" + str(ROOT / "references" / "lantern" / "src"),
               "-outputdir", str(build), str(TEST / (name + ".hs"))]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=90)
    output = result.stdout + result.stderr
    (OUT / (name + ".log")).write_bytes(output)
    return result.returncode, output.decode("utf-8", errors="replace")


def main():
    ghc = shutil.which("ghc")
    if ghc is None:
        raise RuntimeError("GHC must be on PATH for this separate helper; see docs/setup.md.")
    good_code, _ = compile_fixture(ghc, "WorldRead")
    if good_code != 0:
        raise RuntimeError("Public projection/dependencies failed to compile")
    bad_code, diagnostic = compile_fixture(ghc, "RejectWorldUpdate")
    if (bad_code == 0 or "positions" not in diagnostic
            or "is not a record selector" not in diagnostic or "error:" not in diagnostic):
        raise RuntimeError("External record update was not rejected as intended")
    print("lantern public API: PASS (projections compile; record update rejected)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"lantern public API: FAIL: {error}; see ignored .build/lantern-api logs", file=sys.stderr)
        raise SystemExit(1)
