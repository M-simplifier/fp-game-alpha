"""Inspect saved Haskell source with PATH GHC/GHCi; optional specialist tooling.

Core doctor/build/test/check/run and creation belong to the native fp-game CLI.
This helper does not implement or fall back to those operational commands.
It does not yet use Cabal-selected compilers, dependencies or an HLS session.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def execute(command, project, timeout=180, input_text=None):
    try:
        result = subprocess.run(command, cwd=project, input=input_text, text=True,
                                encoding='utf-8', errors='replace', capture_output=True, timeout=timeout)
        return {'command': command, 'exit_code': result.returncode,
                'stdout': result.stdout, 'stderr': result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {'command': command, 'exit_code': 1, 'stdout': '', 'stderr': str(error)}



def source_dirs(project):
    config = project / 'fp-game.json'
    if config.exists():
        names = json.loads(config.read_text(encoding='utf-8'))['source_dirs']
    else:
        names = ['libraries/game-transition/src', 'libraries/game-arena/src',
                 'references/lantern/src', 'references/garden/src',
                 'references/tapline/src', 'references/river/src',
                 'references/station/src', 'src']
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
        raise ValueError('GHC and GHCi are required. Use the native fp-game doctor for core tooling; inspection separately needs GHC and GHCi on PATH.')
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



def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ['inspect', 'context']:
        command = commands.add_parser(name)
        command.add_argument('--project', type=Path, default=ROOT)
        command.add_argument('--json', action='store_true')
        command.add_argument('file')
        command.add_argument('--symbol', required=name == 'context')
    args = parser.parse_args()
    try:
        project = args.project.resolve()
        if not project.is_dir():
            raise ValueError('Project directory does not exist.')
        result = query(project, args.file, args.symbol)
    except (OSError, ValueError, KeyError) as error:
        result = {'status': 'error', 'exit_code': 1, 'stdout': '', 'stderr': str(error)}
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(result.get('stdout', ''), end='')
        print(result.get('stderr', ''), end='', file=sys.stderr)
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
