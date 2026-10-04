"""Compare the same River consumer against a public baseline and current sources.

Requires the repository's existing GHC and Git. Builds only the five imported
modules and the probe, using a temporary directory under ignored .build/.
The baseline supplies the expected bytes; no new golden expectations are made.
"""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / 'research/readability/RiverProbe.hs'
SOURCES = [
    'references/river/src/Life/Domain.hs',
    'references/river/src/Life/Clock.hs',
    'references/river/src/Life/Adapter.hs',
    'libraries/game-transition/src/Game/Transition.hs',
    'libraries/game-arena/src/Game/Arena.hs',
]
SOURCE_ROOTS = [
    'references/river/src', 'libraries/game-transition/src',
    'libraries/game-arena/src',
]


def run(command, **kwargs):
    result = subprocess.run(command, cwd=ROOT, capture_output=True,
                            timeout=120, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace'))
    return result.stdout


def compile_probe(ghc, sources, output):
    output.mkdir()
    binary = output / ('probe.exe' if sys.platform == 'win32' else 'probe')
    run([ghc, '-XGHC2021', '-Wall', '-Wcompat', '-Werror', '-O0',
         '-fforce-recomp', '-fdiagnostics-color=never',
         *['-i' + str(sources / path) for path in SOURCE_ROOTS],
         '-outputdir', str(output), '-o', str(binary), str(PROBE)])
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', help='public Git commit/ref; history is never changed')
    args = parser.parse_args()
    ghc = shutil.which('ghc')
    if not ghc:
        raise RuntimeError('GHC is required; use the repository toolchain')
    baseline = run(['git', 'rev-parse', '--verify', args.baseline + '^{commit}']).decode().strip()
    state = ROOT / '.build/river-readability'
    state.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=state) as temporary:
        work = Path(temporary)
        original = work / 'baseline'
        for name in SOURCES:
            path = original / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(run(['git', 'show', baseline + ':' + name]))
        before = run([str(compile_probe(ghc, original, work / 'before'))])
        after = run([str(compile_probe(ghc, ROOT, work / 'after'))])
    if before != after:
        old_lines, new_lines = before.splitlines(), after.splitlines()
        for index in range(max(len(old_lines), len(new_lines))):
            old = old_lines[index] if index < len(old_lines) else b'<missing>'
            new = new_lines[index] if index < len(new_lines) else b'<missing>'
            if old != new:
                # Values are public probe outputs; limit an oversized save diagnostic.
                raise RuntimeError(f'first differing observation {index + 1}:\n'
                                   f'baseline: {old[:1000]!r}\ncurrent: {new[:1000]!r}')
    lines = before.splitlines()
    coverage = next(line for line in lines if line.startswith(b'coverage\t')).decode()
    print(f'River comparison: PASS ({len(lines)} byte-identical observations; '
          f'{len(before)} bytes; sha256 {hashlib.sha256(before).hexdigest()})')
    print('baseline ' + baseline)
    print(coverage)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print('River comparison: FAIL: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
