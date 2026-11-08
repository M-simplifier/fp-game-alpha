"""Protect the path boundaries that let ordinary changes use fewer runners."""
from pathlib import Path
import re
import unittest

from ci_selection import AFTERLIGHT, EDITOR, FULL, HOSTS, NATIVE, SOURCE, selection


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
        linux = HOSTS[:1]
        for path, expected in {
            'libraries/game-transition/src/Game/Transition.hs': {SOURCE: HOSTS, NATIVE: True, AFTERLIGHT: True},
            'templates/terminal-adventure/build.config': {SOURCE: HOSTS, NATIVE: True},
            'references/station/src/Station/Domain.hs': {SOURCE: HOSTS},
            'references/afterlight/runtime/Garden/Runtime.hs': {SOURCE: linux, AFTERLIGHT: True},
            'research/frontiers/free/AlphaFreeWitness.hs': {SOURCE: linux},
            'references/red-dune/core/Colony/Units.hs': {SOURCE: linux},
            'editors/haskell-design/package.json': {SOURCE: linux, EDITOR: True},
            'editors/neovim/fp-game.lua': {SOURCE: linux, EDITOR: True, NATIVE: True},
            'tools/windows-console/hidden-console.c': {SOURCE: linux, NATIVE: True},
            'tools/publication.py': {SOURCE: HOSTS},
            '.github/workflows/ci.yml': FULL,
            'docs/new-consumer.py': FULL,
        }.items():
            with self.subTest(path=path):
                self.assertEqual(selection([path, 'PUBLICATION-MANIFEST.json']), expected)

    def test_multiple_changes_union_the_checks(self):
        paths = ['references/afterlight/a.hs', 'cabal.project', 'editors/haskell-design/package.json']
        expected = {SOURCE: HOSTS, AFTERLIGHT: True, EDITOR: True}
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
                self.assertIn(NATIVE, selection([path]))


if __name__ == '__main__':
    unittest.main()
