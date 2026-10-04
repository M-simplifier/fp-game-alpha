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


def baseline_downloads():
    metadata = ROOT / 'tools/toolchains.json'
    if not metadata.is_file():
        return {}
    architecture = {'amd64': 'x86_64', 'aarch64': 'arm64'}.get(platform.machine().lower(), platform.machine().lower())
    return json.loads(metadata.read_text(encoding='utf-8'))['profiles'].get(platform.system() + '-' + architecture, {})


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
            'editors': {'vscode': shutil.which('code'), 'neovim': shutil.which('nvim')},
            'baseline_downloads': baseline_downloads(),
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
        names = ['libraries/game-transition/src', 'libraries/game-arena/src', 'references/lantern/src', 'src']
    paths = [(project / name).resolve() for name in names]
    if any(not path.is_relative_to(project) for path in paths):
        raise ValueError('Declared source directories must remain inside this project.')
    return [path for path in paths if path.is_dir()]


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
        # GHCi chooses the loaded file's context. Comments are never parsed as
        # module declarations; both the module and imports come from GHCi.
        script = ':show modules\n:show imports\n'
        script += f':info {symbol}\n:type {symbol}\n' if symbol else ':browse\n'
        result = execute([ghci, '-v0', '-ignore-dot-ghci', *flags, str(path)], project,
                         input_text=script + ':quit\n')
        errors = re.search(r'error:|not in scope|unknown command', result['stdout'] + result['stderr'], re.IGNORECASE)
        if errors:
            result['exit_code'] = result['exit_code'] or 1
        loaded = []
        for line in result['stdout'].splitlines():
            found = re.match(r'^([A-Z][\w\']*(?:\.[A-Z][\w\']*)*)\s+\((.+),\s*interpreted\s*\)$', line.strip())
            if found:
                loaded.append({'module': found.group(1), 'source': found.group(2).strip()})
        module = next((item['module'] for item in loaded
                       if (project / item['source']).resolve() == path), None)
        if module is None:
            result['exit_code'] = result['exit_code'] or 1
            result['stderr'] += '\nCould not establish the loaded source module from GHCi.\n'
        imports = re.findall(r'^import\s+.*$', result['stdout'], re.MULTILINE)
        context = re.findall(r'^(?:import\s+|:module\s+).*$', result['stdout'], re.MULTILINE)
        return {'status': 'ok' if result['exit_code'] == 0 else 'query-error',
                'module': module, 'loaded_modules': loaded, 'symbol': symbol, 'imports': imports, 'module_context': context,
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
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ['doctor', 'plan', 'scaffold', 'build', 'test', 'check', 'inspect', 'context', 'run']:
        command = commands.add_parser(name)
        command.add_argument('--project', type=Path, default=ROOT)
        command.add_argument('--json', action='store_true')
        if name in {'check', 'inspect', 'context'}:
            command.add_argument('file', nargs='?' if name == 'check' else None)
        if name in {'inspect', 'context'}:
            command.add_argument('--symbol', required=name == 'context')
        if name in {'plan', 'scaffold'}:
            command.add_argument('name')
            command.add_argument('destination', type=Path)
            command.add_argument('--title')
            command.add_argument('--target', choices=['native', 'web', 'server', 'mobile'], default='native')
            command.add_argument('--rendering', choices=['terminal', '2d', '3d', 'miso'], default='terminal')
            command.add_argument('--license', choices=['unlicensed', 'MIT'], default='unlicensed')
            command.add_argument('--author')
        if name == 'scaffold':
            command.add_argument('--dry-run', action='store_true')
        if name == 'run':
            command.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    project = args.project.resolve()
    try:
        if not project.is_dir():
            raise ValueError('Project directory does not exist.')
        if args.action == 'doctor':
            result = doctor(project)
        elif args.action in {'plan', 'scaffold'}:
            import scaffold
            result = scaffold.plan(args) if args.action == 'plan' else scaffold.scaffold(args)
        elif args.action == 'run':
            config = json.loads((project / 'fp-game.json').read_text(encoding='utf-8'))
            command = cabal_command(project, 'run', [config['default_executable']])
            if args.smoke:
                result = execute([*command, '--', '--smoke'], project)
            elif args.json:
                raise ValueError('Interactive run uses the terminal; use --smoke for captured JSON.')
            else:
                completed = subprocess.run(command, cwd=project)
                result = {'exit_code': completed.returncode, 'stdout': '', 'stderr': ''}
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
    if args.json or args.action in {'doctor', 'plan', 'scaffold'}:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(result.get('stdout', ''), end='')
        print(result.get('stderr', ''), end='', file=sys.stderr)
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
