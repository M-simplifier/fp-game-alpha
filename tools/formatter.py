"""Pinned, project-local Ormolu. Only install downloads; check never writes source."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MAX_BINARY = 128 * 1024 * 1024
PROTECTED = {'vendor', 'oracle', 'oracles', 'fixture', 'fixtures', 'node_modules',
             '.git', '.build', '.runtime', 'dist-newstyle'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def local_path(project, relative):
    """Reject links and traversal before any cache or source access."""
    parts = PurePosixPath(relative).parts
    if (not parts or '\\' in relative or ':' in relative or relative.startswith('/')
            or '..' in parts or any(part.endswith((' ', '.')) for part in parts)):
        raise ValueError('Expected a project-relative path without traversal.')
    path = project
    for part in parts:
        path = path / part
        if path.is_symlink() or getattr(path, 'is_junction', lambda: False)():
            raise ValueError('Refusing a symlink or junction: ' + relative)
    if not path.resolve().is_relative_to(project.resolve()):
        raise ValueError('Path escapes the project.')
    return path


def profile_key():
    machine = platform.machine().lower()
    machine = {'amd64': 'x86_64', 'aarch64': 'arm64'}.get(machine, machine)
    return platform.system() + '-' + machine


def metadata(project):
    lock = json.loads(local_path(project, 'tools/formatter.lock.json').read_text(encoding='utf-8'))
    version = lock['version']
    if lock['schema'] != 1 or not re.fullmatch(r'\d+(?:\.\d+){3}', version):
        raise ValueError('Invalid formatter version lock.')
    key = profile_key()
    if key not in lock['profiles']:
        raise ValueError('No pinned Ormolu archive for ' + key + '; no fallback installation attempted.')
    item = lock['profiles'][key]
    expected_url = 'https://github.com/tweag/ormolu/releases/download/' + version + '/' + item['asset']
    if item['url'] != expected_url or not re.fullmatch(r'ormolu-[a-z0-9_-]+\.zip', item['asset']):
        raise ValueError('Formatter archive must be a pinned official Ormolu release.')
    if not re.fullmatch('[a-f0-9]{64}', item['sha256']) or not 0 < item['bytes'] < MAX_BINARY:
        raise ValueError('Invalid formatter archive size or checksum.')
    return version, key, item


def archive_payloads(data, item, executable):
    if len(data) != item['bytes'] or digest(data) != item['sha256']:
        raise ValueError('Formatter archive size/checksum mismatch; nothing installed.')
    members = item.get('members', [executable])
    if (not isinstance(members, list) or executable not in members
            or any(not isinstance(name, str) or not re.fullmatch(r'ormolu(?:\.exe)?|lib[a-zA-Z0-9_.-]+\.dylib', name) for name in members)
            or len(members) != len(set(members))):
        raise ValueError('Invalid pinned formatter archive member list.')
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            # macOS arm64 also needs the four pinned sibling dylibs. Never
            # extract arbitrary paths, links, extra files or duplicate members.
            entries = archive.infolist()
            if len(entries) != len(members) or {entry.filename for entry in entries} != set(members):
                raise ValueError('Expected exactly the pinned formatter archive members.')
            total_size = 0
            for entry in entries:
                mode = entry.external_attr >> 16
                if entry.is_dir() or stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG):
                    raise ValueError('Formatter archive contains a non-regular member.')
                total_size += entry.file_size
                if entry.file_size <= 0 or total_size > MAX_BINARY or entry.flag_bits & 1:
                    raise ValueError('Formatter archive has an invalid expanded size or encryption.')
            return {entry.filename: archive.read(entry) for entry in entries}
    except (zipfile.BadZipFile, RuntimeError) as error:
        raise ValueError('Malformed formatter archive: ' + str(error)) from error


def locations(project, version, key):
    folder = '.build/tools/ormolu/' + version + '/' + key
    executable = 'ormolu.exe' if key.startswith('Windows-') else 'ormolu'
    return local_path(project, folder), executable


def check_version(executable, version, project):
    result = subprocess.run([str(executable), '--version'], cwd=project,
                            capture_output=True, text=True, timeout=30)
    if result.returncode or not re.match(r'^ormolu ' + re.escape(version) + r'(?:\s|$)', result.stdout):
        raise ValueError('Installed formatter version does not match the lock.')


def verified(project):
    version, key, item = metadata(project)
    folder, name = locations(project, version, key)
    archive = local_path(project, (folder / 'archive.zip').relative_to(project).as_posix())
    executable = local_path(project, (folder / name).relative_to(project).as_posix())
    if not archive.is_file() or not executable.is_file():
        if folder.exists():
            raise ValueError('Incomplete formatter cache at ' + str(folder)
                             + '. Inspect it, remove only this project-local folder, then run: python tools/formatter.py install')
        raise ValueError('Pinned formatter is missing. Run: python tools/formatter.py install')
    if archive.stat().st_size != item['bytes'] or not 0 < executable.stat().st_size <= MAX_BINARY:
        raise ValueError('Cached formatter size differs from the lock or exceeds its limit.')
    payloads = archive_payloads(archive.read_bytes(), item, name)
    for member, expected in payloads.items():
        path = local_path(project, (folder / member).relative_to(project).as_posix())
        if not path.is_file():
            raise ValueError('Incomplete formatter cache at ' + str(folder)
                             + '. Inspect it, remove only this project-local folder, then run: python tools/formatter.py install')
        if path.stat().st_size != len(expected) or digest(path.read_bytes()) != digest(expected):
            raise ValueError('Cached formatter payload differs from the verified archive; remove this project-local cache and install again.')
    check_version(executable, version, project)
    return executable


def install(project):
    version, key, item = metadata(project)
    folder, name = locations(project, version, key)
    if folder.exists():
        return {'status': 'reused', 'path': str(verified(project)), 'exit_code': 0}
    # Bounded download, no shell or global installer. Verify before writing or running.
    request = urllib.request.Request(item['url'], headers={'User-Agent': 'fp-game-formatter'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(item['bytes'] + 1)
    payloads = archive_payloads(data, item, name)
    folder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='install-', dir=folder.parent) as temporary:
        stage = Path(temporary) / 'ready'
        stage.mkdir()
        (stage / 'archive.zip').write_bytes(data)
        for member, payload in payloads.items():
            output = stage / member
            output.write_bytes(payload)
            output.chmod(0o755)
        executable = stage / name
        check_version(executable, version, project)
        # Another installation must not be overwritten.
        stage.rename(folder)
    return {'status': 'installed', 'path': str(verified(project)), 'exit_code': 0}


def source_files(project):
    config = json.loads(local_path(project, 'formatter.json').read_text(encoding='utf-8'))
    roots = config['source_roots']
    if config['schema'] != 1 or not isinstance(roots, list) or not roots:
        raise ValueError('Formatter config needs explicit owned source_roots.')
    files = set()
    for root in roots:
        if not isinstance(root, str) or root in ('', '.') or any(p.lower() in PROTECTED for p in PurePosixPath(root).parts):
            raise ValueError('Formatter root must be an owned source directory, never vendor/oracle/fixtures.')
        directory = local_path(project, root)
        if any(p.lower() in PROTECTED for p in directory.resolve().relative_to(project).parts):
            raise ValueError('Formatter root resolves to a protected source directory.')
        if not directory.is_dir():
            raise ValueError('Formatter source directory is missing: ' + root)
        for path in directory.rglob('*'):
            relative = path.relative_to(project)
            if any(p.lower() in PROTECTED for p in relative.parts):
                continue
            checked = local_path(project, relative.as_posix())
            if checked.is_file() and checked.suffix == '.hs':
                if checked.stat().st_nlink != 1:
                    raise ValueError('Refusing a hard-linked Haskell source: ' + relative.as_posix())
                files.add(checked)
    if not files:
        raise ValueError('No owned Haskell sources found; refusing an empty success.')
    return sorted(files)


def perform(action, project):
    if action not in {'plan', 'install', 'path', 'check', 'write'}:
        raise ValueError('Unknown formatter action; no changes made.')
    project = project.resolve()
    version, key, item = metadata(project)
    if action == 'plan':
        folder, name = locations(project, version, key)
        return {'status': 'planned', 'exit_code': 0, 'version': version, 'platform': key,
                'download': item, 'path': str(folder / name), 'mutates': False,
                'sources': [p.relative_to(project).as_posix() for p in source_files(project)]}
    if action == 'install':
        return install(project)
    executable = verified(project)
    if action == 'path':
        return {'status': 'verified', 'exit_code': 0, 'path': str(executable)}
    files = source_files(project)
    results = []
    for path in files:
        result = subprocess.run([str(executable), '--mode', 'check' if action == 'check' else 'inplace',
                                 '--check-idempotence', '--ghc-opt=-XGHC2021', str(path)],
                                cwd=project, capture_output=True, text=True, timeout=60)
        results.append({'file': path.relative_to(project).as_posix(), 'exit_code': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr})
    failed = any(r['exit_code'] for r in results)
    return {'status': 'failed' if failed else 'ok', 'exit_code': 1 if failed else 0,
            'version': version, 'mode': action, 'files': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'install', 'path', 'check', 'write'])
    parser.add_argument('--project', type=Path, default=ROOT)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        result = perform(args.action, args.project)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result = {'status': 'error', 'exit_code': 1, 'error': str(error)}
    if args.action == 'path' and not args.json and result['exit_code'] == 0:
        print(result['path'])
    else:
        print(json.dumps(result, indent=2))
    return result['exit_code']


if __name__ == '__main__':
    sys.exit(main())
