"""Archive successful local QA logs, replacing only absolute checkout paths.

Run the checks first. This records their output, not a substitute execution.
The original checkout is used only to read its standalone baseline check log.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True)
    args = parser.parse_args()
    original = args.original.resolve()
    destination = ROOT / "docs/qa"
    destination.mkdir(parents=True, exist_ok=True)

    def read(path):
        return path.read_text(encoding="utf-8", errors="replace")

    def sanitize(content):
        for path, label in [(ROOT, "<afterlight-package>"), (original, "<original-checkout>"),
                            (ROOT.parents[1], "<l-repository>")]:
            for form in [str(path).replace("\\", "\\\\"), str(path), path.as_posix()]:
                content = content.replace(form, label)
        return content

    def write(name, content):
        path = destination / name
        path.write_text(sanitize(content), encoding="utf-8", newline="\n")

    tests = read(ROOT / ".runtime/logs/final-tests.txt")
    suites = ["arena-laws", "original-checks", "parity"]
    for suite in suites:
        if f"Test suite {suite}: PASS" not in tests:
            raise SystemExit(f"Missing successful final suite: {suite}")
    write("tests.txt", tests)
    start = tests.index("Test suite parity: RUNNING...")
    end = tests.index("Test suite parity: PASS", start) + len("Test suite parity: PASS")
    write("parity.txt", "Extract of final cabal test all; concurrent suite output may be interleaved.\n" + tests[start:end] + "\n")
    baseline = read(original / ".runtime/logs/original-checks.txt")
    if "All garden checks passed." not in baseline:
        raise SystemExit("Original baseline checks did not pass")
    write("original-checks.txt", baseline)
    copies = {
        "native-build.txt": "final-build.txt",
        "browser-host.txt": "browser-host-tests.txt",
        "browser-bundle.txt": "browser-host-build.txt",
        "browser-assets.txt": "browser-assets-prepare.txt",
        "browser-assets-tests.txt": "browser-assets-tests.txt",
    }
    for target, source in copies.items():
        write(target, read(ROOT / ".runtime/logs" / source))
    host = read(destination / "browser-host.txt")
    asset_tests = read(destination / "browser-assets-tests.txt")
    if "pass 42" not in host or "fail 0" not in host or "Ran 8 tests" not in asset_tests or "\nOK\n" not in asset_tests:
        raise SystemExit("Expected host/asset success counts missing")
    gpu = json.loads((destination / "NATIVE-COMPARISON.json").read_text(encoding="utf-8"))
    if not (gpu["all_png_bytes_identical"] and gpu["all_wav_bytes_identical"]
            and len(gpu["render_cases"]) == 12 and len(gpu["runtime_cases"]) == 4 and len(gpu["audio_files"]) == 13):
        raise SystemExit("Expected complete native comparisons missing")

    def record(path):
        data = path.read_bytes()
        return {"path": path.relative_to(ROOT).as_posix(), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    result = {
        "schema": 1, "date": "2026-10-03", "baseline": gpu["baseline"],
        "native": {"ghc": "9.6.7", "cabal": "3.12.1.0", "h_raylib": "5.6.0.0", "yampa": "0.15", "quickcheck": "2.15.0.1"},
        "host": {"node": "24.13.0", "npm": "11.18.0", "python": "3.14.2"},
        "tests": {"command": "cabal test all -fnative --offline --test-show-details=direct", "status": "pass", "suites": suites,
                  "original_generated_cases": 800, "frame_generated_sequences": 160, "frame_seed": 20261003,
                  "story_island_route": {"frames": 5580, "ticks": 9067, "revision": 10, "pilot": [4, 0]},
                  "comparison": "complete World and exact/interpolated SceneView Eq; ordered Cue batches; bidirectional codec and continuation"},
        "build": {"command": "cabal build all -fnative --offline", "status": "pass", "fresh_source_builds": ["original", "rewrite"],
                  "dependency_cache_reused": True},
        "browser": {"host_tests": 42, "host_bundle": "pass", "prepared_assets": 23, "subset_codepoints": 430, "asset_http_tests": 8,
                    "fresh_cross_build": "not run: required Linux GHC-Wasm/Emscripten toolchain unavailable",
                    "real_webgl_and_interactive_qa": "not run"},
        "gpu": {"render_pngs": 12, "frozen_runtime_pngs": 4, "all_png_bytes_identical": True, "full_wav_files": 13,
                "all_wav_bytes_identical": True, "software_gles": False, "human_input_or_audition": "not run"},
        "verified_implementation": [record(ROOT / p) for p in ["src/Garden/Arena.hs", "src/Garden/Session.hs", "runtime/Garden/Runtime.hs",
                                     "test/Parity.hs", "afterlight-arena.cabal", "web/build.sh", "web/cabal.project.template", "web/prepare-assets.py"]],
        "evidence": [record(p) for p in sorted(destination.glob("*.txt"))]
                    + [record(destination / p) for p in ["SOURCE-AUDIT.json", "NATIVE-COMPARISON.json"]],
        "limits": "Feature-specific unverified items are listed in PARITY.md and VERIFICATION.md; this is not a formal proof or performance claim.",
    }
    (destination / "RESULTS.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("Archived successful three-suite, host, asset and GPU/audio evidence; personal checkout paths removed")


if __name__ == "__main__":
    main()
