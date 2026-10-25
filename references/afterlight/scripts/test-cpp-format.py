"""Fail-closed boundary and reproducibility tests; uses the pinned formatter."""
import importlib.util
import hashlib
import json
import os
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('cpp_format', Path(__file__).with_name('check-cpp-format.py'))
cpp_format = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpp_format)


class CPPFormatting(unittest.TestCase):
    def test_both_projections(self):
        source = '#if defined(wasm32_HOST_ARCH)\nweb\n#else\nnative\n#endif\nshared\n'
        native, _ = cpp_format.project(source, False)
        web, _ = cpp_format.project(source, True)
        self.assertIn('\nnative\n', native)
        self.assertNotIn('\nweb\n', native)
        self.assertIn('\nweb\n', web)
        self.assertNotIn('\nnative\n', web)
        self.assertTrue(native.endswith('shared\n') and web.endswith('shared\n'))

    def test_native_only(self):
        source = '#if !defined(wasm32_HOST_ARCH)\nnative\n#endif\n'
        self.assertIn('\nnative\n', cpp_format.project(source, False)[0])
        self.assertNotIn('\nnative\n', cpp_format.project(source, True)[0])

    def test_unknown_nested_and_unbalanced_directives_rejected(self):
        for source in ['#if UNKNOWN\n#endif\n', '#else\n', '#endif\n',
                       '#if defined(wasm32_HOST_ARCH)\n',
                       '#if defined(wasm32_HOST_ARCH)\n#if defined(wasm32_HOST_ARCH)\n#endif\n#endif\n',
                       '#if defined(wasm32_HOST_ARCH)\n#else\n#else\n#endif\n']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                cpp_format.project(source, False)

    def test_shared_disagreement_rejected(self):
        with patch.object(cpp_format, 'format_haskell', side_effect=[cpp_format.PREAMBLE + 'x = 1\n', cpp_format.PREAMBLE + 'x = 2\n']):
            with self.assertRaisesRegex(ValueError, 'Shared text'):
                cpp_format.weave('x = 1\n', None)

    def test_lost_boundary_rejected(self):
        with patch.object(cpp_format, 'format_haskell', return_value=cpp_format.PREAMBLE + 'x = 1\n'):
            with self.assertRaisesRegex(ValueError, 'boundary'):
                cpp_format.weave('#if defined(wasm32_HOST_ARCH)\nx = 1\n#endif\n', None)

    def test_missing_or_hardlinked_target_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(cpp_format, 'DECLARATIONS', {'Fixture.hs': ['value']}):
                with self.assertRaises(ValueError):
                    cpp_format.checked_targets(root)
                (root / 'Fixture.hs').write_text('value = 1\n')
                (root / 'other.hs').hardlink_to(root / 'Fixture.hs')
                with self.assertRaises(ValueError):
                    cpp_format.checked_targets(root)


if __name__ == '__main__':
    unittest.main()
