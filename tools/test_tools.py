"""Behavioral checks for publication rejection and actual compiler queries."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
from unittest.mock import patch

import unittest

import inspect_haskell
import publication


class ExportScan(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((publication.ROOT / 'publication/policy.json').read_text())

    def test_repository_source_limit_is_512_kib(self):
        self.assertEqual(self.policy['max_source_bytes'], 524288)

    def test_known_token_is_rejected_without_echoing_value(self):
        token = 'ghp_' + 'a' * 36
        result = publication.scan_text(token, self.policy)
        self.assertEqual(result[0]['rule'], 'credential-token')
        self.assertNotIn(token, json.dumps(result))

    def test_personal_path_is_rejected(self):
        value = 'C:' + '/' + 'Users/example/private.txt'
        self.assertTrue(publication.scan_text(value, self.policy))

    def test_undeclared_repository_is_rejected(self):
        value = 'https://github.com/' + 'private-owner/private-project/blob/main/file'
        self.assertEqual(publication.scan_text(value, self.policy)[0]['rule'], 'undeclared-repository-link')

    def test_public_clone_suffix_is_normalized(self):
        value = 'https://github.com/M-simplifier/fp-game-alpha.git'
        self.assertEqual(publication.scan_text(value, self.policy), [])


class PublicationGate(unittest.TestCase):
    """Exercise the real Git selection, snapshot and gate with tiny source files."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='publication-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        root_patch = patch.object(publication, 'ROOT', self.root)
        self.addCleanup(root_patch.stop)
        root_patch.start()
        self.policy = {
            'schema': 1, 'max_source_bytes': 524288, 'public_repository_links': [],
            'selections': [{'prefix': '', 'license': 'LICENSE', 'maturity': 'experimental'}],
        }
        self.provenance = {'source.txt': {'kind': 'selected-legacy-source', 'origin': 'original.txt'}}
        (self.root / 'publication').mkdir()
        (self.root / '.gitignore').write_text('.build/\n')
        (self.root / 'LICENSE').write_text('Test license notice\n')
        (self.root / 'source.txt').write_text('Selected legacy source\n')
        self.write_json('publication/policy.json', self.policy)
        self.write_json('publication/provenance.json', self.provenance)
        self.snapshot()

    def write_json(self, name, value):
        (self.root / name).write_text(json.dumps(value) + '\n', encoding='utf-8')

    def snapshot(self):
        with contextlib.redirect_stdout(io.StringIO()):
            publication.snapshot()

    def inspect(self):
        output = io.StringIO()
        report = self.root / '.build/report.json'
        with contextlib.redirect_stdout(output):
            result = publication.gate(report)
        return result, json.loads(report.read_text()), output.getvalue()

    def assert_rule(self, name, rule):
        result, report, output = self.inspect()
        self.assertEqual(result, 1)
        row = next(row for row in report['files'] if row['path'] == name)
        self.assertIn(rule, [issue['rule'] for issue in row['checks']])
        return report, output

    def test_deterministic_compact_snapshot_and_git_selection(self):
        original = (self.root / publication.MANIFEST).read_bytes()
        self.snapshot()
        self.assertEqual((self.root / publication.MANIFEST).read_bytes(), original)
        manifest = json.loads(original)
        self.assertEqual(manifest['schema'], 2)
        self.assertEqual(manifest['provenance'], 'publication/provenance.json')
        for record in manifest['files']:
            self.assertEqual(set(record), {'path', 'sha256_lf'})
        # Both tracked and untracked selected sources remain visible; ignored
        # output is not a substitute filesystem inventory.
        subprocess.run(['git', 'add', 'source.txt'], cwd=self.root, check=True)
        (self.root / '.build').mkdir()
        (self.root / '.build/ignored.txt').write_text('Build output')
        self.assertEqual(self.inspect()[0], 0)
        (self.root / 'unselected.txt').write_text('New source needs review')
        result, report, _ = self.inspect()
        self.assertEqual(result, 1)
        self.assertEqual(report['problems'][0]['missing'], ['unselected.txt'])

    def test_removed_selected_source_fails(self):
        (self.root / 'source.txt').unlink()
        result, report, _ = self.inspect()
        self.assertEqual(result, 1)
        self.assertEqual(report['problems'][0]['stale'], ['source.txt'])

    def test_source_hash_tampering_and_lf_normalization(self):
        (self.root / 'source.txt').write_bytes(b'Selected legacy source\r\n')
        self.assertEqual(self.inspect()[0], 0)
        (self.root / 'source.txt').write_text('Changed source\n')
        self.assert_rule('source.txt', 'manifest-digest')

    def test_metadata_tampering_fails_before_trusting_rules_or_defaults(self):
        for name, value in [
                ('publication/policy.json', dict(self.policy, max_source_bytes=999999999)),
                ('publication/provenance.json', {})]:
            path = self.root / name
            original = path.read_bytes()
            with self.subTest(name=name):
                self.write_json(name, value)
                with self.assertRaisesRegex(ValueError, 'metadata digest mismatch'):
                    self.inspect()
                path.write_bytes(original)

    def test_malformed_origin_cannot_use_authored_default(self):
        for origin in [{}, None, 'legacy', {'kind': ''}]:
            with self.subTest(origin=origin):
                self.write_json('publication/provenance.json', {'source.txt': origin})
                self.snapshot()
                self.assert_rule('source.txt', 'missing-origin-or-license')

    def test_license_must_be_selected_and_present(self):
        (self.root / '.build').mkdir()
        (self.root / '.build/unselected-license').write_text('Unreviewed notice')
        for license_path in ['missing-license', '.build/unselected-license', '../LICENSE']:
            with self.subTest(license_path=license_path):
                self.policy['selections'][0]['license'] = license_path
                self.write_json('publication/policy.json', self.policy)
                self.snapshot()
                self.assert_rule('source.txt', 'missing-origin-or-license')

    def test_unreviewed_selection_and_invalid_maturity_fail(self):
        self.policy['selections'] = [
            {'prefix': name, 'license': 'LICENSE', 'maturity': 'experimental'}
            for name in publication.selected_files() if name != 'source.txt']
        self.write_json('publication/policy.json', self.policy)
        # Keep the digest current to test the selection gate itself.
        manifest = json.loads((self.root / publication.MANIFEST).read_text())
        for row in manifest['files']:
            if row['path'] == 'publication/policy.json':
                row['sha256_lf'] = publication.digest(self.root / row['path'])
        self.write_json(publication.MANIFEST, manifest)
        self.assert_rule('source.txt', 'unreviewed-selection')
        self.policy['selections'] = [{'prefix': '', 'license': 'LICENSE', 'maturity': 'unknown'}]
        self.write_json('publication/policy.json', self.policy)
        self.snapshot()
        self.assert_rule('source.txt', 'invalid-disposition')

    def test_uniform_source_size_limit_including_root_manifest(self):
        for name in ['source.txt', publication.MANIFEST]:
            with self.subTest(name=name):
                original = (self.root / name).read_bytes()
                for size, status in [(524288, 0), (524289, 1)]:
                    (self.root / name).write_bytes(original.ljust(size, b' '))
                    if name != publication.MANIFEST:
                        self.snapshot()
                    self.assertEqual(self.inspect()[0], status)
                    if status:
                        self.assert_rule(name, 'large-source-file')
                (self.root / name).write_bytes(original)
                self.snapshot()

    def test_malformed_manifest_contracts_fail_closed(self):
        original = json.loads((self.root / publication.MANIFEST).read_text())
        changes = [
            {'schema': 1}, {'schema': 99}, {'schema': 2.0},
            {'provenance': '../provenance.json'},
            {'selection_policy': '/policy.json'},
            {'default_origin': {'kind': 'anything'}}, {'export': 'excluded'},
            {'extra': 'unknown'}, {'files': {}},
            {'files': original['files'][::-1]},
            {'files': original['files'] + [original['files'][-1]]},
            {'files': [{}]}, {'files': [None]},
            {'files': [{'path': 'file', 'sha256_lf': 'invalid'}]},
            {'files': [{'path': 'file', 'sha256_lf': None}]},
            {'files': [{'path': 'file', 'sha256_lf': '0' * 64, 'license': 'LICENSE'}]},
            {'files': [r for r in original['files'] if r['path'] != 'publication/provenance.json']},
        ]
        for changeset in changes:
            with self.subTest(changeset=changeset):
                self.write_json(publication.MANIFEST, dict(original, **changeset))
                with self.assertRaises(ValueError):
                    self.inspect()
        (self.root / publication.MANIFEST).write_text('{"schema":2,"schema":2}')
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON key'):
            self.inspect()

    def test_noncanonical_paths_fail_closed(self):
        original = json.loads((self.root / publication.MANIFEST).read_text())
        for name in ['', '../escape', '/absolute', './source.txt', 'dir//source.txt',
                     'dir/../source.txt', 'dir\\source.txt', 'C:/escape', None]:
            with self.subTest(name=name):
                records = [{'path': name, 'sha256_lf': '0' * 64}]
                self.write_json(publication.MANIFEST, dict(original, files=records))
                with self.assertRaises(ValueError):
                    self.inspect()

    def test_symlinked_source_and_metadata_fail_before_reading(self):
        (self.root / 'target.txt').write_text('Outside selection')
        for name in ['source.txt', 'publication/provenance.json']:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.unlink()
                try:
                    path.symlink_to(self.root / 'target.txt')
                except OSError as error:
                    path.write_bytes(original)
                    self.skipTest(f'Creating test symlinks is unavailable: {error}')
                with self.assertRaisesRegex(ValueError, 'Linked source path'):
                    self.inspect()
                path.unlink()
                path.write_bytes(original)

    def test_scans_survive_snapshot_and_never_echo_credentials(self):
        token = 'ghp_' + 'a' * 36
        cases = [
            (token.encode(), 'credential-token'),
            (('-----BEGIN ' + 'PRIVATE KEY-----').encode(), 'private-key'),
            (('C:' + '/' + 'Users/example/private.txt').encode(), 'personal-absolute-path'),
            (('http://' + '127.0.0.1/private').encode(), 'private-host'),
            (('https://github.com/' + 'unknown-owner/private-project').encode(), 'undeclared-repository-link'),
            (b'asset\0bytes', 'binary-asset'), (b'\xff\xfe', 'binary-or-unknown-encoding'),
        ]
        for contents, rule in cases:
            with self.subTest(rule=rule):
                (self.root / 'source.txt').write_bytes(contents)
                self.snapshot()
                report, output = self.assert_rule('source.txt', rule)
                self.assertNotIn(token, json.dumps(report) + output)

    def test_internal_and_unreviewed_agent_files_fail_even_when_selected(self):
        for name, rule in [('.env', 'internal-or-linked-file'),
                           ('.agents/private.md', 'unreviewed-agent-content')]:
            with self.subTest(name=name):
                path = self.root / name
                path.parent.mkdir(exist_ok=True)
                path.write_text('Internal source')
                self.snapshot()
                self.assert_rule(name, rule)
                path.unlink()


