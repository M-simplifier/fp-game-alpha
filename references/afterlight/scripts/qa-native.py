"""Compare the original and rewritten Windows GPU outputs using shared assets.

The smoke uses the real complete runtime, a frozen authored world and bounded
observer mode: no OS input polling, pointer capture or user save writes.
Byte-identical PNG files imply identical decoded pixels as well.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RENDER_CASES = ["day-FullQuality", "day-BalancedQuality", "day-LightQuality", "night", "dusk",
                "wide-odd", "portrait-tele", "no-shadows", "no-ao", "no-clouds", "no-bloom", "restored-high"]
SMOKE_CASES = ["day", "dusk", "night", "return"]
SOUNDS = ["day", "night", "Mine", "Build", "Jewel", "Offering", "Wound", "Jump", "Strike", "Dusk", "Wings", "Return", "Dash"]


def binary(package, name):
    plan = json.loads((package / "dist-newstyle/cache/plan.json").read_text(encoding="utf-8"))
    paths = [p["bin-file"] for p in plan["install-plan"] if p.get("component-name") == "exe:" + name]
    if len(paths) != 1 or not Path(paths[0]).is_file():
        raise SystemExit(f"Build {name} first; expected exactly one executable in plan.json")
    return paths[0]


def compare_bytes(old, new):
    a, b = old.read_bytes(), new.read_bytes()
    return {"bytes_identical": a == b, "original_sha256": hashlib.sha256(a).hexdigest(),
            "rewrite_sha256": hashlib.sha256(b).hexdigest(), "bytes": len(b)}


def compare(old, new):
    a, b = old.read_bytes(), new.read_bytes()
    if a[:8] != b"\x89PNG\r\n\x1a\n" or b[:8] != a[:8]:
        raise SystemExit("Expected PNG screenshot")
    return {**compare_bytes(old, new), "size": list(struct.unpack(">II", b[16:24]))}


def gpu(log):
    text = log.read_text(encoding="utf-8", errors="replace")
    return {"renderer": re.findall(r"Renderer:\s*(.+)", text), "gl_version": re.findall(r"> Version:\s*(.+)", text),
            "hdr_observed": "hdr=True" in text,
            "render_check_completed": "Render check complete; no pointer or input APIs were used." in text}


def smoke(package, name, label):
    executable = binary(package, name)
    output = package / ".runtime/native-smoke"
    output.mkdir(parents=True, exist_ok=True)
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GARDEN_")}
    environment.update(GARDEN_INPUT="observe", GARDEN_PAUSED="1", GARDEN_FRAMES="48", GARDEN_SHOT="40",
                       GARDEN_WIDTH="1280", GARDEN_HEIGHT="720", GARDEN_QUALITY="high", GARDEN_HUD="1",
                       GARDEN_SAVE_PATH=str(output / "unused-save-v2.txt"))
    for scene in SMOKE_CASES:
        # raylib TakeScreenshot prepends its working directory; supply a
        # relative path rather than a Windows drive-qualified filename.
        environment.update(GARDEN_SCENE=scene, GARDEN_IMAGE=f".runtime/native-smoke/{scene}.png")
        with (output / f"{scene}.log").open("wb") as log:
            subprocess.run([executable], cwd=package, env=environment, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=60)
        screenshot = output / f"{scene}.png"
        if not screenshot.is_file() or screenshot.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"{label} runtime exited without a PNG capture: {scene}; inspect its log")
        print(f"{label} native runtime captured: {scene}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/qa/NATIVE-COMPARISON.json")
    args = parser.parse_args()
    original = args.original.resolve()
    if args.smoke:
        smoke(original, "noema-garden", "original")
        smoke(ROOT, "afterlight-native", "rewrite")
    records = {name: compare(original / f".runtime/render-check/{name}.png", ROOT / f".runtime/render-check/{name}.png")
               for name in RENDER_CASES}
    runtime = {name: compare(original / f".runtime/native-smoke/{name}.png", ROOT / f".runtime/native-smoke/{name}.png")
               for name in SMOKE_CASES} if (ROOT / ".runtime/native-smoke/return.png").exists() else {}
    audio = {name: compare_bytes(original / f"assets/garden-audio/{name}.wav", ROOT / f"assets/garden-audio/{name}.wav")
             for name in SOUNDS}
    result = {"schema": 1, "baseline": "6367b56e3ff2042199667f2a5bfa50695f4aaf2f",
              "mode": "Windows native real GPU, hidden observer windows; not software GLES, not human input/feel",
              "render_cases": records, "runtime_cases": runtime, "audio_files": audio,
              "original_gpu": gpu(original / ".runtime/logs/render-check.txt"),
              "rewrite_gpu": gpu(ROOT / ".runtime/logs/render-check.txt"),
              "quality_churn_count_per_renderer": 18,
              "runtime_protocol": {"world": "same original deterministic initialWorld / authored scene", "input": "idle",
                                   "semantic_time": "frozen (GARDEN_PAUSED=1)", "frames": 48, "capture_frame": 40,
                                   "size": [1280,720], "quality": "high", "hud": True},
              "shared_font": json.loads((ROOT / ".runtime/assets-manifest.json").read_text(encoding="utf-8"))[:3],
              "all_png_bytes_identical": all(x["bytes_identical"] for x in [*records.values(), *runtime.values()]),
              "all_wav_bytes_identical": all(x["bytes_identical"] for x in audio.values()),
              "nonclaims": ["human mouse/keyboard feel", "audible playback", "browser WebGL hardware", "performance equivalence"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"Compared {len(records)} renderer + {len(runtime)} runtime PNGs; identical={result['all_png_bytes_identical']}")
    print(f"Compared {len(audio)} complete PCM WAV files; identical={result['all_wav_bytes_identical']}")
    if not result["all_png_bytes_identical"] or not result["all_wav_bytes_identical"]:
        raise SystemExit("Native screenshots/audio differ; inspect before claiming parity")


if __name__ == "__main__":
    main()
