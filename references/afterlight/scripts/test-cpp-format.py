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

    def test_all_targets_reject_source_and_manifest_links(self):
        for linked_name in ['Fixture.hs', 'docs/FORMAT-MANIFEST.json']:
            for hardlink in (False, True):
                with self.subTest(target=linked_name, hardlink=hardlink), tempfile.TemporaryDirectory() as folder:
                    root = Path(folder)
                    (root / 'docs').mkdir()
                    (root / 'Fixture.hs').write_text('f = 1\n')
                    (root / 'docs/FORMAT-MANIFEST.json').write_text('{}')
                    outside = root / 'untouched'
                    outside.write_text('untouched')
                    linked = root / linked_name
                    linked.unlink()
                    if hardlink:
                        os.link(outside, linked)
                    else:
                        linked.symlink_to(outside)
                    before = {name: (root / name).read_bytes() for name in ['Fixture.hs', 'docs/FORMAT-MANIFEST.json']}
                    with patch.object(cpp_format, 'DECLARATIONS', {'Fixture.hs': ['f']}), patch.object(cpp_format, 'ROOT', root), \
                            patch.object(cpp_format.sys, 'argv', ['check-cpp-format.py', '--write']), \
                            patch.object(cpp_format.formatter, 'verified', return_value=None):
                        with self.assertRaises(ValueError):
                            cpp_format.main()
                    self.assertEqual(outside.read_text(), 'untouched')
                    self.assertEqual(before, {name: (root / name).read_bytes() for name in before})

    def test_linked_parent_directory_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Fixture.hs').write_text('f = 1\n')
            (root / 'real-docs').mkdir()
            (root / 'real-docs/FORMAT-MANIFEST.json').write_text('{}')
            (root / 'docs').symlink_to(root / 'real-docs', target_is_directory=True)
            with patch.object(cpp_format, 'DECLARATIONS', {'Fixture.hs': ['f']}):
                with self.assertRaises(ValueError):
                    cpp_format.checked_targets(root)

    def test_write_refuses_semantic_drift_without_mutation(self):
        executable = cpp_format.formatter.verified(cpp_format.FOUNDATION)
        original = '{- ORMOLU_DISABLE -}\nf = do\n#if defined(wasm32_HOST_ARCH)\n  let x = 1\n#else\n  let x = 2\n#endif\n  pure x\n\n{- ORMOLU_ENABLE -}\n'
        original = original.replace('f = do', 'f :: IO Int\nf = do')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'docs').mkdir()
            path = root / 'Fixture.hs'
            changed = original.replace('let x = 1', 'let x = 3')
            path.write_text(changed)
            comparisons = [
                {'path': 'Fixture.hs', 'configuration': 'wasm' if wasm else 'native',
                 'normalized_preprocessed_sha256': cpp_format.sha(cpp_format.canonical(original, wasm, executable)),
                 'same': True} for wasm in (False, True)]
            manifest = root / 'docs/FORMAT-MANIFEST.json'
            manifest.write_text(json.dumps({'cpp_normalized_comparison': comparisons}))
            before = manifest.read_bytes()
            with patch.object(cpp_format, 'ROOT', root), patch.object(cpp_format, 'DECLARATIONS', {'Fixture.hs': ['f']}), \
                    patch.object(cpp_format.sys, 'argv', ['check-cpp-format.py', '--write']):
                with self.assertRaisesRegex(ValueError, 'refusing to relock semantic drift'):
                    cpp_format.main()
            self.assertEqual(path.read_text(), changed)
            self.assertEqual(manifest.read_bytes(), before)

    def test_real_formatter_idempotence_and_drift(self):
        executable = cpp_format.formatter.verified(cpp_format.FOUNDATION)
        source = 'f = do\n#if defined(wasm32_HOST_ARCH)\n  let x=1\n#else\n  let x=2\n#endif\n  pure x\n'
        formatted = cpp_format.weave(source, executable)
        self.assertNotEqual(source, formatted)
        self.assertEqual(formatted, cpp_format.weave(formatted, executable))
        self.assertNotIn('AFTERLIGHT_CPP_BOUNDARY', formatted)
        for wasm in (False, True):
            self.assertEqual(cpp_format.canonical(source, wasm, executable),
                             cpp_format.canonical(formatted, wasm, executable))
        changed = formatted.replace('let x = 1', 'let x = 3')
        self.assertEqual(cpp_format.canonical(formatted, False, executable),
                         cpp_format.canonical(changed, False, executable))
        self.assertNotEqual(cpp_format.canonical(formatted, True, executable),
                            cpp_format.canonical(changed, True, executable))

    def test_runtime_successor_does_not_rewrite_format_history(self):
        executable = cpp_format.formatter.verified(cpp_format.FOUNDATION)
        original = '{- ORMOLU_DISABLE -}\nf :: IO Int\nf = do\n#if defined(wasm32_HOST_ARCH)\n  let x = 1\n#else\n  let x = 2\n#endif\n  pure x\n\n{- ORMOLU_ENABLE -}\n'
        revised = original.replace('let x = 1', 'let x=3')
        name = cpp_format.RUNTIME
        historical = [dict(path=name, configuration='wasm' if wasm else 'native',
                           normalized_preprocessed_sha256=cpp_format.sha(cpp_format.canonical(original, wasm, executable)),
                           same=True) for wasm in (False, True)]
        revisions = [dict(path=name, configuration=row['configuration'],
                          previous_sha256=row['normalized_preprocessed_sha256'],
                          current_sha256=cpp_format.sha(cpp_format.canonical(revised, row['configuration'] == 'wasm', executable)))
                     for row in historical]
        predecessor = hashlib.sha256(original.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / name
            path.parent.mkdir(parents=True)
            path.write_text(revised)
            (root / 'docs').mkdir()
            format_path = root / 'docs/FORMAT-MANIFEST.json'
            format_path.write_text(json.dumps(dict(files=[dict(path=name, formatted_sha256=predecessor)],
                                                   cpp_normalized_comparison=historical)))
            revision_path = root / cpp_format.FRAME_MANIFEST
            revision_path.write_text(json.dumps(dict(schema=1, kind='reviewed-frame-boundaries',
                                                     files=[dict(path=name, previous_sha256=predecessor, current_sha256='0' * 64)],
                                                     cpp_normalized_comparison=revisions)))
            before = format_path.read_bytes()
            with patch.object(cpp_format, 'ROOT', root), patch.object(cpp_format, 'DECLARATIONS', {name: ['f']}), \
                    patch.object(cpp_format.sys, 'argv', ['check-cpp-format.py', '--write']):
                cpp_format.main()
            self.assertEqual(format_path.read_bytes(), before)
            self.assertIn('let x = 3', path.read_text())
            current = json.loads(revision_path.read_text())['files'][0]['current_sha256']
            self.assertEqual(current, hashlib.sha256(path.read_bytes()).hexdigest())
            # A new token change cannot be relocked by --write.
            changed = path.read_text().replace('let x = 3', 'let x = 4')
            path.write_text(changed)
            before_revision = revision_path.read_bytes()
            with patch.object(cpp_format, 'ROOT', root), patch.object(cpp_format, 'DECLARATIONS', {name: ['f']}), \
                    patch.object(cpp_format.sys, 'argv', ['check-cpp-format.py', '--write']), \
                    self.assertRaisesRegex(ValueError, 'refusing to relock semantic drift'):
                cpp_format.main()
            self.assertEqual(path.read_text(), changed)
            self.assertEqual(format_path.read_bytes(), before)
            self.assertEqual(revision_path.read_bytes(), before_revision)

    def test_runtime_successor_rejects_changed_scope_and_predecessor(self):
        manifest = dict(files=[dict(path=cpp_format.RUNTIME, formatted_sha256='1' * 64)],
                        cpp_normalized_comparison=[dict(path=cpp_format.RUNTIME, configuration=c,
                                                       normalized_preprocessed_sha256='2' * 64, same=True)
                                                   for c in ('native', 'wasm')])
        revision = dict(schema=1, kind='reviewed-frame-boundaries',
                        files=[dict(path=cpp_format.RUNTIME, previous_sha256='1' * 64)],
                        cpp_normalized_comparison=[dict(path=cpp_format.RUNTIME, configuration=c,
                                                       previous_sha256='2' * 64, current_sha256='3' * 64)
                                                   for c in ('native', 'wasm')])
        mutations = [
            lambda v: v.update(kind='generic-exemption'),
            lambda v: v['files'][0].update(previous_sha256='4' * 64),
            lambda v: v['files'].append(dict(v['files'][0])),
            lambda v: v['cpp_normalized_comparison'][0].update(previous_sha256='4' * 64),
            lambda v: v['cpp_normalized_comparison'][0].update(path='runtime/Garden/Render.hs'),
            lambda v: v['cpp_normalized_comparison'][0].update(current_sha256='bad'),
            lambda v: v['cpp_normalized_comparison'].append(dict(v['cpp_normalized_comparison'][0])),
        ]
        for mutate in mutations:
            value = json.loads(json.dumps(revision))
            mutate(value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                cpp_format.reviewed_comparisons(manifest, value)


if __name__ == '__main__':
    unittest.main()