class CompilerContract(unittest.TestCase):
    def test_module_type_missing_symbol_and_invalid_source(self):
        state = inspect_haskell.ROOT / '.build'
        state.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='paths with spaces-', dir=state) as directory:
            project = Path(directory)
            source = project / 'src'
            source.mkdir()
            (source / 'Tiny.hs').write_bytes('-- Helpers similar to module Prelude\r\n{- module Bogus where -}\r\nmodule Tiny where\r\n-- 日本語\r\ntwice :: Integer -> Integer\r\ntwice value = value + value\r\n'.encode('utf-8'))
            context = inspect_haskell.query(project, 'src/Tiny.hs', 'twice')
            self.assertEqual(context['exit_code'], 0, context)
            self.assertEqual(context['module'], 'Tiny', context)
            self.assertIn('Integer -> Integer', context['stdout'])
            structure = inspect_haskell.query(project, 'src/Tiny.hs')
            self.assertEqual(structure['exit_code'], 0, structure)
            self.assertEqual(structure['module'], 'Tiny', structure)
            self.assertIn('twice', structure['stdout'])
            missing = inspect_haskell.query(project, 'src/Tiny.hs', 'missingBinding')
            self.assertNotEqual(missing['exit_code'], 0, missing)
            (source / 'Empty.hs').write_text('module Empty () where\n')
            empty = inspect_haskell.query(project, 'src/Empty.hs')
            self.assertEqual(empty['exit_code'], 0, empty)
            self.assertEqual(empty['module'], 'Empty', empty)
            (source / 'Broken.hs').write_text('module Broken where\nbroken :: Integer\nbroken = True\n')
            invalid = inspect_haskell.query(project, 'src/Broken.hs')
            self.assertNotEqual(invalid['exit_code'], 0, invalid)
            self.assertIn('Bool', invalid['stderr'])


if __name__ == '__main__':
    unittest.main()
