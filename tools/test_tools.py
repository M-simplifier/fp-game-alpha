"""Behavioral checks for publication rejection and actual compiler queries."""
import json
from pathlib import Path
import tempfile
import shutil
from unittest.mock import patch

import scaffold
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


class ScaffoldDistribution(unittest.TestCase):
    def test_reader_outputs_and_local_settings_never_enter_game(self):
        with tempfile.TemporaryDirectory(prefix='scaffold-isolation-') as temporary:
            root = Path(temporary) / 'foundation'
            root.mkdir()
            for folder in ['templates', 'libraries', 'docs', 'tools']:
                shutil.copytree(scaffold.ROOT / folder, root / folder,
                                ignore=shutil.ignore_patterns('__pycache__', '.build', 'dist-newstyle'))
            shutil.copy2(scaffold.ROOT / 'LICENSE', root / 'LICENSE')
            for name in ['editors/vscode/package.json', 'editors/vscode/extension.js',
                         'editors/vscode/LICENSE', 'editors/neovim/fp-game.lua']:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(scaffold.ROOT / name, target)
            with patch.object(scaffold, 'ROOT', root):
                args = ('example-game', Path(temporary) / 'game', 'Example',
                        'native', 'terminal', 'unlicensed', None)
                _, before = scaffold.prepare(*args)
                for folder in ['dist', 'node_modules', 'native/vendor',
                               'native/dist-newstyle', '.runtime']:
                    target = root / 'editors/haskell-design' / folder / 'harmless.bin'
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b'harmless\x00\r\n')
                (root / 'editors/haskell-design/.haskell-design.json').write_text('{}')
                (root / 'editors/vscode/local-only.json').write_text('{}')
                _, after = scaffold.prepare(*args)
                self.assertEqual(before, after)
                # Exercise leaf and parent-link rejection on Windows too, where
                # creating a real symlink may require extra OS privileges.
                for linked in [root / 'editors', root / 'editors/vscode',
                               root / 'editors/vscode/extension.js']:
                    with patch.object(Path, 'is_symlink', autospec=True,
                                      side_effect=lambda path, link=linked: path == link):
                        with self.assertRaisesRegex(ValueError, 'linked editor source'):
                            scaffold.prepare(*args)
                self.assertEqual({name for name in after if name.startswith('editors/')},
                    {'editors/vscode/package.json', 'editors/vscode/extension.js',
                     'editors/vscode/LICENSE', 'editors/neovim/fp-game.lua'})


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
