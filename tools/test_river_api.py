"""Compile outside clients against River Home's actual Cabal package boundary."""

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / 'references' / 'river' / 'test'
OUT = ROOT / '.build' / 'river-api'
BUILD = ROOT / '.build' / 'dist'
CONFIG = ROOT / 'templates' / 'terminal-adventure' / 'build.config'


def run_logged(command, name):
    OUT.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=180)
    diagnostic = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    (OUT / (name + '.log')).write_text(diagnostic, encoding='utf-8')
    return result.returncode, diagnostic


def compile_fixture(cabal, ghc, name):
    output = OUT / name
    output.mkdir(parents=True, exist_ok=True)
    return run_logged(
        [cabal, '--config-file=' + str(CONFIG), 'exec', '--builddir=' + str(BUILD),
         '--', ghc, '-package', 'river-home-reference', '-fno-code',
         '-fforce-recomp', '-XGHC2021', '-fdiagnostics-color=never', '-i',
         '-outputdir', str(output), str(TEST / (name + '.hs'))], name)


def main():
    ghc = shutil.which('ghc')
    cabal = shutil.which('cabal')
    if ghc is None or cabal is None:
        raise RuntimeError('GHC and Cabal must be on PATH; see docs/setup.md.')
    build_code, _ = run_logged(
        [cabal, '--config-file=' + str(CONFIG), 'build', 'lib:river-home-reference',
         '--offline', '--builddir=' + str(BUILD), '-j1'], 'build-library')
    if build_code != 0:
        raise RuntimeError('River library did not build with its offline profile')
    good_code, _ = compile_fixture(cabal, ghc, 'ReadRiver')
    if good_code != 0:
        raise RuntimeError('Public River projections/dependencies did not compile')
    rejected = [
        ('RejectRiverUpdate', ('dayNumber', 'is not a record selector')),
        ('RejectRiverPrivateField', ('gDay', 'Not in scope')),
        ('RejectRiverConstructor', ('Game', 'Illegal term-level use of the type constructor')),
        ('RejectRiverRead', ('Read Game', 'No instance for')),
        ('RejectRiverInternal', ('Life.Internal.Core', 'hidden module')),
    ]
    for name, expected in rejected:
        code, diagnostic = compile_fixture(cabal, ghc, name)
        if code == 0 or not all(fragment in diagnostic for fragment in expected):
            raise RuntimeError(name + ' was not rejected for the intended reason')
    print('river public API: PASS (package reads compile; update/constructor/Read/internal access rejected)')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'river public API: FAIL: {error}; see ignored .build/river-api logs', file=sys.stderr)
        raise SystemExit(1)
