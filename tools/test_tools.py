"""Behavioral checks for publication rejection and actual compiler queries."""
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

import unittest

import inspect_haskell
import publication


class ExportScan(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((publication.ROOT / 'publication/policy.json').read_text())

    def test_only_exact_root_manifest_has_larger_bounded_size_limit(self):
        self.assertEqual(publication.source_size_limit(publication.MANIFEST, self.policy),
                         1024 * 1024)
        for name in ['source.hs', 'nested/PUBLICATION-MANIFEST.json',
                     'PUBLICATION-MANIFEST.json.backup', 'publication/provenance.json']:
            with self.subTest(name=name):
                self.assertEqual(publication.source_size_limit(name, self.policy),
                                 self.policy['max_source_bytes'])
        self.assertEqual(self.policy['max_source_bytes'], 524288)

    def test_gate_enforces_manifest_and_ordinary_file_limits(self):
        with tempfile.TemporaryDirectory(prefix='publication-size-') as temporary:
            root = Path(temporary)
            (root / 'publication').mkdir()
            policy = dict(self.policy, selections=[
                {'prefix': '', 'license': 'LICENSE', 'maturity': 'experimental'}])
            (root / 'publication/policy.json').write_text(json.dumps(policy))
            (root / 'LICENSE').write_text('Test license notice')
            names = ['LICENSE', publication.MANIFEST, 'ordinary.txt']

            def inspect(ordinary_size, manifest_size):
                (root / 'ordinary.txt').write_text('a' * ordinary_size)
                records = [
                    {'path': name, 'sha256_lf': None if name == publication.MANIFEST
                     else publication.digest(root / name), 'origin': {'kind': 'test'},
                     'license': 'LICENSE', 'maturity': 'experimental', 'export': 'selected'}
                    for name in names]
                manifest = json.dumps({'files': records})
                self.assertLess(len(manifest), manifest_size)
                (root / publication.MANIFEST).write_text(manifest.ljust(manifest_size))
                report_path = root / 'report.json'
                with patch.object(publication, 'ROOT', root), \
                     patch.object(publication, 'selected_files', return_value=names), \
                     patch('builtins.print'):
                    result = publication.gate(report_path)
                report = json.loads(report_path.read_text())
                large = [row['path'] for row in report['files']
                         if {'rule': 'large-source-file'} in row['checks']]
                return result, large

            self.assertEqual(inspect(524288, 600000), (0, []))
            self.assertEqual(inspect(524289, 600000), (1, ['ordinary.txt']))
            self.assertEqual(inspect(524288, 1048577),
                             (1, [publication.MANIFEST]))

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
