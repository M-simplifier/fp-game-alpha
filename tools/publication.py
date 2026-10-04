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


def selected_files():
    command = ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'ls-files', '-z',
               '--cached', '--others', '--exclude-standard']
    result = subprocess.run(command, cwd=ROOT, capture_output=True, check=True)
    return sorted(set(name for name in result.stdout.decode('utf-8').split('\0') if name))


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
    policy = json.loads((ROOT / 'publication/policy.json').read_text(encoding='utf-8'))
    provenance = json.loads((ROOT / 'publication/provenance.json').read_text(encoding='utf-8'))
    records = []
    for name in sorted(set(selected_files()) | {MANIFEST}):
        rule = metadata(name, policy)
        records.append({
            'path': name, 'sha256_lf': None if name == MANIFEST else digest(ROOT / name),
            'origin': provenance.get(name, {'kind': 'authored-for-public-alpha'}),
            'license': rule['license'], 'maturity': rule['maturity'],
            'export': 'selected', 'review': 'explicit technical selection; license notice reviewed',
        })
    value = {'schema': 1, 'digest_format': 'SHA256 of UTF-8 source with LF newlines',
             'self_hash': 'manifest excluded to avoid recursive hash', 'files': records}
    (ROOT / MANIFEST).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(f'Wrote review candidate: {MANIFEST} ({len(records)} files)')


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
    policy = json.loads((ROOT / 'publication/policy.json').read_text(encoding='utf-8'))
    manifest = json.loads((ROOT / MANIFEST).read_text(encoding='utf-8'))
    records = manifest['files']
    expected = {record['path']: record for record in records}
    actual = set(selected_files())
    problems = []
    if len(expected) != len(records):
        problems.append({'rule': 'duplicate-manifest-path'})
    if set(expected) != actual:
        problems.append({'rule': 'manifest-file-set', 'missing': sorted(actual - set(expected)),
                         'stale': sorted(set(expected) - actual)})
    inspection = []
    forbidden = {'.git', '.codex', '.agents', '.aws', 'node_modules', 'AGENTS.md', '.env'}
    for name in sorted(actual):
        path = ROOT / name
        issues = []
        if any(part in forbidden for part in Path(name).parts) or path.is_symlink():
            issues.append({'rule': 'internal-or-linked-file'})
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
            if record['export'] != 'selected' or record['maturity'] not in {'completed', 'experimental', 'blocked'}:
                issues.append({'rule': 'invalid-disposition'})
            if not record.get('origin') or not (ROOT / record['license']).is_file():
                issues.append({'rule': 'missing-origin-or-license'})
            if name != MANIFEST and path.is_file() and digest(path) != record['sha256_lf']:
                issues.append({'rule': 'manifest-digest'})
            try:
                rule = metadata(name, policy)
                if any(record[key] != rule[key] for key in ('license', 'maturity')):
                    issues.append({'rule': 'selection-metadata'})
            except ValueError:
                issues.append({'rule': 'unreviewed-selection'})
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
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Publication check failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
