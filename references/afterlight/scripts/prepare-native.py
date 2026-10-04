"""Prepare the original font paths, without installing a system font.

Only the official fixed Noto CJK 2.004 source is downloaded. Existing files
must match the published input hashes; shaders and user saves are untouched.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/"
FILES = [
    ("Sans/OTF/Japanese/NotoSansCJKjp-Regular.otf", "fonts/NotoSansCJKjp-Regular.otf",
     "68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5"),
    ("LICENSE", "fonts/LICENSE-NotoSansCJK.txt",
     "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, default=ROOT / "assets")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    assets = args.assets_dir.resolve()
    records = []
    for origin, name, expected in FILES:
        target = assets / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            cached_license = ROOT / "assets/licenses/NotoSansCJK-LICENSE.txt"
            if origin == "LICENSE" and cached_license.is_file() and digest(cached_license) == expected:
                shutil.copyfile(cached_license, target)
            else:
                if args.offline:
                    raise SystemExit(f"Missing pinned asset (offline): {target}")
                temporary = target.with_suffix(target.suffix + ".download")
                with urllib.request.urlopen(SOURCE + origin, timeout=60) as response:
                    temporary.write_bytes(response.read())
                if digest(temporary) != expected:
                    raise SystemExit(f"Downloaded asset hash mismatch: {temporary}")
                temporary.replace(target)
        if digest(target) != expected:
            raise SystemExit(f"Refusing to replace a different existing asset: {target}")
        records.append({"path": name, "source": SOURCE + origin, "sha256": expected, "bytes": target.stat().st_size})
    # These are conservative source characters, as in the original web asset
    # preparation. Restrict to the fixed font's supported Japanese/UI ranges.
    text = "".join(p.read_text(encoding="utf-8") for folder in ["src", "runtime"]
                   for p in sorted((ROOT / folder).rglob("*.hs")))
    points = set(range(32, 127)) | {ord(c) for c in text if
        0x2000 <= ord(c) <= 0x206F or 0x3000 <= ord(c) <= 0x30FF or
        0x4E00 <= ord(c) <= 0x9FFF or 0xFF00 <= ord(c) <= 0xFFEF}
    glyphs = assets / "fonts/glyphs.txt"
    glyphs.write_text("".join(map(chr, sorted(points))) + "\n", encoding="utf-8", newline="\n")
    records.append({"path": "fonts/glyphs.txt", "sha256": digest(glyphs), "characters": len(points),
                    "source": "ASCII and conservative Japanese/UI ranges from src/ and runtime/"})
    for path in sorted((assets / "garden-audio").glob("*.wav")):
        records.append({"path": path.relative_to(assets).as_posix(), "sha256": digest(path), "bytes": path.stat().st_size,
                        "source": "Original Garden.Soundscape / Garden.Audio deterministic PCM"})
    output = ROOT / ".runtime/assets-manifest.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(points)} glyphs; pinned font {records[0]['bytes']} bytes; {len(records)} asset records")


if __name__ == "__main__":
    main()
