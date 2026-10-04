"""Compile outside clients against River Home's read-only Game boundary."""

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / 'references' / 'river' / 'test'
OUT = ROOT / '.build' / 'river-api'


def compile_fixture(ghc, name):
    output = OUT / name
    output.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [ghc, '-fno-code', '-fforce-recomp', '-XGHC2021',
         '-fdiagnostics-color=never', '-i' + str(ROOT / 'references/river/src'),
         '-outputdir', str(output), str(TEST / (name + '.hs'))],
        cwd=ROOT, capture_output=True, timeout=90)
    diagnostic = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    (OUT / (name + '.log')).write_text(diagnostic, encoding='utf-8')
    return result.returncode, diagnostic


def main():
    ghc = shutil.which('ghc')
    if ghc is None:
        raise RuntimeError('GHC is required; run tools/fp_game.py doctor')
    good_code, _ = compile_fixture(ghc, 'ReadRiver')
    if good_code != 0:
        raise RuntimeError('Public River projections/dependencies did not compile')
    bad_code, diagnostic = compile_fixture(ghc, 'RejectRiverUpdate')
    if bad_code == 0 or 'dayNumber' not in diagnostic or 'is not a record selector' not in diagnostic:
        raise RuntimeError('Game record update was not rejected for the intended reason')
    print('river public API: PASS (projections compile; Game record update rejected)')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'river public API: FAIL: {error}; see ignored .build/river-api logs', file=sys.stderr)
        raise SystemExit(1)
