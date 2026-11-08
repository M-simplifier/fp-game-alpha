"""Materialize the pinned Windows x64 SplitMix package in the ignored build area."""

import argparse
import hashlib
import io
from pathlib import Path
import tarfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "splitmix-0.1.3.2"
URL = f"https://hackage-content.haskell.org/package/{PACKAGE}/{PACKAGE}.tar.gz"
DIGEST = "a61d4e8b30f5a16526d7d31171b674ae7924d2207f378060d13363bd8794de8c"
UPSTREAM = ("LICENSE", "src/System/Random/SplitMix.hs", "src/System/Random/SplitMix32.hs")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Read the exact upstream tarball from a local cache")
    args = parser.parse_args()
    if args.archive:
        data = args.archive.read_bytes()
    else:
        with urlopen(URL, timeout=30) as response:
            data = response.read(1024 * 1024)
    if hashlib.sha256(data).hexdigest() != DIGEST:
        raise SystemExit("SplitMix archive did not match the pinned SHA-256")

    overlay = ROOT / "dependencies" / "splitmix-win64"
    files = {
        "splitmix.cabal": (overlay / "splitmix.cabal").read_bytes(),
        "src/System/Random/SplitMix/Init.hs": (overlay / "Init.hs").read_bytes(),
    }
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for relative in UPSTREAM:
            member = archive.getmember(f"{PACKAGE}/{relative}")
            if not member.isfile():
                raise SystemExit(f"Expected an upstream file at {relative}")
            with archive.extractfile(member) as source:
                files[relative] = source.read()

    output = ROOT / ".runtime" / "gameio-dependencies" / PACKAGE
    for relative, contents in files.items():
        path = output / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_bytes() != contents:
            temporary = path.with_name(path.name + ".next")
            temporary.write_bytes(contents)
            temporary.replace(path)
    print(f"Prepared {output}")


if __name__ == "__main__":
    main()
