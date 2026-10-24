"""Run current laws, frame boundaries and public API rejection checks.

Cabal owns dependency integrity. Default is offline; --download permits
acquisition of the current locked Hackage dependencies.
"""
import argparse
from pathlib import Path
import subprocess
import sys

GAME = Path(__file__).resolve().parents[1]
FOUNDATION = GAME.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', action='store_true')
    args = parser.parse_args()
    build = FOUNDATION / '.build/afterlight-core/dist'
    command = ['cabal', 'test', 'afterlight-arena:laws',
               'afterlight-arena:frame-boundaries', f'--builddir={build}',
               '--test-show-details=direct']
    if not args.download:
        command.append('--offline')
    compiled = subprocess.run(command, cwd=GAME, check=False)
    if compiled.returncode:
        return compiled.returncode
    return subprocess.run([sys.executable, str(GAME / 'scripts/test-session-api.py'),
                           f'--project-file={GAME / "cabal.project"}',
                           f'--builddir={build}'], cwd=GAME, check=False).returncode


if __name__ == '__main__':
    raise SystemExit(main())
