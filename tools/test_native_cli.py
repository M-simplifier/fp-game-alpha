"""Independent native CLI acceptance, using real GHC/Cabal and editable games.

Python is the test driver and legacy contract oracle, never the native runtime.
All games live outside the checkout. Raw logs remain local under .build/.
The public summary contains outcomes and hashes, not machine-specific paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from acceptance.features import add_key, add_stamina
from test_native_terminal import terminal_checks

ROOT = Path(__file__).resolve().parents[1]
RECORDS = []
LOGS = ROOT / '.build/native-cli-logs'
ENVIRONMENT = {'os': platform.system(), 'architecture': platform.machine()}


def source_hashes():
    inputs = set()
    for name in ['tools/haskell', 'templates/terminal-adventure',
                 'libraries/game-transition', 'libraries/game-arena']:
        for path in (ROOT / name).rglob('*'):
            if path.is_file() and not any(part in {'.build', 'dist-newstyle', '__pycache__', 'cabal.project.local'}
                                          for part in path.relative_to(ROOT).parts):
                inputs.add(path)
    for name in ['tools/bootstrap-fp-game.sh', 'tools/bootstrap-fp-game.ps1',
                 'tools/test_native_cli.py', 'tools/test_native_terminal.py',
                 'tools/test_windows_toolchain_paths.py',
                 'tools/acceptance/features.py', 'tools/inspect_haskell.py',
                 'tools/acceptance/legacy_oracle.py', 'tools/acceptance/fixtures/python_cli/fp_game.py',
                 'tools/acceptance/fixtures/python_cli/scaffold.py', 'tools/acceptance/fixtures/python_cli/provenance.json',
                 'tools/toolchains.json', 'tools/formatter.py', 'tools/formatter.lock.json',
                 'docs/native-tooling.md', 'docs/failure-prevention.md',
                 '.github/workflows/native-tooling.yml', 'formatter.json']:
        inputs.add(ROOT / name)
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(
            path.read_bytes().replace(b'\r\n', b'\n')).hexdigest() for path in sorted(inputs)}


def require(label, condition, detail=''):
    RECORDS.append({'check': label, 'status': 'pass' if condition else 'fail'})
    if not condition:
        raise AssertionError(label + (': ' + detail if detail else ''))


def run(label, command, cwd, expected=0, *, env=None, input_text=None, json_result=True):
    print(label, flush=True)
    start = time.monotonic()
    process = subprocess.run([str(value) for value in command], cwd=cwd, env=env,
                             input=input_text, capture_output=True, text=True,
                             encoding='utf-8', errors='replace', timeout=300)
    LOGS.mkdir(parents=True, exist_ok=True)
    (LOGS / (label + '.json')).write_text(json.dumps({
        'command': [str(value) for value in command], 'exit_code': process.returncode,
        'stdout': process.stdout, 'stderr': process.stderr}, ensure_ascii=False, indent=2), encoding='utf-8')
    RECORDS.append({'check': label, 'exit_code': process.returncode,
                    'expected_exit_code': expected,
                    'seconds': round(time.monotonic() - start, 3),
                    'stdout_sha256': hashlib.sha256(process.stdout.encode()).hexdigest()})
    if expected is not None and process.returncode != expected:
        raise AssertionError(f'{label}: exit {process.returncode}, expected {expected}; inspect local native-cli-logs\n'
                             + process.stdout[-3000:] + process.stderr[-3000:])
    if not json_result:
        return process
    require(label + '-stdout-is-one-json-value', bool(process.stdout.strip()))
    result = json.loads(process.stdout)
    require(label + '-json-exit-agrees', result.get('exit_code') == process.returncode)
    require(label + '-no-protocol-noise-on-stderr', not process.stderr.strip(), process.stderr)
    return result


def cli(binary, label, action, project, *options, expected=0, cwd=None, env=None):
    return run(label, [binary, action, *options, '--project', project, '--json'],
               cwd or project, expected, env=env)


def executed(label, result):
    require(label + '-execution-schema', set(result) == {'command', 'exit_code', 'stdout', 'stderr'})
    require(label + '-argument-array', isinstance(result['command'], list)
            and all(isinstance(value, str) for value in result['command']))
    require(label + '-output-is-text', isinstance(result['stdout'], str) and isinstance(result['stderr'], str))


def error(label, result):
    require(label + '-typed-refusal', result.get('status') == 'error'
            and result.get('exit_code') == 1 and result.get('stdout') == ''
            and isinstance(result.get('error_code'), str) and bool(result['error_code'])
            and bool(result.get('stderr')))


def bootstrap(project, label, compiler=None):
    if os.name == 'nt':
        shell = shutil.which('pwsh') or shutil.which('powershell')
        require(label + '-powershell-present', shell is not None)
        command = [shell, '-NoProfile', '-File', project / 'tools/bootstrap-fp-game.ps1']
        if compiler is not None:
            command += ['-CompilerPath', compiler]
    else:
        command = [shutil.which('sh'), project / 'tools/bootstrap-fp-game.sh']
    run(label, command, project.parent, json_result=False)
    binary = project / '.build/tools' / ('fp-game.exe' if os.name == 'nt' else 'fp-game')
    require(label + '-executable-created', binary.is_file())
    return binary


def powershell_duplicate_path_check(project, trial):
    """Exercise the real PowerShell script, not a source-text substitute."""
    if os.name != 'nt':
        RECORDS.append({'check': 'powershell-duplicate-path-regression', 'status': 'not-applicable',
                        'reason': 'Windows application/PATH-separator contract'})
        return
    shell = shutil.which('pwsh') or shutil.which('powershell')
    require('windows-bootstrap-has-powershell', shell is not None)
    aliases = []
    for tool in ['ghc', 'cabal']:
        executable = shutil.which(tool)
        require('duplicate-path-' + tool + '-present', executable is not None)
        folder = Path(executable).parent
        # The actual Windows CI failure included both separator spellings.
        aliases.extend([folder.as_posix(), str(folder).replace('/', '\\')])
    environment = dict(os.environ, PATH=os.pathsep.join([*aliases, os.environ.get('PATH', '')]))
    probe = run('powershell-duplicate-application-probe', [shell, '-NoProfile', '-NonInteractive',
        '-Command', "@{ghc=@(Get-Command ghc -CommandType Application -ErrorAction Stop).Count; "
        "cabal=@(Get-Command cabal -CommandType Application -ErrorAction Stop).Count} | ConvertTo-Json -Compress"],
        trial, env=environment, json_result=False)
    matches = json.loads(probe.stdout)
    require('powershell-fixture-really-has-multiple-applications',
            matches['ghc'] >= 2 and matches['cabal'] >= 2, json.dumps(matches))
    checked = run('powershell-check-with-duplicate-paths', [shell, '-NoProfile', '-NonInteractive',
                  '-File', project / 'tools/bootstrap-fp-game.ps1', '-Check'], trial,
                  env=environment, json_result=False)
    require('powershell-duplicate-path-reports-both-tools',
            'ghc:' in checked.stderr and 'cabal:' in checked.stderr)
    require('powershell-duplicate-path-check-does-not-build', not (project / '.build').exists())


def bootstrap_refusals(trial, compiler=None):
    project = trial / 'bootstrap refusal 日本語'
    (project / 'tools/haskell').mkdir(parents=True)
    (project / 'tools/haskell/cabal.project').write_text('packages: .\n', encoding='utf-8')
    for name in ['bootstrap-fp-game.sh', 'bootstrap-fp-game.ps1']:
        shutil.copy2(ROOT / 'tools' / name, project / 'tools' / name)
    if os.name == 'nt':
        shell = shutil.which('pwsh') or shutil.which('powershell')
        command = [shell, '-NoProfile', '-File', project / 'tools/bootstrap-fp-game.ps1']
    else:
        command = [shutil.which('sh'), project / 'tools/bootstrap-fp-game.sh']
    check_option = '-Check' if os.name == 'nt' else '--check'
    run('bootstrap-tool-check', [*command, check_option], trial, json_result=False)
    missing = run('bootstrap-before-ghc-exists', [*command, check_option], trial, expected=1,
                  env=dict(os.environ, PATH=str(trial / 'no-tools')), json_result=False)
    require('bootstrap-missing-tool-diagnostic', 'ghc' in missing.stderr.lower()
            and 'cabal' in missing.stderr.lower() and 'ghcup/install' in missing.stderr)
    require('bootstrap-check-creates-no-output', not (project / '.build').exists())
    powershell_duplicate_path_check(project, trial)
    if os.name == 'nt' and compiler is not None:
        selected = run('bootstrap-explicit-compiler-check', [*command, '-Check', '-CompilerPath', compiler],
                       trial, json_result=False)
        require('bootstrap-reports-explicit-compiler', str(compiler) in selected.stderr)
        local_profile = project / 'tools/haskell/cabal.project.local'
        local_profile.write_text('-- user-owned settings must be preserved\n', encoding='utf-8')
        profile_before = local_profile.read_bytes()
        # Resolve from the selected compiler's own directory: valid even when
        # the temporary project and compiler live on different Windows volumes.
        run('bootstrap-relative-compiler-check', [*command, '-Check', '-CompilerPath',
            './' + compiler.name], compiler.parent, json_result=False)
        require('bootstrap-preserves-existing-profile', local_profile.read_bytes() == profile_before)
        run('bootstrap-missing-explicit-compiler', [*command, '-Check', '-CompilerPath',
            trial / 'missing-ghc.exe'], trial, expected=1, json_result=False)
        run('bootstrap-directory-as-compiler', [*command, '-Check', '-CompilerPath', trial],
            trial, expected=1, json_result=False)
        require('explicit-bootstrap-check-does-not-build', not (project / '.build').exists())
    leaf = project / '.build/tools' / ('fp-game.exe' if os.name == 'nt' else 'fp-game')
    leaf.mkdir(parents=True)
    sentinel = leaf / 'sentinel'
    sentinel.write_text('preserve', encoding='utf-8')
    run('bootstrap-refuses-directory-leaf', command, trial, expected=1, json_result=False)
    require('bootstrap-directory-preserved', list(leaf.iterdir()) == [sentinel])
    shutil.rmtree(leaf)
    outside = trial / 'outside bootstrap target'
    outside.mkdir()
    if symlink_or_record(leaf, outside, directory=True):
        run('bootstrap-refuses-linked-leaf', command, trial, expected=1, json_result=False)
        require('bootstrap-outside-target-untouched', not list(outside.iterdir()))
        leaf.unlink()


def source_snapshot(destination):
    """A source-only foundation, without ambient repository or build products."""
    for name in ['libraries', 'templates', 'docs', 'tools', '.agents', 'editors']:
        shutil.copytree(ROOT / name, destination / name,
                        ignore=shutil.ignore_patterns('.build', 'dist-newstyle', '__pycache__',
                                                     'node_modules', 'dist', 'vendor', '.runtime',
                                                     '*.hi', '*.o', '*.exe', 'cabal.project.local'))
    shutil.copy2(ROOT / 'LICENSE', destination / 'LICENSE')
    # A genuine boot-package-only project for Cabal's authoritative path query.
    # The root checkout project references examples deliberately absent here.
    (destination / 'cabal.project').write_text(
        'packages: libraries/game-transition libraries/game-arena\n', encoding='utf-8')


def symlink_or_record(link, target, directory=False):
    try:
        link.symlink_to(target, target_is_directory=directory)
        return True
    except OSError as failure:
        if os.name != 'nt':
            raise
        RECORDS.append({'check': 'windows-symlink-privilege', 'status': 'unavailable',
                        'reason': type(failure).__name__})
        return False


def slow_source(project, name, started, late, release):
    source = project / 'src' / name
    # Actual GHC/Template Haskell work cannot finish naturally while its gate
    # remains closed. The positive control proves the same gate reaches an effect.
    for marker in [started, late, release]:
        require('fresh-compiler-marker-' + marker, not (project / marker).exists())
    source.write_text('{-# LANGUAGE TemplateHaskell #-}\nmodule Slow where\n'
        'import Control.Concurrent (threadDelay)\n'
        'import Control.Monad (unless)\n'
        'import System.Directory (doesFileExist)\n'
        'import Language.Haskell.TH (runIO)\n'
        'value :: ()\nvalue = $(do\n'
        '  runIO $ do\n'
        f'    writeFile "{started}" "started"\n'
        '    let awaitRelease = do\n'
        f'          released <- doesFileExist "{release}"\n'
        '          unless released (threadDelay 20000 >> awaitRelease)\n'
        '    awaitRelease\n'
        f'    writeFile "{late}" "late"\n'
        '  [| () |])\n', encoding='utf-8')
    return source


def compiler_timing(label, **values):
    record = {'check': label, **values}
    RECORDS.append(record)
    print(json.dumps(record, ensure_ascii=True), flush=True)
    return record


def release_fixture(process, release):
    # Failure cleanup is never acceptance: open the gate so a real compiler
    # cannot remain indefinitely blocked, then allow its own bounded CLI to exit.
    # A failed CLI may already have exited while leaving a descendant gated.
    # Opening the gate is necessary even then; this finally path grants no pass.
    release.touch(exist_ok=True)
    if process.poll() is None:
        try:
            process.communicate(timeout=55)
        except subprocess.TimeoutExpired:
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               capture_output=True, timeout=15)
            else:
                process.terminate()
            process.communicate(timeout=15)


def positive_compiler_gate(binary, project):
    started, late, release = 'control-started', 'control-effect', 'control-release'
    slow_source(project, 'Slow.hs', started, late, release)
    command = [str(binary), 'check', 'src/Slow.hs', '--project', str(project),
               '--timeout', '30', '--json']
    print('real-ghc-gate-positive-control', flush=True)
    began = time.monotonic()
    process = subprocess.Popen(command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8', errors='replace')
    try:
        deadline = began + 30
        while not (project / started).exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        ready = (project / started).exists()
        ready_seconds = round(time.monotonic() - began, 3) if ready else None
        closed = not (project / late).exists()
        # This live-child control is intentionally released; it must produce the
        # effect and finish successfully, unlike the timed-out/signal cases below.
        (project / release).write_text('positive control release', encoding='utf-8')
        released_at = time.monotonic()
        stdout, stderr = process.communicate(timeout=40)
        timings = compiler_timing('real-ghc-positive-control-timing',
            started_seconds=ready_seconds, completion_seconds=round(time.monotonic() - began, 3),
            release_to_completion_seconds=round(time.monotonic() - released_at, 3))
        diagnostic = json.dumps({'command': command, 'exit_code': process.returncode,
            'stdout': stdout, 'stderr': stderr, 'timings': timings, 'observed_tools': ENVIRONMENT}, ensure_ascii=True)
        require('positive-control-compiler-started', ready, diagnostic)
        require('positive-control-gate-prevented-effect', closed, diagnostic)
        require('positive-control-compiler-completed', process.returncode == 0, diagnostic)
        result = json.loads(stdout)
        require('positive-control-json-success', result.get('exit_code') == 0 and not stderr, diagnostic)
        require('positive-control-release-produced-effect', (project / late).is_file(), diagnostic)
    finally:
        release_fixture(process, project / release)


def no_released_effect(project, late):
    # A bounded observation, not a claim about arbitrarily suspended processes.
    # The positive live-child control proves this same release path can produce it.
    deadline = time.monotonic() + 4
    while not (project / late).exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    return not (project / late).exists()


def cancellation(binary, project):
    positive_compiler_gate(binary, project)
    started, late, release = 'timeout-started', 'timeout-late', 'timeout-release'
    source = slow_source(project, 'Slow.hs', started, late, release)
    began = time.monotonic()
    # Windows GHC9.6.7 was observed entering healthy TH at4.656s. This deadline
    # provides startup headroom; the closed gate, not a fixed sleep, prevents exit.
    try:
        result = cli(binary, 'real-ghc-timeout', 'check', project,
                     str(source.relative_to(project)), '--timeout', '15', expected=1)
        timings = compiler_timing('real-ghc-timeout-timing', deadline_seconds=15,
            completion_seconds=round(time.monotonic() - began, 3),
            started_marker=(project / started).is_file(), release_exists_at_return=(project / release).exists())
        diagnostic = json.dumps({'result': result, 'timings': timings, 'observed_tools': ENVIRONMENT}, ensure_ascii=True)
        require('timeout-reports-exact-deadline', result['stderr'] ==
                'Command timed out; process tree terminated.', diagnostic)
        require('timeout-interrupted-running-ghc', (project / started).is_file(), diagnostic)
        require('timeout-gate-prevented-natural-completion', not (project / late).exists(), diagnostic)
    finally:
        # The synchronous CLI has returned (or failed); release cannot precede it.
        # On assertion failure this is cleanup, never a passing observation.
        (project / release).write_text('post-timeout release', encoding='utf-8')
    require('timeout-leaves-no-running-compiler-effect', no_released_effect(project, late), diagnostic)
    if os.name == 'nt':
        RECORDS.append({'check': 'posix-signal-cancellation', 'status': 'not-applicable'})
        source.unlink()
        return
    for name, sig, accepted in [('sigterm', signal.SIGTERM, {143, -signal.SIGTERM}),
                                ('sigint', signal.SIGINT, {130, -signal.SIGINT})]:
        started, late, release = name + '-started', name + '-late', name + '-release'
        slow_source(project, 'Slow.hs', started, late, release)
        command = [str(binary), 'check', 'src/Slow.hs', '--project', str(project), '--json']
        began = time.monotonic()
        process = subprocess.Popen(command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding='utf-8', errors='replace')
        try:
            deadline = began + 15
            while not (project / started).exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            if not (project / started).exists():
                (project / release).write_text('failed startup cleanup', encoding='utf-8')
                stdout, stderr = process.communicate(timeout=40)
                require(name + '-compiler-started', False, json.dumps({'command': command,
                    'exit_code': process.returncode, 'stdout': stdout, 'stderr': stderr}, ensure_ascii=True))
            require(name + '-compiler-started', True)
            ready_seconds = round(time.monotonic() - began, 3)
            process.send_signal(sig)
            stdout, stderr = process.communicate(timeout=10)
            timings = compiler_timing(name + '-compiler-timing', started_seconds=ready_seconds,
                completion_seconds=round(time.monotonic() - began, 3))
            diagnostic = json.dumps({'command': command, 'exit_code': process.returncode,
                'stdout': stdout, 'stderr': stderr, 'timings': timings}, ensure_ascii=True)
            require(name + '-exit-code', process.returncode in accepted, diagnostic)
            require(name + '-gate-prevented-natural-completion', not (project / late).exists(), diagnostic)
            (project / release).write_text('post-signal release', encoding='utf-8')
            require(name + '-no-late-compiler-effect', no_released_effect(project, late), diagnostic)
        finally:
            release_fixture(process, project / release)
    source.unlink()


def compiler_profile(project, compiler):
    """Explicit machine-local selection; never overwrite a caller's profile."""
    value = str(compiler).replace('\\', '/')
    if any(ord(character) < 32 for character in value):
        raise ValueError('Compiler path contains a control character')
    with (project / 'cabal.project.local').open('x', encoding='utf-8', newline='\n') as profile:
        # This Cabal field is a whole raw value, not a Haskell/JSON string literal.
        profile.write('with-compiler: ' + value + '\n')


