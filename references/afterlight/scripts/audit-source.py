"""Verify fixed original source and oracle provenance, including restored hosts."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CHANGED = {
    "runtime/Garden/Runtime.hs": "World/Clock/Pilot fold -> pure Garden.Session; Arena.play and complete observe; original effects retained",
    "web/build.sh": "Package identity and shared L library paths; original linker executable mode restored if lost in a Windows archive; excluded independent documentation guide made optional",
    "web/cabal.project.template": "Package identity and shared L library paths",
    "web/prepare-assets.py": "Include relocated runtime sources in the conservative Japanese glyph inventory",
}

manifest = json.loads((ROOT / "docs/BASELINE-MANIFEST.json").read_text(encoding="utf-8"))
format_file = ROOT / "docs/FORMAT-MANIFEST.json"
format_rows = json.loads(format_file.read_text(encoding="utf-8"))["files"] if format_file.exists() else []
formats = {record["path"]: record for record in format_rows}
if len(formats) != len(format_rows):
    raise SystemExit("Duplicate formatting record")
original_hashes = {record["path"]: record["sha256"] for record in manifest["files"]}
# This single reviewed successor is deliberately not a general exemption mechanism.
# Preserve the historical format hashes and the independent baseline/oracle checks.
successor = json.loads((ROOT / "docs/TEST-OPTIMIZATION-MANIFEST.json").read_text(encoding="utf-8"))
if successor.get("schema") != 1 or successor.get("kind") != "reviewed-test-optimization":
    raise SystemExit("Invalid test optimization provenance")
rows = successor["files"]
optimizations = {record["path"]: record for record in rows}
allowed = {"test/Parity.hs", "test/TerrainEquality.hs", "afterlight-arena.cabal"}
if len(optimizations) != len(rows) or set(optimizations) != allowed:
    raise SystemExit("Unexpected test optimization scope")
for name, record in optimizations.items():
    previous = formats["test/Parity.hs"]["formatted_sha256"] if name == "test/Parity.hs" else None
    if record["previous_formatted_sha256"] != previous:
        raise SystemExit("Test optimization predecessor mismatch: " + name)
    if name != "test/Parity.hs" and (name in formats or name in original_hashes):
        raise SystemExit("Test optimization cannot exempt baseline or formatted source: " + name)
    path = ROOT / name
    if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
        raise SystemExit("Unsafe test optimization path: " + name)
    if hashlib.sha256(path.read_bytes()).hexdigest() != record["current_sha256"]:
        raise SystemExit("Test optimization source changed: " + name)
for name, record in formats.items():
    path = ROOT / name
    if not path.resolve().is_relative_to(ROOT) or "oracle" in path.parts or path.suffix != ".hs":
        raise SystemExit("Unsafe formatting record: " + name)
    if name in original_hashes and name not in CHANGED and record["pre_format_sha256"] != original_hashes[name]:
        raise SystemExit("Formatting preimage differs from original: " + name)
    if record["baseline_sha256"] != original_hashes.get(name):
        raise SystemExit("Formatting baseline mismatch: " + name)
    expected = optimizations[name]["current_sha256"] if name in optimizations else record["formatted_sha256"]
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit("Formatted source changed since reviewed formatting: " + name)
unchanged, rewritten = [], []
for record in manifest["files"]:
    path = ROOT / record["path"]
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if record["path"] in CHANGED or record["path"] in formats:
        rewritten.append({"path": record["path"], "origin_sha256": record["sha256"], "current_sha256": digest,
                          "reason": CHANGED.get(record["path"], "") + ("; reviewed Ormolu 0.9.0.0 formatting, exact current hash locked" if record["path"] in formats else "")})
    else:
        if digest != record["sha256"]:
            raise SystemExit(f"Unexpected original source change: {record['path']}")
        unchanged.append(record["path"])
for record in manifest["oracle"]:
    if hashlib.sha256((ROOT / record["path"]).read_bytes()).hexdigest() != record["sha256"]:
        raise SystemExit(f"Oracle changed: {record['path']}")
mode_count = 0
repository = ROOT.parents[1]
if (repository / ".git").exists():
    entries = subprocess.check_output(
        ["git", "-c", f"safe.directory={repository.as_posix()}", "-C", str(repository),
         "ls-files", "--stage", "--", "references/afterlight"], text=True).splitlines()
    modes = {line.split("\t", 1)[1]: line.split()[0] for line in entries}
    for record in manifest["files"]:
        path = "references/afterlight/" + record["path"]
        if path in modes:
            if modes[path] != record["mode"]:
                raise SystemExit(f"Original executable mode changed: {record['path']}")
            mode_count += 1
matched = []
result = {"schema": 1, "baseline": manifest["baseline"], "original_files": len(manifest["files"]),
          "unchanged_original_files": unchanged, "intentional_changes": rewritten,
          "reviewed_test_optimization": successor,
          "oracle_modules_verified": len(manifest["oracle"]), "recovered_gallery_core_matched": matched,
          "gallery_comparison_status": "not_run: original private gallery is not a public dependency",
          "original_git_modes_verified": mode_count,
          "gallery_comparison": "LF canonical source; CRLF checkout conversion removed only for earlier gallery files",
          "status": "pass"}
output = ROOT / "docs/qa/SOURCE-AUDIT.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
print(f"PASS original {len(unchanged)} unchanged + {len(rewritten)} intentional rewrites; oracle {len(manifest['oracle'])}; earlier gallery comparison not run")
