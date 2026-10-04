"""Editor-independent alpha entrypoint. Requires only Python's standard library."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = {'ghc': '9.6.7', 'cabal': '3.12.1.0'}


def execute(command, project, timeout=180, input_text=None):
    try:
        result = subprocess.run(command, cwd=project, input=input_text, text=True,
                                encoding='utf-8', errors='replace', capture_output=True, timeout=timeout)
        return {'command': command, 'exit_code': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': command, 'exit_code': 1, 'stdout': '', 'stderr': str(error)}


def doctor(project):
    tools = {}
    for name, flag in [('ghc', '--numeric-version'), ('cabal', '--numeric-version')]:
        executable = shutil.which(name)
        probe = execute([executable, flag], project, timeout=20) if executable else None
        version = probe['stdout'].strip() if probe and probe['exit_code'] == 0 else None
        tools[name] = {'path': executable, 'version': version,
                       'tested_version': BASELINE[name], 'matches_baseline': version == BASELINE[name]}
    missing = [name for name, value in tools.items() if not value['version']]
    return {'status': 'missing-tools' if missing else 'ready-to-try', 'exit_code': 1 if missing else 0,
            'os': platform.system(), 'architecture': platform.machine(), 'python': platform.python_version(),
            'tools': tools, 'optional_hls': shutil.which('haskell-language-server-wrapper'),
            'missing': missing, 'setup': 'https://www.haskell.org/ghcup/install/',
            'scope': 'Detects tools; build/test establishes this project. Tool installation remains explicit.'}


def cabal_command(project, action, targets):
    """Avoid global settings and Cabal's initial secure-repository bootstrap."""
    state = project / '.build'
    state.mkdir(exist_ok=True)
    config = state / 'cabal.config'
    config.write_text('active-repositories: :none\nstore-dir: ' + (state / 'store').as_posix()
                      + '\nremote-repo-cache: ' + (state / 'package-cache').as_posix() + '\n', encoding='utf-8', newline='\n')
    executable = shutil.which('cabal')
    if not executable:
        raise ValueError('Cabal is missing. Run doctor and follow docs/setup.md.')
    return [executable, f'--config-file={config}', action, *targets,
            '--offline', f'--builddir={state / "dist"}']


def source_dirs(project):
    config = project / 'fp-game.json'
    if config.exists():
        names = json.loads(config.read_text(encoding='utf-8'))['source_dirs']
    else:
        names = ['libraries/game-transition/src', 'libraries/game-arena/src', 'src']
    return [project / name for name in names if (project / name).is_dir()]


def compiler_args(project, output):
    return ['-XGHC2021', '-Wall', '-fdiagnostics-color=never', '-outputdir', str(output),
            *['-i' + str(path) for path in source_dirs(project)]]


def checked_source(project, filename):
    path = (project / filename).resolve()
    if not path.is_relative_to(project) or not path.is_file() or path.suffix != '.hs':
        raise ValueError('Choose an existing .hs source inside the selected project.')
    return path


def query(project, filename, symbol=None):
    path = checked_source(project, filename)
    if symbol and not re.fullmatch(r'(?:[A-Z][\w\']*\.)*[a-zA-Z_][\w\']*', symbol):
        raise ValueError('Symbol must be a Haskell identifier, optionally module-qualified.')
    ghc, ghci = shutil.which('ghc'), shutil.which('ghci')
    if not ghc or not ghci:
        raise ValueError('GHC and GHCi are required. Run doctor.')
    state = project / '.build'
    state.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='inspect-', dir=state) as temporary:
        flags = compiler_args(project, Path(temporary))
        check = execute([ghc, '-fno-code', '-fforce-recomp', *flags, str(path)], project)
        if check['exit_code'] != 0:
            return {'status': 'compiler-error', **check}
        source = path.read_text(encoding='utf-8-sig')
        found = re.search(r'\bmodule\s+([A-Z][\w\']*(?:\.[A-Z][\w\']*)*)', source)
        module = found.group(1) if found else 'Main'
        script = f':info {symbol}\n:type {symbol}\n' if symbol else f':browse {module}\n'
        result = execute([ghci, '-v0', '-ignore-dot-ghci', *flags, str(path)], project,
                         input_text=script + ':quit\n')
        errors = re.search(r'error:|not in scope|unknown command', result['stdout'] + result['stderr'], re.IGNORECASE)
        if errors or not result['stdout'].strip():
            result['exit_code'] = result['exit_code'] or 1
        imports = re.findall(r'^import\s+.*$', source, re.MULTILINE)
        return {'status': 'ok' if result['exit_code'] == 0 else 'query-error',
                'module': module, 'symbol': symbol, 'imports': imports,
                'scope': 'GHC/GHCi on saved source and declared local source directories; no HLS session', **result}


def check_file(project, filename):
    path = checked_source(project, filename)
    executable = shutil.which('ghc')
    if not executable:
        raise ValueError('GHC is missing. Run doctor.')
    state = project / '.build'
    state.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='check-', dir=state) as temporary:
        return execute([executable, '-fno-code', '-fforce-recomp', *compiler_args(project, Path(temporary)), str(path)], project)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ['doctor', 'build', 'test', 'check', 'inspect', 'context']:
        command = commands.add_parser(name)
        command.add_argument('--project', type=Path, default=ROOT)
        command.add_argument('--json', action='store_true')
        if name in {'check', 'inspect', 'context'}:
            command.add_argument('file', nargs='?' if name == 'check' else None)
        if name in {'inspect', 'context'}:
            command.add_argument('--symbol', required=name == 'context')
    args = parser.parse_args()
    project = args.project.resolve()
    try:
        if not project.is_dir():
            raise ValueError('Project directory does not exist.')
        if args.action == 'doctor':
            result = doctor(project)
        elif args.action in {'build', 'test'}:
            command = cabal_command(project, args.action, ['all'])
            if args.action == 'test':
                command.append('--test-show-details=direct')
            result = execute(command, project)
        elif args.action == 'check':
            result = check_file(project, args.file) if args.file else execute(cabal_command(project, 'build', ['all']), project)
        else:
            result = query(project, args.file, args.symbol)
    except (OSError, ValueError, KeyError) as error:
        result = {'status': 'error', 'exit_code': 1, 'stdout': '', 'stderr': str(error)}
    if args.json or args.action == 'doctor':
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(result.get('stdout', ''), end='')
        print(result.get('stderr', ''), end='', file=sys.stderr)
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
