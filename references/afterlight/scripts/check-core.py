"""Check the complete pure core and original parity oracle with pinned inputs.

Default is offline. --download explicitly fetches only five hash-pinned Hackage
source archives into this checkout's ignored build directory. No global config,
compiler installation, graphical host, or browser verification is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

GAME = Path(__file__).resolve().parents[1]
FOUNDATION = GAME.parents[1]
DEPENDENCIES = [
    ('Yampa', '0.15', '985d7a3fe2df6f189bc114a024e2616ad8774855eaed400014af58104f7bac37'),
    ('random', '1.2.1.3', 'e9c81926a7d1e40328f645f73592b31efc9c631589669a7f130687b9cc3051dc'),
    ('splitmix', '0.1.3.2', 'a61d4e8b30f5a16526d7d31171b674ae7924d2207f378060d13363bd8794de8c'),
    ('simple-affine-space', '0.2.1', '5de5b6a0243570356adb3a630218f09885517298941b7869b5cfabccf224d6e6'),
    ('QuickCheck', '2.15.0.1', 'a3b2216ddbaf481dbc82414b6120f8b726d969db3f0b51f20a7a45425ef36e7f'),
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true')
    parser.add_argument('--archives', type=Path, help='Directory containing the five pinned .tar.gz files')
    args = parser.parse_args()
    for tool in ('ghc', 'ghc-pkg', 'cabal'):
        if not shutil.which(tool):
            parser.error(f'Missing {tool}; activate an existing Haskell toolchain first')
    build = FOUNDATION / '.build/afterlight-core'
    archives = args.archives.resolve() if args.archives else build / 'archives'
    archives.mkdir(parents=True, exist_ok=True)
    sources = build / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    inputs = []
    for name, version, expected in DEPENDENCIES:
        package = f'{name}-{version}'
        archive = archives / (package + '.tar.gz')
        if not archive.exists():
            if not args.download:
                parser.error(f'Missing {archive.name}; supply --archives or explicitly use --download')
            url = f'https://hackage.haskell.org/package/{package}/{package}.tar.gz'
            temporary = archive.with_suffix('.download')
            with urllib.request.urlopen(url, timeout=90) as response:
                temporary.write_bytes(response.read())
            if sha(temporary) != expected:
                parser.error(f'Hash mismatch for downloaded {archive.name}; not extracted')
            temporary.replace(archive)
        if sha(archive) != expected:
            parser.error(f'Hash mismatch for {archive.name}; not extracted')
        # Treat extraction caches as untrusted inputs, not proof of pinned bytes.
        target = sources / package
        if sources.is_symlink() or target.is_symlink():
            parser.error(f'Linked extraction directory for {package}')
        if target.exists():
            for cached in target.rglob('*'):
                if cached.is_symlink() or (cached.is_file() and cached.stat().st_nlink > 1):
                    parser.error(f'Linked cached source in {package}; use a fresh build cache')
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            if any(Path(m.name).parts[0] != package or m.issym() or m.islnk() for m in members):
                parser.error(f'Unexpected package layout or link in {archive.name}')
            expected_files = {m.name.rstrip('/') for m in members if m.isfile()}
            bundle.extractall(sources, filter='data')
            actual_files = {p.relative_to(sources).as_posix() for p in (sources / package).rglob('*') if p.is_file()}
            if actual_files != expected_files:
                parser.error(f'Unexpected files in extracted {package}; use a fresh build cache')
            for member in members:
                if member.isfile():
                    extracted = sources / member.name
                    if extracted.is_symlink() or extracted.stat().st_nlink > 1:
                        parser.error(f'Linked extracted file in {package}')
                    expected_bytes = bundle.extractfile(member).read()
                    if extracted.read_bytes() != expected_bytes:
                        parser.error(f'Extracted content mismatch in {package}')
        inputs.append({'package': package, 'archive_sha256': expected})
    packages = [GAME, FOUNDATION / 'libraries/game-transition', FOUNDATION / 'libraries/game-arena']
    packages += [sources / f'{n}-{v}' for n, v, _ in DEPENDENCIES]
    project = build / 'core.project'
    project.write_text('packages: ' + '\n          '.join(json.dumps(p.as_posix()) for p in packages)
                       + '\nactive-repositories: :none\ntests: False\npackage afterlight-arena\n  tests: True\n  flags: -native -web\n', encoding='utf-8')
    config = build / 'cabal.config'
    config.write_text('active-repositories: :none\nstore-dir: ' + (build / 'store').as_posix()
                      + '\nremote-repo-cache: ' + (build / 'package-cache').as_posix() + '\n', encoding='utf-8')
    versions = {name: subprocess.check_output([name, '--numeric-version'], text=True).strip()
                for name in ('ghc', 'cabal')}
    command = ['cabal', f'--config-file={config}', 'test', 'afterlight-arena:original-checks',
               'afterlight-arena:parity', f'--project-file={project}', f'--builddir={build / "dist"}', '--offline']
    result = subprocess.run(command, cwd=FOUNDATION, check=False)
    report = {'schema': 1, 'versions': versions, 'dependencies': inputs,
              'exit_code': result.returncode, 'scope': 'complete pure core, original checks and parity oracle',
              'native_graphics': 'not_run', 'browser': 'not_run'}
    (build / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(result.returncode)

if __name__ == '__main__':
    main()
