"""Exercise installed editor processes with an isolated generated project/profile."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from acceptance.native import binary_path, create_game

ROOT = Path(__file__).resolve().parents[1]


def executable(name):
    found = shutil.which(name)
    if not found and name == 'nvim' and platform.system() == 'Windows':
        candidate = Path(os.environ.get('PROGRAMFILES', '')) / 'Neovim/bin/nvim.exe'
        found = str(candidate) if candidate.is_file() else None
    if not found:
        raise ValueError(f'{name} is missing; no editor success is claimed')
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('editor', choices=['neovim', 'vscode'])
    parser.add_argument('--with-hls', action='store_true')
    parser.add_argument('--binary', help='Native fp-game used to create the editor test game')
    parser.add_argument('--windows-compiler', type=Path, default=os.environ.get('FP_GAME_COMPILER'),
                        help='Explicit native compiler profile; inspector still uses separate PATH GHC/GHCi')
    arguments = parser.parse_args()
    compiler = arguments.windows_compiler.absolute() if arguments.windows_compiler else None
    if compiler is not None and (not compiler.is_file() or any(ord(char) < 32 for char in str(compiler))):
        parser.error('The explicitly selected compiler must be an existing file without control characters')
    trial = Path(tempfile.mkdtemp(prefix='FP game editor ')).resolve()
    if not trial.is_relative_to(Path(tempfile.gettempdir()).resolve()):
        raise ValueError('Unexpected test workspace')
    project = trial / 'independent editor game'
    binary = binary_path(arguments.binary)
    create_game('editor-fixture', project, title='Editor fixture', binary=binary)
    if compiler is not None:
        with (project / 'cabal.project.local').open('x', encoding='utf-8', newline='\n') as profile:
            profile.write('with-compiler: ' + compiler.as_posix() + '\n')
    # Test the same project-local native entrypoint shipped by bootstrap. The
    # tested binary is copied, never replaced with a Python product scaffold.
    local_binary = project / '.build/tools' / ('fp-game.exe' if os.name == 'nt' else 'fp-game')
    local_binary.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, local_binary)
    package = project / 'editor-fixture.cabal'
    package.write_text(package.read_text().replace('Game.Save\n', 'Game.Save, EditorProbe\n'), encoding='utf-8')
    environment = os.environ.copy()
    environment.pop('FP_GAME_EDITOR_COMPILER', None)
    if compiler is not None:
        environment['FP_GAME_EDITOR_COMPILER'] = str(compiler)
    environment['XDG_STATE_HOME'] = str(trial / 'private-state')
    if arguments.editor == 'neovim':
        environment['FP_GAME_EDITOR_PROJECT'] = str(project)
        environment['FP_GAME_NVIM_MODULE'] = str(ROOT / 'editors/neovim/fp-game.lua')
        environment['FP_GAME_TEST_HLS'] = '1' if arguments.with_hls else '0'
        command = [executable('nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '-l', str(ROOT / 'editors/neovim/test.lua')]
        result_file = project / 'neovim-test-result.json'
    else:
        if arguments.with_hls:
            raise ValueError('This VSCode contract tests the CLI extension, not the separate Haskell extension/HLS')
        launcher = executable('code')
        command = [launcher, '--new-window', '--wait', '--disable-extensions', '--disable-workspace-trust',
                   '--skip-welcome', '--skip-release-notes', f'--user-data-dir={trial / "profile"}',
                   f'--extensions-dir={trial / "extensions"}', f'--extensionDevelopmentPath={ROOT / "editors/vscode"}',
                   f'--extensionTestsPath={ROOT / "editors/vscode/test"}', str(project)]
        result_file = project / 'vscode-test-result.json'
    startup = None
    if platform.system() == 'Windows':
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
    private_log = ROOT / '.build' / (arguments.editor + '-process.log')
    private_log.parent.mkdir(exist_ok=True)
    try:
        result = subprocess.run(command, cwd=project, env=environment, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=450, startupinfo=startup)
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or b'') + (error.stderr or b'')
        private_log.write_text(json.dumps({'command': command, 'project': str(project), 'status': 'timeout'}) + '\n' + output.decode('utf-8', errors='replace'), encoding='utf-8')
        raise RuntimeError('Editor process timeout; no success claimed. Inspect ' + private_log.name) from error
    private_log.write_text(json.dumps({'command': command, 'project': str(project), 'exit_code': result.returncode}) + '\n' + result.stdout + result.stderr, encoding='utf-8')
    if result.returncode != 0 or not result_file.is_file():
        raise RuntimeError(f'{arguments.editor} contract failed (process exit {result.returncode}, result exists {result_file.exists()}); inspect {private_log.name}')
    report = json.loads(result_file.read_text(encoding='utf-8'))
    if report['status'] != 'pass':
        raise RuntimeError('Editor did not confirm the contract')
    (ROOT / '.build' / (arguments.editor + '-report.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
