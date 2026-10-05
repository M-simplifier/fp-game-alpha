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
            if path.is_file() and not any(part in {'.build', 'dist-newstyle', '__pycache__'}
                                          for part in path.relative_to(ROOT).parts):
                inputs.add(path)
    for name in ['tools/bootstrap-fp-game.sh', 'tools/bootstrap-fp-game.ps1',
                 'tools/test_native_cli.py', 'tools/test_native_terminal.py',
                 'tools/acceptance/features.py', 'tools/fp_game.py', 'tools/scaffold.py',
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


def bootstrap(project, label):
    if os.name == 'nt':
        shell = shutil.which('pwsh') or shutil.which('powershell')
        require(label + '-powershell-present', shell is not None)
        command = [shell, '-NoProfile', '-File', project / 'tools/bootstrap-fp-game.ps1']
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


def bootstrap_refusals(trial):
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
                                                     '*.hi', '*.o', '*.exe'))
    shutil.copy2(ROOT / 'LICENSE', destination / 'LICENSE')


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


def slow_source(project, name, started, late):
    source = project / 'src' / name
    # Actual GHC Template Haskell work exercises cancellation of a real compiler,
    # including its interpreter process when the compiler uses one.
    source.write_text('{-# LANGUAGE TemplateHaskell #-}\nmodule Slow where\n'
        'import Control.Concurrent (threadDelay)\n'
        'import Language.Haskell.TH (runIO)\n'
        'value :: ()\nvalue = $(do\n'
        f'  runIO (writeFile "{started}" "started" >> threadDelay 5000000 >> writeFile "{late}" "late")\n'
        '  [| () |])\n', encoding='utf-8')
    return source


def cancellation(binary, project):
    started, late = 'timeout-started', 'timeout-late'
    source = slow_source(project, 'Slow.hs', started, late)
    result = cli(binary, 'real-ghc-timeout', 'check', project,
                 str(source.relative_to(project)), '--timeout', '2', expected=1)
    require('timeout-reports-failure', bool(result['stderr']))
    require('timeout-interrupted-running-ghc', (project / started).is_file())
    time.sleep(4)
    require('timeout-leaves-no-running-compiler-effect', not (project / late).exists())
    if os.name == 'nt':
        RECORDS.append({'check': 'posix-signal-cancellation', 'status': 'not-applicable'})
        return
    for name, sig, accepted in [('sigterm', signal.SIGTERM, {143, -signal.SIGTERM}),
                                ('sigint', signal.SIGINT, {130, -signal.SIGINT})]:
        started, late = name + '-started', name + '-late'
        slow_source(project, 'Slow.hs', started, late)
        command = [str(binary), 'check', 'src/Slow.hs', '--project', str(project), '--json']
        process = subprocess.Popen(command, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while not (project / started).exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            require(name + '-compiler-started', (project / started).is_file())
            process.send_signal(sig)
            process.communicate(timeout=10)
            require(name + '-exit-code', process.returncode in accepted, str(process.returncode))
            time.sleep(5)
            require(name + '-no-late-compiler-effect', not (project / late).exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
    source.unlink()


def acceptance(binary, trial):
    bootstrap_refusals(trial)
    unrelated = trial / 'unrelated caller 日本語'
    unrelated.mkdir()
    fixture = trial / 'source snapshot 日本語'
    source_snapshot(fixture)
    require('foundation-snapshot-has-no-git', not (fixture / '.git').exists())
    installed = trial / 'installed tooling 日本語' / binary.name
    installed.parent.mkdir()
    shutil.copy2(binary, installed)
    binary = installed
    game = trial / 'first independent game 日本語'
    args = ['acceptance-game', str(game), '--title', '独立したゲーム']

    doctor = cli(binary, 'native-doctor', 'doctor', fixture, cwd=unrelated)
    ENVIRONMENT.update({name: doctor['tools'][name]['version'] for name in ['ghc', 'cabal']})
    require('doctor-identifies-haskell', doctor.get('implementation') == 'haskell')
    require('doctor-not-a-build-claim', doctor.get('status') == 'ready-to-try')
    missing_path = dict(os.environ, PATH=str(trial / 'absent-tools'))
    missing = cli(binary, 'missing-tools', 'doctor', fixture, expected=1, env=missing_path)
    require('missing-tools-explicit', missing.get('status') == 'missing-tools'
            and set(missing.get('missing', [])) >= {'ghc', 'cabal'})
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
    legacy_plan = run('legacy-contract-plan', [sys.executable, ROOT / 'tools/fp_game.py',
        'plan', *args, '--project', ROOT, '--json'], unrelated)
    require('legacy-plan-shape-compatible', set(legacy_plan) <= set(plan))
    require('legacy-plan-metadata-compatible', all(plan[key] == legacy_plan[key]
            for key in ['status', 'exit_code', 'destination', 'template', 'target',
                        'rendering', 'game_license', 'mutates']))
    shared_sources = [name for name in legacy_plan['files']
                      if name.startswith(('src/', 'app/', 'test/', 'vendor/'))]
    require('legacy-game-source-bytes-compatible', bool(shared_sources) and all(
            plan['files'].get(name) == legacy_plan['files'][name] for name in shared_sources))
    for name in ['tools/haskell/.build/poison.bin', 'editors/haskell-design/.runtime/poison.bin']:
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
    alias = cli(binary, 'native-plan-alias', 'plan', fixture, *args, cwd=unrelated)
    require('plan-alias-equivalent', plan == alias)
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
    legacy = run('legacy-contract-check', [sys.executable, ROOT / 'tools/fp_game.py',
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

    relocated = trial / 'relocated continued game 日本語'
    shutil.copytree(game, relocated, ignore=shutil.ignore_patterns('.build', 'dist-newstyle', '__pycache__', '*.py'))
    shutil.rmtree(game)
    shutil.rmtree(fixture)
    require('original-game-and-foundation-removed', not game.exists() and not fixture.exists())
    require('relocated-no-python-scripts', not list(relocated.rglob('*.py')))
    require('relocated-no-game-build-cache', not (relocated / '.build').exists())
    native_local = bootstrap(relocated, 'standalone-native-bootstrap')
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
    parser.add_argument('--report', type=Path, default=ROOT / '.build/native-cli-report.json')
    args = parser.parse_args()
    binary = args.binary.resolve()
    require('real-native-executable-present', binary.is_file())
    input_hashes = source_hashes()
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    status = 'fail'
    try:
        with tempfile.TemporaryDirectory(prefix='FP native acceptance 日本語 ') as temporary:
            trial = Path(temporary).resolve()
            require('trial-outside-foundation', not trial.is_relative_to(ROOT))
            acceptance(binary, trial)
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
