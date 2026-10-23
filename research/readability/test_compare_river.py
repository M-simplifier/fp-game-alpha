"""Exercise baseline selection with real Git trees, without a compiler."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('river_compare', Path(__file__).with_name('compare_river.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class BaselineSources(unittest.TestCase):
    def test_revision_supplies_private_modules_and_only_owned_haskell_sources(self):
        with tempfile.TemporaryDirectory(prefix='river baseline ') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            sources = {
                'references/river/src/Life/Domain.hs': b'module Life.Domain where\nimport Life.Internal.Core\n',
                'references/river/src/Life/Internal/Core.hs': b'module Life.Internal.Core where\nvalue = 1\n',
                'libraries/game-arena/src/Game/Arena.hs': b'module Game.Arena where\n',
                'libraries/game-transition/src/Game/Transition.hs': b'module Game.Transition where\n',
            }
            for name, data in {**sources, 'references/river/src/notes.txt': b'not Haskell',
                                'unrelated/Other.hs': b'not selected'}.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                            'commit', '-qm', 'baseline'], cwd=root, check=True)
            (root / 'references/river/src/Life/Internal/Core.hs').write_text('changed working source')
            with patch.object(runner, 'ROOT', root):
                destination = root / 'copied'
                selected = runner.copy_baseline('HEAD', destination)
            self.assertEqual(selected, sorted(sources))
            actual = {p.relative_to(destination).as_posix(): p.read_bytes()
                      for p in destination.rglob('*') if p.is_file()}
            self.assertEqual(actual, sources)

    def test_empty_baseline_fails_instead_of_compiling_ambient_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                            'commit', '--allow-empty', '-qm', 'empty'], cwd=root, check=True)
            with patch.object(runner, 'ROOT', root), self.assertRaisesRegex(RuntimeError, 'no Haskell sources'):
                runner.copy_baseline('HEAD', root / 'copied')


if __name__ == '__main__':
    unittest.main()
