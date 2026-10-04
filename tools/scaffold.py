"""Prepare and create a new independent game; never regenerate existing work."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = 'terminal-adventure'


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def source_revision():
    result = subprocess.run(['git', '-c', f'safe.directory={ROOT.as_posix()}', 'rev-parse', 'HEAD'],
                            cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def source_state():
    result = subprocess.run(['git', '-c', f'safe.directory={ROOT.as_posix()}', 'status', '--porcelain'],
                            cwd=ROOT, capture_output=True, text=True)
    return ('modified-checkout' if result.stdout.strip() else 'clean-commit') if result.returncode == 0 else 'no-git-metadata'


def prepare(slug, destination, title, target, rendering, license_choice, author):
    if not re.fullmatch(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*', slug) or len(slug) > 64 or any(not re.search('[a-z]', part) for part in slug.split('-')) or slug in {'base', 'game-transition', 'game-arena'}:
        raise ValueError('Use a lowercase Cabal slug, such as my-adventure.')
    if any(ord(character) < 32 for character in title) or len(title) > 120:
        raise ValueError('Title must be one line of at most 120 characters.')
    if (target, rendering) != ('native', 'terminal'):
        raise ValueError('This alpha scaffold currently implements native/terminal. Other renderer/target routes require explicit development; no substitute is generated.')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Scaffold refuses every existing destination, including empty directories.')
    destination = destination.resolve()
    if destination.is_relative_to(ROOT) and not destination.is_relative_to(ROOT / 'generated-games') and not destination.is_relative_to(ROOT / '.build'):
        raise ValueError('Choose an independent directory outside the starter checkout, or generated-games/.')
    template = ROOT / 'templates' / TEMPLATE
    if not template.is_dir():
        raise ValueError('This game already owns its editable source. Continue development here; templates are available only in the starter checkout.')
    if license_choice == 'MIT' and not author:
        raise ValueError('An MIT game license needs an explicit author/credit name.')
    if author and (any(ord(character) < 32 for character in author) or len(author) > 120):
        raise ValueError('Author must be one line of at most 120 characters.')
    game_license = 'not chosen; no license granted for your additions' if license_choice == 'unlicensed' else 'MIT'
    substitutions = {'SLUG': slug, 'TITLE': title, 'GAME_LICENSE': game_license,
                     'CABAL_LICENSE': 'NONE' if license_choice == 'unlicensed' else 'MIT'}
    files = {}
    for path in sorted(template.rglob('*')):
        if not path.is_file():
            continue
        name = path.relative_to(template).as_posix()
        if name == 'game.cabal.tmpl':
            name = slug + '.cabal'
        elif name == 'skills/game-dev/SKILL.md.tmpl':
            name = '.agents/skills/game-dev/SKILL.md'
        elif name.endswith('.tmpl'):
            name = name[:-5]
        text = path.read_text(encoding='utf-8')
        for key, value in substitutions.items():
            text = text.replace('{{' + key + '}}', value)
        files[name] = text.replace('\r\n', '\n').encode('utf-8')
    foundation_files = {}
    for package in ['game-transition', 'game-arena']:
        base = ROOT / 'libraries' / package
        for path in sorted(base.rglob('*')):
            if path.is_file() and (path.suffix == '.hs' or path.suffix == '.cabal' or path.name == 'LICENSE'):
                name = 'vendor/' + package + '/' + path.relative_to(base).as_posix()
                files[name] = path.read_bytes().replace(b'\r\n', b'\n')
                foundation_files[name] = sha256(files[name])
    for source in ['architecture.md', 'haskell.md', 'failure-prevention.md', 'editors.md', 'verification.md']:
        path = ROOT / 'docs' / source
        files['docs/' + source] = path.read_bytes().replace(b'\r\n', b'\n')
        foundation_files['docs/' + source] = sha256(files['docs/' + source])
    for path in sorted((ROOT / 'docs/evidence').glob('*.json')):
        name = path.relative_to(ROOT).as_posix()
        files[name] = path.read_bytes().replace(b'\r\n', b'\n')
        foundation_files[name] = sha256(files[name])
    for path in sorted((ROOT / 'editors').rglob('*')):
        if path.is_file() and 'test' not in path.parts and path.name not in {'test.lua'}:
            name = path.relative_to(ROOT).as_posix()
            files[name] = path.read_bytes().replace(b'\r\n', b'\n')
            foundation_files[name] = sha256(files[name])
    for name in ['fp_game.py', 'scaffold.py', 'toolchains.json']:
        files['tools/' + name] = (ROOT / 'tools' / name).read_bytes().replace(b'\r\n', b'\n')
        foundation_files['tools/' + name] = sha256(files['tools/' + name])
    files['licenses/FOUNDATION-MIT.txt'] = (ROOT / 'LICENSE').read_bytes().replace(b'\r\n', b'\n')
    files['NOTICE.md'] = (
        '# License scope\n\nThe original template and foundation source represented by the initial scaffold hashes retain their MIT notices in licenses/ and vendor/. '
        'Your subsequent game code, content and assets are yours; their license is a separate decision. '
        'The game license selection is: ' + game_license + '.\n'
    ).encode('utf-8')
    if license_choice == 'MIT':
        text = files['licenses/FOUNDATION-MIT.txt'].decode('utf-8')
        files['LICENSE'] = text.replace('2026 Masaya Shirasawa', '2026 ' + author).encode('utf-8')
    else:
        files['LICENSE.game.txt'] = b'No game license has been chosen. No license is granted for your additions by this file. Foundation and original template notices remain separate.\n'
    files['.gitignore'] = b'.build/\ndist-newstyle/\n__pycache__/\n*.hi\n*.o\n*.exe\ndata/\n'
    files['.gitattributes'] = b'* text=auto eol=lf\n'
    config = {'schema': 1, 'slug': slug, 'template': TEMPLATE, 'target': target, 'rendering': rendering,
              'source_dirs': ['src', 'vendor/game-transition/src', 'vendor/game-arena/src'],
              'default_executable': slug, 'game_license': license_choice}
    files['fp-game.json'] = (json.dumps(config, indent=2) + '\n').encode('utf-8')
    lock = {'schema': 1, 'upstream': 'https://github.com/M-simplifier/fp-game-alpha',
            'upstream_commit': source_revision(), 'distribution': 'vendored-source',
            'source_state': source_state(),
            'packages': {'game-transition': '0.1.0.0', 'game-arena': '0.1.0.0'}, 'sha256_lf': foundation_files}
    files['foundation.lock.json'] = (json.dumps(lock, indent=2) + '\n').encode('utf-8')
    files['hie.yaml'] = b'cradle:\n  cabal:\n'
    workflow = (
        'name: game-checks\non: [push, pull_request]\npermissions:\n  contents: read\njobs:\n'
        '  game:\n    strategy:\n      matrix:\n        os: [windows-latest, ubuntu-latest, macos-latest]\n'
        '    runs-on: ${{ matrix.os }}\n    steps:\n'
        '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262\n'
        '      - uses: haskell-actions/setup@0f8e8c99d88aeb3fbfd523f1ef2c6f762d10d64d\n'
        '        with:\n          ghc-version: \'9.6.7\'\n          cabal-version: \'3.12.1.0\'\n          cabal-update: false\n'
        '      - run: cabal --config-file=build.config build all --offline --builddir=.build/dist\n'
        '      - run: cabal --config-file=build.config test all --offline --builddir=.build/dist --test-show-details=direct\n'
        '      - run: cabal --config-file=build.config run ' + slug + ' --offline --builddir=.build/dist -- --smoke\n'
    )
    files['.github/workflows/game.yml'] = workflow.encode('utf-8')
    manifest = {'schema': 1, 'template_version': '0.1.0', 'files': {name: sha256(content) for name, content in sorted(files.items())},
                'scope': 'Initial scaffold identity. User edits are expected; never regenerate to upgrade.'}
    files['scaffold-manifest.json'] = (json.dumps(manifest, indent=2) + '\n').encode('utf-8')
    return destination, files


def plan(arguments):
    destination, files = prepare(arguments.name, arguments.destination, arguments.title or arguments.name,
                                 arguments.target, arguments.rendering, arguments.license, arguments.author)
    from fp_game import baseline_downloads
    return {'status': 'planned', 'exit_code': 0, 'destination': str(destination),
            'template': TEMPLATE, 'target': arguments.target, 'rendering': arguments.rendering,
            'game_license': arguments.license, 'files': {name: sha256(content) for name, content in sorted(files.items())},
            'baseline_downloads': baseline_downloads(),
            'prerequisites': {'python_minimum': '3.12', 'ghc_baseline': '9.6.7', 'cabal_baseline': '3.12.1.0',
                              'dependencies': 'only packages bundled with GHC; vendored kernels',
                              'network': 'compiler installation if missing; none for this build profile',
                              'graphics': 'terminal only; no renderer or artwork download',
                              'installation': 'explicit; see docs/setup.md'},
            'mutates': False, 'next': 'scaffold, then build/test/run and implement the agreed game mechanic'}


def scaffold(arguments):
    destination, files = prepare(arguments.name, arguments.destination, arguments.title or arguments.name,
                                 arguments.target, arguments.rendering, arguments.license, arguments.author)
    if arguments.dry_run:
        return plan(arguments)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive reservation preserves a directory that appears concurrently.
    destination.mkdir(exist_ok=False)
    marker = destination / '.scaffold-incomplete'
    marker.write_text('Scaffolding has not completed.\n')
    for name, content in files.items():
        path = destination / name
        if not path.resolve().is_relative_to(destination):
            raise ValueError('Generated path escaped the new project')
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as handle:
            handle.write(content)
    marker.unlink()
    return {'status': 'created', 'exit_code': 0, 'destination': str(destination),
            'files': len(files), 'next': 'Enter the game directory; build/test/play, then continue with $game-dev.'}
