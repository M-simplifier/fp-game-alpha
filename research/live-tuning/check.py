#!/usr/bin/env python3
"""Check the actual bounded host; these are correctness checks, not timings."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, **kwargs):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=30, **kwargs)
    require(result.returncode == 0, result.stdout)
    return result.stdout


def verify_host_log(log):
    lines = log.splitlines()
    require('[.@....G] PLAYING | moves=7 session=r0/8 staged=r1/5' in lines,
            'Staging must preserve the active session budget')
    require('[@.....G] PLAYING | moves=8 session=r0/8 staged=r1/5' in lines,
            'Restart must retain the active session rules')
    rejects = [i for i, line in enumerate(lines) if line.startswith('REJECTED:')]
    require(len(rejects) == 7, 'Expected seven rejected rule loads')
    unchanged = '[.....@G] OUT OF MOVES | moves=0 session=r1/5 staged=r1/5'
    require(all(i + 1 < len(lines) and lines[i + 1] == unchanged for i in rejects),
            'Rejected rule loads must preserve the session and staged rules')
    terminal = '[......@] WON | moves=0 session=r2/6 staged=r2/6'
    require(len(lines) >= 2 and lines[-1] == lines[-2] == terminal,
            'Recovery must win on the final move and retain the terminal state')


def main():
    ghc = os.environ.get('GHC', 'ghc')
    (ROOT / '.build').mkdir(exist_ok=True)
    suffix = '.exe' if os.name == 'nt' else ''
    tests = ROOT / '.build' / ('tests-bin' + suffix)
    game = ROOT / '.build' / ('game' + suffix)
    for source, directory, binary in [('Tests.hs', 'tests', 'tests-bin'),
                                       ('Main.hs', 'app', 'game')]:
        print(run([ghc, '-O0', '-Wall', '-Werror', '-outputdir', f'.build/{directory}',
                   source, '-o', str(ROOT / '.build' / (binary + suffix))]), end='')
    # Windows resolves an executable before applying the child cwd. Resolve
    # these paths ourselves so the root-level CI invocation works there too.
    print(run([str(tests)]), end='')
    with tempfile.TemporaryDirectory(prefix='host-check-', dir=ROOT) as temporary:
        folder = Path(temporary)
        # The prototype's input grammar is `load FILE` with one whitespace-free
        # token. Only its private fixture basename must enter that protocol.
        relative = folder.relative_to(ROOT)
        fixtures = [
            ('valid', 'revision 1 moveBudget 5'),
            ('invalid', 'revision 2 moveBudget 99'),
            ('partial', 'revision 2'),
            ('huge', '9' * 10000),
            ('overflow', 'revision 2 moveBudget 18446744073709551622'),
            ('negative-overflow', 'revision 2 moveBudget -18446744073709551610'),
            ('win', 'revision 2 moveBudget 6'),
        ]
        for name, data in fixtures:
            (folder / name).write_text(data)
        commands = ['r', f'load {relative}/valid', 'restart', 'new', *(['r'] * 5)]
        for name in ['invalid', 'partial', 'huge', 'missing', 'valid',
                     'overflow', 'negative-overflow']:
            commands.append(f'load {relative}/{name}')
        commands += [f'load {relative}/win', 'new', *(['r'] * 6), 'r', 'quit']
        log = run([str(game)], input='\n'.join(commands) + '\n')
        verify_host_log(log)
        (ROOT / '.build/host-check.log').write_text(log)
    print('PASS: real CLI host admission, restart/new, 7 failures retain state, '
          'recovery after failure, final-move win, repeated terminal input')


if __name__ == '__main__':
    main()
