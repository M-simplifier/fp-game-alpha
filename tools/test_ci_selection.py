"""Protect the path boundaries that let ordinary changes use fewer runners."""
from pathlib import Path
import re
import unittest

from ci_selection import AFTERLIGHT, AFTERLIGHT_WINDOWS, EDITOR, FULL, HOSTS, KERNEL_HOSTS, LINUX, MACOS, NATIVE, SOURCE, WINDOWS, selection


class SelectionTest(unittest.TestCase):
    def test_public_changes(self):
        for paths in [
            ['README.md', 'PUBLICATION-MANIFEST.json'],
            ['docs/purpose.md', 'site/learn.html', 'site/evidence/station-trace.json'],
            ['research/frontiers/category/finite_witness.py',
             'research/frontiers/category/finite-results.json', 'tools/test_research.py'],
        ]:
            with self.subTest(paths=paths):
                self.assertEqual(selection(paths), {})

    def test_component_checks(self):
        linux = [LINUX]
        for path, expected in {
            'libraries/game-transition/src/Game/Transition.hs': {SOURCE: linux, NATIVE: linux, AFTERLIGHT: True, AFTERLIGHT_WINDOWS: True},
            'libraries/game-arena/game-arena.cabal': {SOURCE: KERNEL_HOSTS, NATIVE: KERNEL_HOSTS, AFTERLIGHT: True, AFTERLIGHT_WINDOWS: True},
            'templates/terminal-adventure/build.config': {SOURCE: KERNEL_HOSTS, NATIVE: KERNEL_HOSTS},
            'references/station/src/Station/Domain.hs': {SOURCE: linux},
            'tools/play.py': {SOURCE: KERNEL_HOSTS},
            'cabal.project.gameio-afterlight': {AFTERLIGHT_WINDOWS: True},
            'references/afterlight/runtime/Garden/Runtime.hs': {SOURCE: linux, AFTERLIGHT: True, AFTERLIGHT_WINDOWS: True},
            'references/afterlight/web/BrowserMain.hs': {SOURCE: linux, AFTERLIGHT: True},
            'research/frontiers/free/AlphaFreeWitness.hs': {SOURCE: linux},
            'references/red-dune/core/Colony/Units.hs': {SOURCE: linux},
            'editors/haskell-design/package.json': {SOURCE: linux, EDITOR: True},
            'editors/neovim/fp-game.lua': {SOURCE: linux, EDITOR: True, NATIVE: linux},
            'tools/windows-console/hidden-console.c': {SOURCE: linux, NATIVE: [WINDOWS]},
            'tools/bootstrap-fp-game.sh': {NATIVE: [LINUX, MACOS]},
            'tools/haskell/src/FpGame/Result.hs': {NATIVE: KERNEL_HOSTS},
            'tools/haskell/src/FpGame/Process.hs': {NATIVE: HOSTS},
            'tools/haskell/src/FpGame/Command.hs': {NATIVE: HOSTS},
            'tools/haskell/src/FpGame/Config.hs': {NATIVE: HOSTS},
            'tools/haskell/src/FpGame/Create/Distribution.hs': {NATIVE: HOSTS},
            'tools/haskell/src/FpGame/Create/Filesystem.hs': {NATIVE: HOSTS},
            'tools/haskell/test/CreateSpec.hs': {NATIVE: HOSTS},
            'tools/publication.py': {SOURCE: KERNEL_HOSTS},
            '.github/workflows/ci.yml': FULL,
            'docs/new-consumer.py': FULL,
        }.items():
            with self.subTest(path=path):
                self.assertEqual(selection([path, 'PUBLICATION-MANIFEST.json']), expected)

    def test_multiple_changes_union_the_checks(self):
        paths = ['references/afterlight/a.hs', 'cabal.project', 'editors/haskell-design/package.json',
                 'tools/bootstrap-fp-game.sh', 'tools/windows-console/hidden-console.c']
        expected = {SOURCE: KERNEL_HOSTS, AFTERLIGHT: True, AFTERLIGHT_WINDOWS: True, EDITOR: True, NATIVE: HOSTS}
        self.assertEqual(selection(paths), expected)
        self.assertEqual(selection(reversed(paths)), expected)

    def test_documents_copied_into_games_select_native_checks(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'tools/haskell/src/FpGame/Create/Distribution.hs').read_text(encoding='utf-8')
        copied = source.split('foundationSources =', 1)[1].split('gameWorkflow ::', 1)[0]
        documents = re.findall(r'"((?:docs/|\.agents/)[^"]+)"', copied)
        self.assertIn('docs/native-tooling.md', documents)
        for path in documents:
            with self.subTest(path=path):
                self.assertEqual(selection([path]), {NATIVE: [LINUX]})


if __name__ == '__main__':
    unittest.main()
