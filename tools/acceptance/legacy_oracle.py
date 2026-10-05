"""Test-only adapter around byte-frozen pre-retirement Python implementations.

This is not distributed to games. Plan comparison gets a disposable source view
because the frozen implementation expects its old product paths. The adapter
never reinstalls those paths in the foundation or modifies the frozen bytes.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FROZEN = Path(__file__).resolve().parent / 'fixtures/python_cli'


def verify():
    manifest = json.loads((FROZEN / 'provenance.json').read_text(encoding='utf-8'))
    for name, digest in manifest['sha256_lf'].items():
        if hashlib.sha256((FROZEN / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest() != digest:
            raise ValueError('Frozen oracle changed: ' + name)


def main():
    verify()
    arguments = sys.argv[1:]
    if arguments and arguments[0] == 'plan':
        with tempfile.TemporaryDirectory(prefix='frozen Python oracle ') as temporary:
            source = Path(temporary).resolve() / 'source'
            source.mkdir()
            for name in ['templates', 'libraries', 'docs', 'editors', '.agents', 'tools']:
                shutil.copytree(ROOT / name, source / name,
                                ignore=shutil.ignore_patterns('.build', 'dist-newstyle', '__pycache__', 'node_modules', 'dist', '.runtime', 'cabal.project.local'))
            shutil.copy2(ROOT / 'LICENSE', source / 'LICENSE')
            for name in ['fp_game.py', 'scaffold.py']:
                shutil.copy2(FROZEN / name, source / 'tools' / name)
            return subprocess.run([sys.executable, str(source / 'tools/fp_game.py'), *arguments]).returncode
    return subprocess.run([sys.executable, str(FROZEN / 'fp_game.py'), *arguments]).returncode


if __name__ == '__main__':
    sys.exit(main())
