"""Build, change, relocate and continue an independent game with ordinary Cabal.

Artifacts remain in the system temporary directory for inspection. The public
report contains hashes and outcomes, never personal absolute paths or raw logs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from acceptance.features import add_key, add_stamina
import fp_game

ROOT = Path(__file__).resolve().parents[1]
RECORDS = []


def run(label, command, project, input_text=None, expected=0):
    print(label, flush=True)
    result = fp_game.execute(command, project, timeout=300, input_text=input_text)
    record = {'check': label, 'exit_code': result['exit_code'], 'expected_exit_code': expected,
              'stdout_sha256': hashlib.sha256(result['stdout'].encode()).hexdigest()}
    RECORDS.append(record)
    state = ROOT / '.build' / 'workspace-logs'
    state.mkdir(parents=True, exist_ok=True)
    (state / (label + '.json')).write_text(json.dumps(result, indent=2), encoding='utf-8')
    if result['exit_code'] != expected:
        raise RuntimeError(f'{label} failed; inspect the project-local .build/workspace-logs record')
    return result['stdout']


def cabal(project, action, *extras, input_text=None, label=None):
    command = [shutil.which('cabal'), '--config-file=build.config', action]
    command += ['all'] if action in {'build', 'test'} else ['acceptance-game']
    command += ['--offline', '--builddir=.build/dist']
    if action == 'test':
        command += ['--test-show-details=direct']
    command += list(extras)
    return run(label or action, command, project, input_text)


def require(label, condition):
    if not condition:
        raise RuntimeError(label)
    RECORDS.append({'check': label, 'status': 'pass'})


def check_public_model_api(game):
    """Compile both sides of the generated read-only Model contract."""
    ghc = shutil.which('ghc')
    require('api-compiler-present', ghc is not None)
    output = game / '.build' / 'api-check'
    output.mkdir(parents=True, exist_ok=True)
    good = output / 'ReadModel.hs'
    bad = output / 'RejectModelUpdate.hs'
    good.write_text('module ReadModel where\nimport Game.Model\nreadPosition :: (Int, Int)\nreadPosition = coordinates (position initial)\n', encoding='utf-8')
    bad.write_text('module RejectModelUpdate where\nimport Game.Model\nforged :: World\nforged = initial { position = position initial }\n', encoding='utf-8')
    flags = [ghc, '-fno-code', '-fforce-recomp', '-XGHC2021',
             '-fdiagnostics-color=never', '-i' + str(game / 'src'),
             '-outputdir', str(output)]
    run('public-model-read', [*flags, str(good)], game)
    rejection = fp_game.execute([*flags, str(bad)], game, timeout=90)
    (output / 'RejectModelUpdate.json').write_text(json.dumps(rejection, indent=2), encoding='utf-8')
    require('public-model-update-rejected-for-selector',
            rejection['exit_code'] != 0 and 'position' in rejection['stderr']
            and 'is not a record selector' in rejection['stderr'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, default=ROOT / '.build/development-report.json')
    args = parser.parse_args()
    temporary_root = Path(tempfile.gettempdir()).resolve()
    trial = Path(tempfile.mkdtemp(prefix='FP game development ', dir=temporary_root)).resolve()
    require('independent-space-path', trial.is_relative_to(temporary_root) and not trial.is_relative_to(ROOT) and ' ' in trial.name)
    game = trial / 'first user game'
    cli = [sys.executable, str(ROOT / 'tools/fp_game.py')]
    parameters = ['acceptance-game', str(game), '--title', 'Independent game']
    run('doctor', [*cli, 'doctor', '--json'], ROOT)
    run('plan', [*cli, 'plan', *parameters, '--json'], ROOT)
    run('dry-run', [*cli, 'scaffold', *parameters, '--dry-run', '--json'], ROOT)
    require('dry-run-created-nothing', not game.exists())
    run('scaffold', [*cli, 'scaffold', *parameters, '--json'], ROOT)
    snapshot = (game / 'scaffold-manifest.json').read_bytes()
    run('existing-directory-refused', [*cli, 'scaffold', *parameters, '--json'], ROOT, expected=1)
    require('existing-directory-preserved', snapshot == (game / 'scaffold-manifest.json').read_bytes())
    require('separate-game-license', not (game / 'LICENSE').exists() and (game / 'LICENSE.game.txt').exists())
    require('continuation-skill-local', (game / '.agents/skills/game-dev/SKILL.md').is_file())
    lock = json.loads((game / 'foundation.lock.json').read_text())
    require('kernel-versions-pinned', lock['packages'] == {'game-transition': '0.1.0.0', 'game-arena': '0.1.0.0'})
    require('vendored-kernel-identity', all(hashlib.sha256((game / name).read_bytes()).hexdigest() == value for name, value in lock['sha256_lf'].items()))
    check_public_model_api(game)
    cabal(game, 'build', label='baseline-build')
    cabal(game, 'test', label='baseline-tests')
    require('baseline-runtime', 'gameplay/save smoke: PASS' in cabal(game, 'run', '--', '--smoke', label='baseline-smoke'))
    add_key(game)
    require('development-not-regeneration', (game / 'scaffold-manifest.json').read_bytes() == snapshot)
    cabal(game, 'test', label='key-tests')
    locked = cabal(game, 'run', input_text='east\neast\nsouth\nexit\nquit\n', label='key-locked-runtime')
    require('locked-runtime-visible', 'The exit is locked' in locked and 'You escaped.' not in locked)
    unlocked = cabal(game, 'run', input_text='south\nsave\nsave\nload\neast\neast\nexit\nquit\n', label='key-unlocked-runtime')
    require('collect-unlock-save-load', all(text in unlocked for text in ['Collected the key.', 'Saved.', 'Loaded.', 'You escaped.']))
    relocated = trial / 'isolated continued game'
    require('copy-target-new-and-independent', not relocated.exists() and relocated.parent == trial and not relocated.is_relative_to(ROOT))
    shutil.copytree(game, relocated, ignore=shutil.ignore_patterns('.build', 'dist-newstyle', '__pycache__'))
    require('copied-without-build-cache', not (relocated / '.build').exists())
    cabal(relocated, 'build', label='isolated-build')
    cabal(relocated, 'test', label='isolated-tests')
    require('isolated-runtime', 'gameplay/save smoke: PASS' in cabal(relocated, 'run', '--', '--smoke', label='isolated-smoke'))
    run('local-cli-run', [sys.executable, 'tools/fp_game.py', 'run', '--smoke', '--json'], relocated)
    run('local-continuation-cli', [sys.executable, 'tools/fp_game.py', 'context', 'src/Game/Rules.hs', '--symbol', 'advance', '--json'], relocated)
    add_stamina(relocated)
    require('second-feature-without-regeneration', (relocated / 'scaffold-manifest.json').read_bytes() == snapshot)
    cabal(relocated, 'test', label='stamina-tests')
    continued = cabal(relocated, 'run', input_text='south\neast\nnorth\neast\nrest\neast\nrest\nsouth\nexit\nquit\n', label='stamina-runtime')
    require('second-mechanic-visible', all(text in continued for text in ['Too tired to move.', 'Rested to recover stamina.', 'You escaped.']))
    require('prior-save-not-silently-migrated', 'UnsupportedFormat' in cabal(relocated, 'run', input_text='load\nquit\n', label='save-migration-contract'))
    environment = fp_game.doctor(ROOT)
    inputs = [p for base in ['templates', 'libraries'] for p in (ROOT / base).rglob('*') if p.is_file()]
    inputs += [ROOT / 'tools' / name for name in ['fp_game.py', 'scaffold.py', 'test_workspace.py', 'acceptance/features.py']]
    report = {'schema': 1, 'status': 'pass', 'scope': 'Generated independent terminal game: actual key edit, relocation, actual stamina edit; standard Cabal; saved-source CLI. No editor session, graphical route or manual fun evaluation.',
              'environment': {name: environment[name] for name in ['os', 'architecture', 'python']},
              'input_sha256_lf': {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest() for path in sorted(inputs)},
              'checks': RECORDS}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('independent game development acceptance: PASS')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
