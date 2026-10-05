"""Regression checks for the frozen independent Python comparison oracle only."""
import sys
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent / 'fixtures/python_cli'))
import scaffold

scaffold.ROOT = ROOT

class ScaffoldDistribution(unittest.TestCase):
    def test_reader_outputs_and_local_settings_never_enter_game(self):
        with tempfile.TemporaryDirectory(prefix='scaffold-isolation-') as temporary:
            root = Path(temporary) / 'foundation'
            root.mkdir()
            for folder in ['templates', 'libraries', 'docs', 'tools']:
                shutil.copytree(scaffold.ROOT / folder, root / folder,
                                ignore=shutil.ignore_patterns('__pycache__', '.build', 'dist-newstyle'))
            shutil.copy2(scaffold.ROOT / 'LICENSE', root / 'LICENSE')
            for name in ['fp_game.py', 'scaffold.py']:
                shutil.copy2(ROOT / 'tools/acceptance/fixtures/python_cli' / name, root / 'tools' / name)
            learning_skill = '.agents/skills/learn-code/SKILL.md'
            target = root / learning_skill
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(scaffold.ROOT / learning_skill, target)
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



if __name__ == '__main__':
    unittest.main()
