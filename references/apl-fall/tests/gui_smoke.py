"""Finite native-window traces. Host injects only key bits and a fixed clock."""
from pathlib import Path
import os
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("ARRAY_FALL_RUNTIME", str(ROOT / ".runtime")))
OUT = ROOT / ".scratch" / "evidence"


def press(events, frame, key):
    events.extend([(frame, key, 1), (frame + 1, key, 0)])


def run(name, frames, events=(), extra=(), snapshot=0):
    OUT.mkdir(parents=True, exist_ok=True)
    fixture = OUT / f"{name}-input.txt"
    fixture.write_text("# frame key-index down\n" + "".join(f"{f} {k} {v}\n" for f, k, v in sorted(events)), encoding="ascii")
    shot = OUT / f"{name}.png"
    command = [str(RUNTIME / "bin/array-host.exe"), "--width", "1080", "--height", "800", "--fps", "120",
               "--frames", str(frames), "--fixed-dt", "0.0166666666667", "--input", str(fixture),
               "--screenshot", str(shot), "--title", f"ARRAY FALL / {name}"]
    if snapshot:
        command += ["--snapshot-frame", str(snapshot)]
    for source in ["apl/core.apl", "apl/inspect.apl", "tests/fixed-seed.apl", *extra, "apl/game.apl"]:
        command.append(str(ROOT / source))
    began = time.perf_counter()
    result = subprocess.run(command, cwd=ROOT, capture_output=True, encoding="utf-8", timeout=40)
    elapsed = time.perf_counter() - began
    log = result.stdout + result.stderr
    (OUT / f"{name}.log").write_text(log, encoding="utf-8")
    assert result.returncode == 0 and "protocol=ok" in log, (name, log)
    assert shot.is_file(), (name, "missing native screenshot")
    found = re.search(r"game score=(\d+) lines=(\d+) pieces=(\d+) ticks=(\d+) seed=(\d+) mode=(\d+) type=(\d+) pose=(\d+) hold=([¯\-]?\d+)", log)
    assert found, (name, log)
    values = [int(value.replace("¯", "-")) for value in found.groups()]
    state = dict(zip(["score", "lines", "pieces", "ticks", "seed", "mode", "type", "pose", "hold"], values))
    print(f"GUI PASS {name}: {state} ({elapsed:.3f}s / {frames} presented frames)")
    return {"name": name, "frames": frames, "seconds": round(elapsed, 3), "screenshot": str(shot.relative_to(ROOT)), **state}


def main():
    results = []
    start = run("opening", 3)
    assert start["pose"] == 58 and start["mode"] == 0
    results.append(start)
    first = run("inspect-first", 3, extra=["apl/demo.apl"], snapshot=2)
    assert first["mode"] == 3 and first["ticks"] == 0
    results.append(first)
    t_piece = run("inspect-t", 20, extra=["tests/t-inspect.apl"])
    assert t_piece["type"] == 5 and t_piece["mode"] == 3
    results.append(t_piece)
    controls = [(1, 1, 1), (18, 1, 0), (30, 0, 1), (45, 0, 0), (50, 2, 1), (62, 2, 0)]
    for frame, key in [(20, 5), (25, 6), (46, 4), (64, 6), (70, 10), (75, 7), (95, 7)]:
        press(controls, frame, key)
    played = run("controls", 130, controls)
    assert played["pieces"] == 2 and played["hold"] == 2 and played["ticks"] == 108 and played["mode"] == 0
    results.append(played)
    paused = run("paused", 90, controls)
    assert paused["mode"] == 1 and paused["ticks"] == 74
    results.append(paused)
    witness = []
    for frame in range(2, 18, 2):
        press(witness, frame, 14)  # eighth supported landing = the two-row opening
    press(witness, 18, 12)         # replay saved witness through MoveAction
    press(witness, 150, 11)        # resume clock, already at selected landing
    press(witness, 152, 6)         # lock exactly there
    double = run("witness-double", 160, witness, extra=["apl/demo.apl"])
    assert double["lines"] == 2 and double["pieces"] == 1 and double["score"] == 300 and double["mode"] == 0
    results.append(double)
    repeated = []
    for frame in range(1, 80, 2):
        press(repeated, frame, 6)
    over = run("gameover", 90, repeated)
    assert over["mode"] == 2 and over["pieces"] > 5
    results.append(over)
    press(repeated, 82, 8)
    restarted = run("restarted", 100, repeated)
    assert restarted["mode"] == 0 and restarted["pieces"] == 0 and restarted["score"] == 0 and restarted["ticks"] == 17
    results.append(restarted)
    (OUT / "gui-summary.json").write_text(json.dumps({"status": "passed", "traces": results}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
