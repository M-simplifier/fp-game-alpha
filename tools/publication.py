"""Create a reviewable manifest or check selected source before publication.

Uses only local Git and Python's standard library. Scan results report locations
and rule names, never a matched credential value. The manifest is an explicit
selection contract; creating it does not establish third-party ownership.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'PUBLICATION-MANIFEST.json'
HEADER = {
    'schema': 2,
    'digest_format': 'SHA256 of UTF-8 source with LF newlines',
    'self_hash': 'manifest excluded to avoid recursive hash',
    'selection_policy': 'publication/policy.json',
    'provenance': 'publication/provenance.json',
    'default_origin': {'kind': 'authored-for-public-alpha'},
    'export': 'selected',
    'review': 'explicit technical selection; license notice reviewed',
}


def selected_files():
    command = ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'ls-files', '-z',
               '--cached', '--others', '--exclude-standard']
    result = subprocess.run(command, cwd=ROOT, capture_output=True, check=True)
    return sorted(set(name for name in result.stdout.decode('utf-8').split('\0') if name))


def source_path(name):
    """Reject noncanonical/escaping names and links before opening any source."""
    if (not isinstance(name, str) or not name or '\\' in name or ':' in name
            or any(part in {'', '.', '..'} for part in name.split('/'))):
        raise ValueError('Noncanonical source path')
    path = ROOT
    for part in name.split('/'):
        path /= part
        if path.is_symlink():
            raise ValueError('Linked source path')
    return path


def read_json(name):
    def unique_keys(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f'Duplicate JSON key in {name}')
            value[key] = item
        return value
    return json.loads(source_path(name).read_text(encoding='utf-8'),
                      object_pairs_hook=unique_keys)


def canonical(path):
    return path.read_bytes().replace(b'\r\n', b'\n')


def digest(path):
    return hashlib.sha256(canonical(path)).hexdigest()


def metadata(name, policy):
    matches = [rule for rule in policy['selections'] if name.startswith(rule['prefix'])]
    if not matches:
        raise ValueError(f'No reviewed selection rule: {name}')
    return max(matches, key=lambda rule: len(rule['prefix']))


def snapshot():
    policy = read_json(HEADER['selection_policy'])
    records = []
    for name in sorted(set(selected_files()) | {MANIFEST}):
        metadata(name, policy)
        records.append({'path': name, 'sha256_lf': None if name == MANIFEST
                        else digest(source_path(name))})
    value = dict(HEADER, files=records)
    source_path(MANIFEST).write_text(json.dumps(value, ensure_ascii=False, indent=1) + '\n',
                                    encoding='utf-8', newline='\n')
    print(f'Wrote review candidate: {MANIFEST} ({len(records)} files)')


def read_manifest():
    manifest = read_json(MANIFEST)
    if (not isinstance(manifest, dict) or type(manifest.get('schema')) is not int
            or set(manifest) != set(HEADER) | {'files'}
            or any(manifest[key] != value for key, value in HEADER.items())):
        raise ValueError('Unsupported publication manifest contract')
    records = manifest['files']
    if not isinstance(records, list):
        raise ValueError('Manifest files must be a sorted list')
    for record in records:
        if not isinstance(record, dict) or set(record) != {'path', 'sha256_lf'}:
            raise ValueError('Malformed manifest file record')
        source_path(record['path'])
        value = record['sha256_lf']
        valid = value is None if record['path'] == MANIFEST else (
            isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value))
        if not valid:
            raise ValueError('Invalid manifest source digest')
    names = [record['path'] for record in records]
    if names != sorted(set(names)):
        raise ValueError('Manifest paths must be sorted and unique')
    expected = {record['path']: record for record in records}
    if MANIFEST not in expected:
        raise ValueError('Manifest must select itself')
    # Authenticate the canonical metadata before trusting its defaults or rules.
    # A removed legacy origin or weakened policy cannot hide behind a fallback.
    for name in (HEADER['selection_policy'], HEADER['provenance']):
        if name not in expected or digest(source_path(name)) != expected[name]['sha256_lf']:
            raise ValueError(f'Manifest metadata digest mismatch: {name}')
    return expected


def scan_text(text, policy):
    patterns = {
        'credential-token': r'(?:gh[pousr]_' + r'[A-Za-z0-9]{30,}|github_pat_' + r'[A-Za-z0-9_]{30,}|xox[baprs]-' + r'[A-Za-z0-9-]{15,}|AKIA' + r'[A-Z0-9]{16})',
        'private-key': r'-----BEGIN ' + r'(?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        'personal-absolute-path': r'(?:[A-Za-z]:[/\\]' + r'Users[/\\]|/(?:home|Users|root)/)[^\s"\'<>]+',
        'private-host': r'https?://' + r'(?:localhost|127\.0\.0\.1|10\.[0-9.]+|192\.168\.[0-9.]+)(?::\d+)?/',
    }
    failures = []
    for label, pattern in patterns.items():
        for found in re.finditer(pattern, text):
            failures.append({'rule': label, 'line': text.count('\n', 0, found.start()) + 1})
    for found in re.finditer(r"https?://(?:github\.com|raw\.githubusercontent\.com)/([^/\s\"'<>`]+)/([^/\s)#?\"'<>`]+)", text):
        repository = '/'.join(found.groups()).rstrip('.,').removesuffix('.git')
        if repository not in policy['public_repository_links']:
            failures.append({'rule': 'undeclared-repository-link', 'line': text.count('\n', 0, found.start()) + 1})
    return failures


def gate(report_path):
    expected = read_manifest()
    policy = read_json(HEADER['selection_policy'])
    provenance = read_json(HEADER['provenance'])
    if not isinstance(provenance, dict):
        raise ValueError('Malformed provenance inventory')
    actual = set(selected_files())
    problems = []
    if set(expected) != actual:
        problems.append({'rule': 'manifest-file-set', 'missing': sorted(actual - set(expected)),
                         'stale': sorted(set(expected) - actual)})
    inspection = []
    forbidden = {'.git', '.codex', '.aws', 'node_modules', 'AGENTS.md', '.env'}
    for name in sorted(actual):
        path = source_path(name)
        issues = []
        if any(part in forbidden for part in Path(name).parts):
            issues.append({'rule': 'internal-or-linked-file'})
        if '.agents' in Path(name).parts and name not in policy.get('authored_public_skills', []):
            issues.append({'rule': 'unreviewed-agent-content'})
        if not path.is_file():
            issues.append({'rule': 'not-regular-file'})
        elif path.stat().st_size > policy['max_source_bytes']:
            issues.append({'rule': 'large-source-file'})
        else:
            try:
                text = canonical(path).decode('utf-8')
                if '\0' in text:
                    issues.append({'rule': 'binary-asset'})
                issues.extend(scan_text(text, policy))
            except UnicodeDecodeError:
                issues.append({'rule': 'binary-or-unknown-encoding'})
        record = expected.get(name)
        if record is not None:
            if name != MANIFEST and path.is_file() and digest(path) != record['sha256_lf']:
                issues.append({'rule': 'manifest-digest'})
            origin = provenance.get(name, HEADER['default_origin'])
            if not isinstance(origin, dict) or not isinstance(origin.get('kind'), str) or not origin['kind']:
                issues.append({'rule': 'missing-origin-or-license'})
            try:
                rule = metadata(name, policy)
            except ValueError:
                issues.append({'rule': 'unreviewed-selection'})
            else:
                if rule['maturity'] not in {'completed', 'experimental', 'blocked'}:
                    issues.append({'rule': 'invalid-disposition'})
                if rule['license'] not in expected or not source_path(rule['license']).is_file():
                    issues.append({'rule': 'missing-origin-or-license'})
        inspection.append({'path': name, 'status': 'FAIL' if issues else 'PASS', 'checks': issues})
    ok = not problems and all(row['status'] == 'PASS' for row in inspection)
    report = {'schema': 1, 'status': 'PASS' if ok else 'FAIL',
              'scope': 'current selected files, explicit licenses, source hashes and bounded pattern scan',
              'manifest_sha256': digest(ROOT / MANIFEST), 'problems': problems, 'files': inspection}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8', newline='\n')
    for row in inspection:
        if row['checks']:
            print(f"FAIL {row['path']}: " + ', '.join(issue['rule'] for issue in row['checks']))
    for problem in problems:
        print(json.dumps(problem))
    print(f"export gate: {report['status']} ({len(inspection)} files; report {report_path.relative_to(ROOT)})")
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['snapshot', 'check'])
    parser.add_argument('--report', type=Path, default=ROOT / '.build/export-report.json')
    args = parser.parse_args()
    try:
        if args.action == 'snapshot':
            snapshot()
            return 0
        return gate(args.report)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'Publication check failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
