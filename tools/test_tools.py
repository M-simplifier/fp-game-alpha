"""Behavioral checks for publication rejection and actual compiler queries."""
import json
from pathlib import Path
import tempfile
import unittest

import fp_game
import publication


class ExportScan(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads((publication.ROOT / 'publication/policy.json').read_text())

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
        state = fp_game.ROOT / '.build'
        state.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='paths with spaces-', dir=state) as directory:
            project = Path(directory)
            source = project / 'src'
            source.mkdir()
            (source / 'Tiny.hs').write_bytes('-- Helpers similar to module Prelude\r\n{- module Bogus where -}\r\nmodule Tiny where\r\n-- 日本語\r\ntwice :: Integer -> Integer\r\ntwice value = value + value\r\n'.encode('utf-8'))
            context = fp_game.query(project, 'src/Tiny.hs', 'twice')
            self.assertEqual(context['exit_code'], 0, context)
            self.assertEqual(context['module'], 'Tiny', context)
            self.assertIn('Integer -> Integer', context['stdout'])
            structure = fp_game.query(project, 'src/Tiny.hs')
            self.assertEqual(structure['exit_code'], 0, structure)
            self.assertEqual(structure['module'], 'Tiny', structure)
            self.assertIn('twice', structure['stdout'])
            missing = fp_game.query(project, 'src/Tiny.hs', 'missingBinding')
            self.assertNotEqual(missing['exit_code'], 0, missing)
            (source / 'Empty.hs').write_text('module Empty () where\n')
            empty = fp_game.query(project, 'src/Empty.hs')
            self.assertEqual(empty['exit_code'], 0, empty)
            self.assertEqual(empty['module'], 'Empty', empty)
            (source / 'Broken.hs').write_text('module Broken where\nbroken :: Integer\nbroken = True\n')
            invalid = fp_game.check_file(project, 'src/Broken.hs')
            self.assertNotEqual(invalid['exit_code'], 0, invalid)
            self.assertIn('Bool', invalid['stderr'])


if __name__ == '__main__':
    unittest.main()