def same_path(left, right):
    # Normalize spelling only: do not resolve symlinks or bypass custom wrappers.
    return os.path.normcase(os.path.abspath(left)) == os.path.normcase(os.path.abspath(right))


def legacy_adapter_source():
    """Run the unchanged checker with explicit compiler selection and UTF-8 JSON."""
    return ("import json,sys; from pathlib import Path; from unittest.mock import patch; "
            "sys.stdout.reconfigure(encoding='utf-8', errors='replace'); "
            "sys.path.insert(0,sys.argv[1]); import fp_game; "
            "original=fp_game.shutil.which; "
            "selected=lambda name,*a,**k: sys.argv[3] if name=='ghc' else original(name,*a,**k); "
            "context=patch.object(fp_game.shutil,'which',selected); context.start(); "
            "result=fp_game.check_file(Path(sys.argv[2]),'src/Unicode.hs'); "
            "print(json.dumps(result,ensure_ascii=False)); sys.exit(result['exit_code'])")


def legacy_adapter_encoding_check(project, compiler, cwd):
    result = run('legacy-adapter-forced-cp1252',
                 [sys.executable, '-c', legacy_adapter_source(), ROOT / 'tools/acceptance/fixtures/python_cli', project, compiler],
                 cwd, env=dict(os.environ, PYTHONIOENCODING='cp1252'))
    executed('legacy-adapter-forced-cp1252', result)
    require('legacy-adapter-preserves-unicode-path',
            same_path(result['command'][-1], project / 'src/Unicode.hs'))


