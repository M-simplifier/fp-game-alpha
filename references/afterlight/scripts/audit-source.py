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
for name, record in formats.items():
    path = ROOT / name
    if not path.resolve().is_relative_to(ROOT) or "oracle" in path.parts or path.suffix != ".hs":
        raise SystemExit("Unsafe formatting record: " + name)
    if name in original_hashes and name not in CHANGED and record["pre_format_sha256"] != original_hashes[name]:
        raise SystemExit("Formatting preimage differs from original: " + name)
    if record["baseline_sha256"] != original_hashes.get(name):
        raise SystemExit("Formatting baseline mismatch: " + name)
    if hashlib.sha256(path.read_bytes()).hexdigest() != record["formatted_sha256"]:
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
          "oracle_modules_verified": len(manifest["oracle"]), "recovered_gallery_core_matched": matched,
          "gallery_comparison_status": "not_run: original private gallery is not a public dependency",
          "original_git_modes_verified": mode_count,
          "gallery_comparison": "LF canonical source; CRLF checkout conversion removed only for earlier gallery files",
          "status": "pass"}
output = ROOT / "docs/qa/SOURCE-AUDIT.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
print(f"PASS original {len(unchanged)} unchanged + {len(rewritten)} intentional rewrites; oracle {len(manifest['oracle'])}; earlier gallery comparison not run")
