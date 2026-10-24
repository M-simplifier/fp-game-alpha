"""Compile real package clients: read/transition/Show work; raw updates fail.

Uses an already built Cabal project, with no source include path or downloads.
The negative clients must fail specifically because the query is not a field.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

GAME = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config-file', type=Path)
    parser.add_argument('--project-file', type=Path, required=True)
    parser.add_argument('--builddir', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    build = args.builddir.resolve()
    output = args.output.resolve() if args.output else build.parent / 'session-api.json'
    cabal = ['cabal'] + ([f'--config-file={args.config_file.resolve()}'] if args.config_file else []) + ['exec',
             f'--project-file={args.project_file.resolve()}', f'--builddir={build}', '--offline', '--']
    rows = []
    with tempfile.TemporaryDirectory(prefix='session-api-', dir=build.parent) as folder:
        temporary = Path(folder)
        for name, field in [('SessionRead', None), ('WorldUpdate', 'simulationWorld'), ('PilotUpdate', 'simulationPilot')]:
            destination = temporary / name
            destination.mkdir()
            command = cabal + ['ghc', '-XGHC2021', '-fforce-recomp', '-i', '-hide-all-packages',
                               '-package=base', '-package=afterlight-arena', '-package=game-arena',
                               '-package=containers', '-outputdir', str(destination)]
            if field:
                command.append('-fno-code')
            else:
                command += ['-o', str(destination / 'session-read')]
            command.append(str(GAME / f'test/api/{name}.hs'))
            compiled = subprocess.run(command, cwd=GAME, capture_output=True, text=True,
                                      encoding='utf-8', errors='replace', timeout=90)
            diagnostics = compiled.stdout + compiled.stderr
            if field:
                passed = compiled.returncode != 0 and field in diagnostics and ('is not a record selector' in diagnostics or 'Not in scope: record field' in diagnostics)
                rows.append(dict(client=name, compile_exit=compiled.returncode, passed=passed,
                                 expected='query is not a record selector', diagnostics=diagnostics))
            else:
                if compiled.returncode:
                    rows.append(dict(client=name, compile_exit=compiled.returncode, passed=False, diagnostics=diagnostics))
                    continue
                executable = destination / ('session-read.exe' if (destination / 'session-read.exe').exists() else 'session-read')
                run = subprocess.run([str(executable)], capture_output=True, timeout=30)
                rows.append(dict(client=name, compile_exit=0, run_exit=run.returncode, passed=run.returncode == 0,
                                 stdout_sha256=hashlib.sha256(run.stdout).hexdigest(),
                                 stdout=run.stdout.decode('utf-8', errors='replace'),
                                 stderr=run.stderr.decode('utf-8', errors='replace')))
    result = dict(schema=1, scope='public Cabal package clients, no src include path', clients=rows,
                  passed=len(rows) == 3 and all(row['passed'] for row in rows))
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    for row in rows:
        print(('PASS ' if row['passed'] else 'FAIL ') + row['client'])
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
