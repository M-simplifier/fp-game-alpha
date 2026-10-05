"""Compile outside clients against Station's public construction boundary."""

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / 'references' / 'station' / 'test'
OUT = ROOT / '.build' / 'station-api'


def compile_fixture(ghc, name):
    output = OUT / name
    output.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [ghc, '-fno-code', '-fforce-recomp', '-XGHC2021',
         '-fdiagnostics-color=never', '-i' + str(ROOT / 'references/station/src'),
         '-outputdir', str(output), str(TEST / (name + '.hs'))],
        cwd=ROOT, capture_output=True, timeout=90)
    diagnostic = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    (OUT / (name + '.log')).write_text(diagnostic, encoding='utf-8')
    return result.returncode, diagnostic


def main():
    ghc = shutil.which('ghc')
    if ghc is None:
        raise RuntimeError('GHC must be on PATH for this separate helper; see docs/setup.md.')
    good_code, _ = compile_fixture(ghc, 'ReadGame')
    if good_code != 0:
        raise RuntimeError('Public Station projection/dependencies did not compile')
    bad_code, diagnostic = compile_fixture(ghc, 'RejectGameUpdate')
    if bad_code == 0 or 'stats' not in diagnostic or 'is not a record selector' not in diagnostic:
        raise RuntimeError('GameState record update was not rejected for the intended reason')
    bad_code, diagnostic = compile_fixture(ghc, 'RejectTurnId')
    if bad_code == 0 or 'TurnId' not in diagnostic or 'Illegal term-level use of the type constructor' not in diagnostic:
        raise RuntimeError('TurnId forgery was not rejected for the intended reason')
    print('station public API: PASS (projection compiles; state update and token forgery rejected)')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'station public API: FAIL: {error}; see ignored .build/station-api logs', file=sys.stderr)
        raise SystemExit(1)