def acceptance(binary, trial, compiler=None):
    bootstrap_refusals(trial, compiler)
    unrelated = trial / 'unrelated caller 日本語'
    unrelated.mkdir()
    fixture = trial / 'source snapshot 日本語'
    source_snapshot(fixture)
    selected_compiler = compiler or Path(shutil.which('ghc')).absolute()
    query_compiler = selected_compiler
    if os.name != 'nt':
        # Exercise the actual field grammar and preserve a user-selected wrapper
        # with spaces/Unicode, forwarding every argument to the real compiler.
        query_compiler = trial / 'custom compiler 日本語'
        query_compiler.write_text('#!/bin/sh\nexec ' + shlex.quote(str(selected_compiler)) + ' "$@"\n', encoding='utf-8')
        query_compiler.chmod(0o755)
    compiler_profile(fixture, query_compiler)
    require('foundation-snapshot-has-no-git', not (fixture / '.git').exists())
    installed = trial / 'installed tooling 日本語' / binary.name
    installed.parent.mkdir()
    shutil.copy2(binary, installed)
    binary = installed
    game = trial / 'first independent game 日本語'
    args = ['acceptance-game', str(game), '--title', '独立したゲーム']

    fresh_cabal_home = trial / 'absent global Cabal home'
    doctor = cli(binary, 'native-doctor', 'doctor', fixture, cwd=unrelated,
                 env=dict(os.environ, CABAL_DIR=str(fresh_cabal_home)))
    require('doctor-does-not-initialize-global-cabal-home', not fresh_cabal_home.exists())
    ENVIRONMENT.update({name: doctor['tools'][name]['version'] for name in ['ghc', 'cabal']})
    ENVIRONMENT['compiler_profile'] = 'explicit project-local compiler; Cabal authoritative selection'
    require('doctor-identifies-haskell', doctor.get('implementation') == 'haskell')
    require('doctor-not-a-build-claim', doctor.get('status') == 'ready-to-try')
    require('doctor-reports-selected-compiler', same_path(doctor['tools']['ghc']['path'], query_compiler)
            and doctor['compiler_selection']['path'] == doctor['tools']['ghc']['path'])
    require('doctor-cleans-scoped-query-state', not (fixture / '.build').exists())
    if os.name != 'nt':
        cabal_only = trial / 'cabal only PATH'
        cabal_only.mkdir()
        (cabal_only / 'cabal').symlink_to(shutil.which('cabal'))
        # A custom compiler name cannot infer the package-tool sibling; retain
        # its real package manager while deliberately excluding ambient ghc.
        (cabal_only / 'ghc-pkg').symlink_to(shutil.which('ghc-pkg'))
        no_ambient = cli(binary, 'doctor-explicit-compiler-without-ambient-ghc', 'doctor', fixture,
                         env=dict(os.environ, PATH=str(cabal_only)))
        require('doctor-honors-selected-compiler-without-ambient-ghc',
                same_path(no_ambient['tools']['ghc']['path'], query_compiler)
                and no_ambient['status'] == 'ready-to-try')
        require('no-ambient-doctor-cleans-query-state', not (fixture / '.build').exists())
    existing_state = fixture / '.build'
    existing_state.mkdir()
    sentinel = existing_state / 'user-cache-sentinel'
    sentinel.write_bytes(b'preserve existing state')
    cli(binary, 'doctor-preserves-existing-build-state', 'doctor', fixture)
    require('doctor-removes-only-its-own-query-state', list(existing_state.iterdir()) == [sentinel]
            and sentinel.read_bytes() == b'preserve existing state')
    shutil.rmtree(existing_state)
    missing_project = trial / 'missing tools project'
    missing_project.mkdir()
    missing_path = dict(os.environ, PATH=str(trial / 'absent-tools'))
    missing = cli(binary, 'missing-tools', 'doctor', missing_project, expected=1, env=missing_path)
    require('missing-tools-explicit', missing.get('status') == 'missing-tools'
            and set(missing.get('missing', [])) >= {'ghc', 'cabal'}
            and missing.get('compiler_selection') is None)
    require('missing-tools-doctor-creates-no-state', not list(missing_project.iterdir()))
    run('unknown-command', [binary, 'unknown-command'], unrelated, expected=2, json_result=False)

    invalid_run = trial / 'invalid run target'
    invalid_run.mkdir()
    (invalid_run / 'fp-game.json').write_text(json.dumps({
        'source_dirs': [], 'default_executable': '--help'}), encoding='utf-8')
    error('executable-option-injection', cli(binary, 'executable-option-injection-refused',
          'run', invalid_run, '--smoke', expected=1))
    require('invalid-executable-rejected-before-build-state', not (invalid_run / '.build').exists())

    deadline_project = trial / 'interactive deadline refusal'
    deadline_project.mkdir()
    deadline_error = cli(binary, 'interactive-deadline-refused-before-config', 'run',
                         deadline_project, '--timeout', '1', expected=1)
    error('interactive-deadline', deadline_error)
    require('interactive-deadline-specific-diagnostic', '--timeout' in deadline_error['stderr']
            and '--smoke' in deadline_error['stderr'])
    require('interactive-deadline-creates-no-build-state', not (deadline_project / '.build').exists())

    plan = cli(binary, 'native-create-plan', 'create-plan', fixture, *args, cwd=unrelated)
    require('plan-creates-nothing', not game.exists() and plan.get('mutates') is False)
    require('plan-status', plan.get('status') == 'planned')
    no_tools = cli(binary, 'installed-plan-needs-no-toolchain-or-python', 'create-plan', fixture,
                   *args, cwd=unrelated, env=missing_path)
    require('installed-plan-no-tools-equivalent', no_tools == plan)
    require('plan-file-hashes', isinstance(plan.get('files'), dict)
            and all(len(value) == 64 for value in plan['files'].values()))
    relative_project = os.path.relpath(fixture, unrelated)
    relative_game = trial / 'My Game 日本語'
    relative_destination = os.path.relpath(relative_game, unrelated)
    before_relative = set(trial.iterdir())
    relative_plan = cli(binary, 'relative-root-create-plan', 'create-plan', relative_project,
                        'relative-game', relative_destination, cwd=unrelated)
    require('relative-roots-resolve-from-caller', relative_plan['destination'] == str(relative_game))
    require('relative-plan-creates-nothing', set(trial.iterdir()) == before_relative)
    caller_plan = cli(binary, 'caller-relative-destination-plan', 'create-plan', relative_project,
                      'relative-game', 'inside caller 日本語', cwd=unrelated)
    require('destination-independent-of-project-root', caller_plan['destination']
            == str(unrelated / 'inside caller 日本語'))
    relative_created = cli(binary, 'relative-root-create', 'create', relative_project,
                           'relative-game', relative_destination, cwd=unrelated)
    require('relative-create-chosen-root-only', relative_created['destination'] == str(relative_game)
            and set(trial.iterdir()) == before_relative | {relative_game}
            and not list(unrelated.iterdir()))
    require('relative-create-planned-bytes', all(hashlib.sha256((relative_game / name).read_bytes()).hexdigest() == digest
            for name, digest in relative_plan['files'].items()))
    shutil.rmtree(relative_game)
    legacy_plan = run('legacy-contract-plan', [sys.executable, ROOT / 'tools/acceptance/legacy_oracle.py',
        'plan', *args, '--json'], unrelated)
    require('legacy-plan-shape-compatible', set(legacy_plan) <= set(plan))
    require('legacy-plan-metadata-compatible', all(plan[key] == legacy_plan[key]
            for key in ['status', 'exit_code', 'destination', 'template', 'target',
                        'rendering', 'game_license', 'mutates']))
    shared_sources = [name for name in legacy_plan['files']
                      if name.startswith(('src/', 'app/', 'test/', 'vendor/'))]
    require('legacy-game-source-bytes-compatible', bool(shared_sources) and all(
            plan['files'].get(name) == legacy_plan['files'][name] for name in shared_sources))
    require('generated-product-excludes-retired-python', not any(name in plan['files'] for name in ['tools/fp_game.py', 'tools/scaffold.py'])
            and not any(name.startswith('tools/acceptance/') for name in plan['files']))
    require('generated-product-retains-specialist-inspection', 'tools/inspect_haskell.py' in plan['files'])
    require('generated-editor-source-boundary', {name for name in plan['files'] if name.startswith('editors/')} ==
            {'editors/vscode/package.json', 'editors/vscode/extension.js', 'editors/vscode/LICENSE', 'editors/neovim/fp-game.lua'})
    for name in ['tools/haskell/.build/poison.bin', 'editors/haskell-design/.runtime/poison.bin',
                 'editors/haskell-design/dist/poison.bin', 'editors/haskell-design/node_modules/poison.bin',
                 'editors/haskell-design/native/vendor/poison.bin', 'editors/haskell-design/native/dist-newstyle/poison.bin',
                 'editors/haskell-design/.haskell-design.json', 'editors/vscode/local-only.json']:
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'not distributable\x00\r\n')
    dirty = cli(binary, 'native-plan-ignores-local-outputs', 'create-plan', fixture, *args, cwd=unrelated)
    require('explicit-distribution-unaffected-by-binaries', dirty == plan)
    selected = fixture / 'templates/terminal-adventure/src/Game/Rules.hs'
    original = selected.read_bytes()
    source_target = trial / 'outside selected source.hs'
    source_target.write_bytes(original)
    selected.unlink()
    if symlink_or_record(selected, source_target):
        error('linked-template', cli(binary, 'linked-template-refused', 'create-plan', fixture, *args, expected=1))
        selected.unlink()
    selected.write_bytes(original)
    for obsolete in ['plan', 'scaffold']:
        refused = run('obsolete-' + obsolete + '-refused', [binary, obsolete, *args, '--json'], unrelated, expected=2, json_result=False)
        require('obsolete-' + obsolete + '-has-no-fallback', 'Unknown command: ' + obsolete in refused.stderr and not game.exists())
    dry = cli(binary, 'native-create-dry-run', 'create', fixture, *args, '--dry-run', cwd=unrelated)
    require('dry-run-equivalent-and-no-directory', dry == plan and not game.exists())

    foundation_link = trial / 'linked foundation'
    if symlink_or_record(foundation_link, fixture, directory=True):
        error('linked-foundation', cli(binary, 'linked-foundation-root-refused', 'create-plan',
                                      foundation_link, *args, expected=1))
        require('linked-foundation-created-nothing', not game.exists())
        foundation_link.unlink()
    for label, extra in [('invalid-name', ['Bad-Name', str(game)]),
                         ('unsupported-platform', [*args, '--target', 'web', '--rendering', 'miso']),
                         ('license-needs-author', [*args, '--license', 'MIT'])]:
        error(label, cli(binary, label, 'create-plan', fixture, *extra, expected=1))
        require(label + '-created-nothing', not game.exists())
    occupied = trial / 'existing directory'
    occupied.mkdir()
    sentinel = occupied / 'user.txt'
    sentinel.write_text('preserve me', encoding='utf-8')
    error('existing', cli(binary, 'existing-destination-refused', 'create', fixture,
                         'acceptance-game', str(occupied), expected=1))
    require('existing-directory-preserved', sentinel.read_text() == 'preserve me'
            and list(occupied.iterdir()) == [sentinel])

    created = cli(binary, 'native-create', 'create', fixture, *args, cwd=unrelated)
    require('created-status', created.get('status') == 'created')
    require('planned-files-match-created-bytes', all((game / name).is_file()
            and hashlib.sha256((game / name).read_bytes()).hexdigest() == digest
            for name, digest in plan['files'].items()))
    snapshot = (game / 'scaffold-manifest.json').read_bytes()
    error('repeat', cli(binary, 'repeat-create-refused', 'create', fixture, *args, expected=1))
    require('repeat-preserves-manifest', (game / 'scaffold-manifest.json').read_bytes() == snapshot)
    require('local-continuation-skill', (game / '.agents/skills/game-dev/SKILL.md').is_file())
    require('local-native-sources', (game / 'tools/haskell/cabal.project').is_file())
    require('generated-game-never-embeds-local-foundation-path', not any(
        str(fixture).encode() in path.read_bytes() or str(ROOT).encode() in path.read_bytes()
        for path in game.rglob('*') if path.is_file()))
    lock = json.loads((game / 'foundation.lock.json').read_text(encoding='utf-8'))
    require('kernel-pins', lock['packages'] == {'game-transition': '0.1.0.0', 'game-arena': '0.1.0.0'})
    require('vendored-file-hashes', all(hashlib.sha256((game / name).read_bytes()).hexdigest() == digest
            for name, digest in lock['sha256_lf'].items()))

    require('generated-no-machine-compiler-profile', not list(game.rglob('cabal.project.local')))
    compiler_profile(game, selected_compiler)
    profile_bytes = (game / 'cabal.project.local').read_bytes()
    try:
        compiler_profile(game, trial / 'different-compiler')
    except FileExistsError:
        pass
    else:
        raise AssertionError('Compiler setup overwrote an existing local profile')
    require('compiler-profile-preserves-existing-config', (game / 'cabal.project.local').read_bytes() == profile_bytes)
    # A deliberately unavailable explicit compiler must fail the authoritative
    # query while a valid ambient GHC is still present. No fallback can pass.
    unavailable = trial / 'unavailable compiler project'
    unavailable.mkdir()
    (unavailable / 'src').mkdir()
    (unavailable / 'src/Unavailable.hs').write_text('module Unavailable where\n', encoding='utf-8')
    (unavailable / 'cabal.project').write_text('packages: .\n', encoding='utf-8')
    (unavailable / 'unavailable.cabal').write_text('cabal-version: 3.0\nname: unavailable\nversion: 0.1.0.0\n'
        'build-type: Simple\nlibrary\n  exposed-modules: Unavailable\n  hs-source-dirs: src\n'
        '  default-language: Haskell2010\n  build-depends: base\n', encoding='utf-8')
    (unavailable / 'fp-game.json').write_text('{"source_dirs":["src"]}', encoding='utf-8')
    compiler_profile(unavailable, trial / 'absent chosen compiler' / 'ghc.exe')
    for action, options in [('doctor', []), ('check', ['src/Unavailable.hs'])]:
        refused = cli(binary, 'unavailable-selected-compiler-' + action, action, unavailable, *options, expected=1)
        error('unavailable-compiler-' + action, refused)
        require('unavailable-compiler-no-fallback-' + action, refused['error_code'] == 'invalid-config'
                and 'No PATH fallback' in refused['stderr'])
        require('unavailable-query-cleans-temporary-state-' + action, not (unavailable / '.build').exists())
    for action in ['build', 'test', 'check']:
        result = cli(binary, 'native-' + action, action, game, cwd=unrelated)
        executed(action, result)
        require(action + '-isolates-game-cabal-state', '--offline' in result['command']
                and any(value.startswith('--config-file=') and str(game / '.build') in value
                        for value in result['command']))
    result = cli(binary, 'native-smoke', 'run', game, '--smoke', cwd=unrelated)
    executed('smoke', result)
    require('real-game-smoke-output', 'gameplay/save smoke: PASS' in result['stdout'])
    bounded_smoke = cli(binary, 'native-smoke-explicit-deadline', 'run', game,
                        '--smoke', '--timeout', '10', cwd=unrelated)
    require('bounded-smoke-runs-real-game', 'gameplay/save smoke: PASS' in bounded_smoke['stdout'])
    good = game / 'src/Unicode.hs'
    good.write_bytes('-- 日本語\r\nmodule Unicode where\r\nvalue :: Integer\r\nvalue = 7\r\n'.encode())
    native = cli(binary, 'native-crlf-unicode-check', 'check', game, 'src/Unicode.hs')
    require('saved-check-uses-selected-compiler', same_path(native['command'][0], selected_compiler))
    legacy_adapter_encoding_check(game, selected_compiler, unrelated)
    if os.name == 'nt':
        # Keep the real unchanged Python checker, changing only its explicit
        # compiler lookup for this diagnostic comparison. PATH stays untouched.
        adapter = legacy_adapter_source()
        legacy = run('legacy-check-explicit-compiler-selection-adapter',
                     [sys.executable, '-c', adapter, ROOT / 'tools/acceptance/fixtures/python_cli', game, selected_compiler], unrelated)
    else:
        legacy = run('legacy-contract-check', [sys.executable, ROOT / 'tools/acceptance/legacy_oracle.py',
            'check', 'src/Unicode.hs', '--project', game, '--json'], unrelated)
    require('legacy-execution-schema-compatible', set(native) == set(legacy))
    require('legacy-compiler-flags-compatible', all(flag in native['command'] and flag in legacy['command']
            for flag in ['-fno-code', '-fforce-recomp', '-XGHC2021', '-Wall', '-fdiagnostics-color=never']))
    good.write_text('module Unicode where\nvalue :: Integer\nvalue = True\n', encoding='utf-8')
    bad = cli(binary, 'native-real-compiler-error', 'check', game, 'src/Unicode.hs', expected=1)
    executed('compiler-error', bad)
    require('actual-compiler-diagnostic', 'Bool' in bad['stderr'])
    good.unlink()

    outside = trial / 'Outside.hs'
    outside.write_text('module Outside where\n', encoding='utf-8')
    error('path-escape', cli(binary, 'source-escape-refused', 'check', game, str(outside), expected=1))
    source_link = game / 'src/Linked.hs'
    if symlink_or_record(source_link, outside):
        error('linked-source', cli(binary, 'linked-source-refused', 'check', game, 'src/Linked.hs', expected=1))
        source_link.unlink()
    configuration = game / 'fp-game.json'
    content = configuration.read_bytes()
    for label, config in [('wrong-source-shape', {'source_dirs': 'src'}),
                          ('escape-source-dir', {'source_dirs': [str(trial)]})]:
        configuration.write_text(json.dumps(config), encoding='utf-8')
        error(label, cli(binary, label, 'check', game, 'src/Game/Rules.hs', expected=1))
    configuration.write_bytes(content)
    fresh = trial / 'linked build project'
    fresh.mkdir()
    if symlink_or_record(fresh / '.build', trial, directory=True):
        error('linked-build-state', cli(binary, 'linked-build-state-refused', 'build', fresh, expected=1))

    linked_logs = trial / 'linked log project'
    (linked_logs / '.build').mkdir(parents=True)
    outside_logs = trial / 'outside logs'
    outside_logs.mkdir()
    if symlink_or_record(linked_logs / '.build/logs', outside_logs, directory=True):
        refused = cli(binary, 'linked-log-directory-refused', 'build', linked_logs, expected=1)
        error('linked-logs', refused)
        require('linked-logs-specific-refusal', refused['error_code'] == 'unsafe-path')
        require('linked-log-directory-outside-untouched', not list(outside_logs.iterdir()))
        require('linked-logs-refused-before-config-write', not (linked_logs / '.build/cabal.config').exists())

    external_config = trial / 'external-cabal-config'
    external_config.write_bytes(b'outside content must not be truncated\n')
    config_path = game / '.build/cabal.config'
    config_path.unlink()
    try:
        os.link(external_config, config_path)
    except OSError as failure:
        if os.name != 'nt':
            raise
        RECORDS.append({'check': 'windows-hardlink-availability', 'status': 'unavailable',
                        'reason': type(failure).__name__})
    else:
        cli(binary, 'hardlinked-config-atomic-replacement', 'build', game)
        require('hardlinked-outside-content-preserved', external_config.read_bytes()
                == b'outside content must not be truncated\n')
        require('cabal-config-no-longer-shares-hardlink', config_path.stat().st_nlink == 1)

    add_key(game)
    require('feature-edit-without-regeneration', (game / 'scaffold-manifest.json').read_bytes() == snapshot)
    cli(binary, 'native-key-tests', 'test', game)
    played = run('native-key-play', [binary, 'run', '--project', game], unrelated,
                 input_text='south\nsave\nload\neast\neast\nexit\nquit\n', json_result=False)
    require('actual-key-gameplay', all(word in played.stdout for word in
            ['Collected the key.', 'Saved.', 'Loaded.', 'You escaped.']))

    require('native-operations-preserve-selected-profile', (game / 'cabal.project.local').read_bytes() == profile_bytes)
    relocated = trial / 'relocated continued game 日本語'
    shutil.copytree(game, relocated, ignore=shutil.ignore_patterns('.build', 'dist-newstyle', '__pycache__', '*.py', 'cabal.project.local'))
    shutil.rmtree(game)
    shutil.rmtree(fixture)
    require('original-game-and-foundation-removed', not game.exists() and not fixture.exists())
    require('relocated-no-python-scripts', not list(relocated.rglob('*.py')))
    require('relocated-no-game-build-cache', not (relocated / '.build').exists())
    require('relocated-profile-not-copied', not list(relocated.rglob('cabal.project.local')))
    compiler_profile(relocated, selected_compiler)
    native_local = bootstrap(relocated, 'standalone-native-bootstrap', compiler)
    local_hash = hashlib.sha256(native_local.read_bytes()).hexdigest()
    local_modified = native_local.stat().st_mtime_ns
    for action in ['build', 'test']:
        executed('relocated-' + action, cli(native_local, 'relocated-native-' + action, action, relocated, cwd=unrelated))
    cli(native_local, 'relocated-native-check', 'check', relocated, 'src/Game/Rules.hs', cwd=unrelated)
    smoke = cli(native_local, 'relocated-native-smoke', 'run', relocated, '--smoke', cwd=unrelated)
    require('relocated-real-smoke', 'gameplay/save smoke: PASS' in smoke['stdout'])
    terminal_checks(native_local, relocated, require)
    add_stamina(relocated)
    cli(native_local, 'relocated-stamina-tests', 'test', relocated)
    played = run('relocated-stamina-play', [native_local, 'run', '--project', relocated], unrelated,
                 input_text='south\neast\nnorth\neast\nrest\neast\nrest\nsouth\nexit\nquit\n', json_result=False)
    require('actual-second-mechanic', all(word in played.stdout for word in
            ['Too tired to move.', 'Rested to recover stamina.', 'You escaped.']))
    require('continuation-never-regenerates', (relocated / 'scaffold-manifest.json').read_bytes() == snapshot)
    require('normal-cli-never-replaces-itself', hashlib.sha256(native_local.read_bytes()).hexdigest() == local_hash
            and native_local.stat().st_mtime_ns == local_modified)
    current = run('caller-cwd-default', [native_local, 'check', 'src/Game/Rules.hs', '--json'], relocated)
    executed('caller-cwd-default', current)
    cancellation(native_local, relocated)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--windows-compiler', type=Path, help='Explicit verified compiler profile; required on Windows')
    parser.add_argument('--report', type=Path, default=ROOT / '.build/native-cli-report.json')
    args = parser.parse_args()
    if os.name == 'nt' and args.windows_compiler is None:
        parser.error('Windows acceptance requires --windows-compiler from the declared toolchain profile')
    compiler = args.windows_compiler.absolute() if args.windows_compiler is not None else None
    if compiler is not None and not compiler.is_file():
        parser.error('The explicitly selected compiler does not exist')
    binary = args.binary.resolve()
    require('real-native-executable-present', binary.is_file())
    input_hashes = source_hashes()
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    status = 'fail'
    try:
        with tempfile.TemporaryDirectory(prefix='FP native acceptance 日本語 ') as temporary:
            trial = Path(temporary).resolve()
            require('trial-outside-foundation', not trial.is_relative_to(ROOT))
            acceptance(binary, trial, compiler)
        require('source-inputs-stable-through-test', source_hashes() == input_hashes)
        status = 'pass'
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({'schema': 1, 'status': status,
            'scope': 'Real native CLI and optional terminal workspace development; no physical editor, graphical host or human play acceptance.',
            'environment': ENVIRONMENT,
            'binary_sha256': binary_hash,
            'input_source_scope': 'Native package, bootstrap, harness, optional starter/core fixtures, legacy contract oracle, native/prevention guides, workflow and formatter selection; excludes local outputs and evidence reports.',
            'input_sha256_lf': input_hashes,
            'checks': RECORDS}, indent=2) + '\n', encoding='utf-8')
    print(f'native CLI integration: PASS ({len(RECORDS)} recorded checks on {platform.system()})')


if __name__ == '__main__':
    main()
