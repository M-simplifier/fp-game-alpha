"""Offline formatter safety tests; --integration also runs the pinned executable."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import formatter
from acceptance.native import create_game

INTEGRATION = '--integration' in sys.argv
if INTEGRATION:
    sys.argv.remove('--integration')


def zipped(name='ormolu', data=b'formatter', mode=None, extra=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        entry = zipfile.ZipInfo(name)
        if mode is not None:
            entry.external_attr = mode << 16
        archive.writestr(entry, data)
        if extra:
            archive.writestr(extra, b'other')
    return output.getvalue()


def item(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


class ArchiveTests(unittest.TestCase):
    def test_regular_binary(self):
        data = zipped()
        self.assertEqual(formatter.archive_payloads(data, item(data), 'ormolu'), {'ormolu': b'formatter'})

    def test_pinned_sibling_library(self):
        data = zipped(extra='libtest.1.dylib')
        pinned = {**item(data), 'members': ['ormolu', 'libtest.1.dylib']}
        self.assertEqual(formatter.archive_payloads(data, pinned, 'ormolu'),
                         {'ormolu': b'formatter', 'libtest.1.dylib': b'other'})
        for members in [['ormolu'], ['ormolu', '../libtest.1.dylib'],
                        ['ormolu', 'libtest.1.dylib', 'libtest.1.dylib']]:
            with self.subTest(members=members), self.assertRaises(ValueError):
                formatter.archive_payloads(data, {**item(data), 'members': members}, 'ormolu')

    def test_library_symlink_and_duplicate_rejected(self):
        for duplicate in [False, True]:
            output = io.BytesIO()
            with zipfile.ZipFile(output, 'w') as archive:
                archive.writestr('ormolu', b'executable')
                entry = zipfile.ZipInfo('libtest.1.dylib')
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, b'target')
                if duplicate:
                    archive.writestr('ormolu', b'duplicate')
            data = output.getvalue()
            with self.assertRaises(ValueError):
                formatter.archive_payloads(data, {**item(data), 'members': ['ormolu', 'libtest.1.dylib']}, 'ormolu')

    def test_checksum_mismatch(self):
        data = zipped()
        with self.assertRaisesRegex(ValueError, 'checksum'):
            formatter.archive_payloads(data, {**item(data), 'sha256': '0' * 64}, 'ormolu')

    def test_malformed_archive(self):
        data = b'not zip'
        with self.assertRaisesRegex(ValueError, 'Malformed'):
            formatter.archive_payloads(data, item(data), 'ormolu')

    def test_paths_extra_files_and_symlinks(self):
        for data in [zipped('../ormolu'), zipped('/ormolu'), zipped('bin/ormolu'),
                     zipped('C:\\ormolu'), zipped(extra='README'),
                     zipped(mode=stat.S_IFLNK | 0o777), zipped(mode=stat.S_IFIFO | 0o600)]:
            with self.subTest(archive=repr(data[:20])), self.assertRaises(ValueError):
                formatter.archive_payloads(data, item(data), 'ormolu')

    def test_unpacked_size_limit(self):
        data = zipped(data=b'large')
        with patch.object(formatter, 'MAX_BINARY', 4), self.assertRaisesRegex(ValueError, 'size'):
            formatter.archive_payloads(data, item(data), 'ormolu')


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='formatter test ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / 'tools').mkdir()
        shutil.copy2(formatter.ROOT / 'tools/formatter.lock.json', self.root / 'tools')
        (self.root / 'src').mkdir()
        (self.root / 'src/Main.hs').write_text('module Main where\nmain=print 1\n')
        self.config(['src'])

    def config(self, roots):
        (self.root / 'formatter.json').write_text(json.dumps({'schema': 1, 'source_roots': roots}))

    def test_plan_has_no_side_effect(self):
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch('urllib.request.urlopen', side_effect=AssertionError('network')):
            result = formatter.perform('plan', self.root)
            self.assertFalse(result['mutates'])
            self.assertEqual(result['sources'], ['src/Main.hs'])
            self.assertFalse((self.root / '.build').exists())

    def test_unsupported_platform(self):
        with patch.object(formatter, 'profile_key', return_value='Linux-arm64'), self.assertRaisesRegex(ValueError, 'No pinned'):
            formatter.metadata(self.root)

    def test_unsafe_paths(self):
        for path in ['../escape', '/tmp/escape', 'C:/escape', 'src\\escape', 'vendor.', 'vendor ', 'src/fixtures.']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                formatter.local_path(self.root, path)

    def test_protected_roots(self):
        for root in ['vendor', 'src/fixtures', 'oracle', '.', '..']:
            self.config([root])
            with self.subTest(root=root), self.assertRaises(ValueError):
                formatter.source_files(self.root)

    def test_nested_fixtures_are_excluded(self):
        (self.root / 'src/fixtures').mkdir()
        (self.root / 'src/fixtures/Bad.hs').write_text('do not rewrite')
        self.assertEqual([p.name for p in formatter.source_files(self.root)], ['Main.hs'])

    def test_no_silent_empty_success(self):
        (self.root / 'src/Main.hs').unlink()
        with self.assertRaisesRegex(ValueError, 'No owned'):
            formatter.source_files(self.root)

    def test_missing_check_never_downloads(self):
        before = (self.root / 'src/Main.hs').read_bytes()
        with patch('urllib.request.urlopen', side_effect=AssertionError('network')), self.assertRaisesRegex(ValueError, 'missing'):
            formatter.perform('check', self.root)
        self.assertEqual(before, (self.root / 'src/Main.hs').read_bytes())

    def test_symlink_cache_and_source_refused(self):
        target = self.root / 'real'
        target.mkdir()
        link = self.root / '.build'
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError:
            self.skipTest('OS does not permit test symlinks')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            formatter.local_path(self.root, '.build/tools')
        (self.root / 'src/Linked.hs').symlink_to(self.root / 'src/Main.hs')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            formatter.source_files(self.root)

    def test_hard_link_into_vendor_refused(self):
        target = self.root / 'vendor'
        target.mkdir()
        protected = target / 'Protected.hs'
        protected.write_text('module Protected where\nvalue=1\n')
        before = protected.read_bytes()
        try:
            os.link(protected, self.root / 'src/Linked.hs')
        except OSError:
            self.skipTest('filesystem does not permit test hard links')
        with self.assertRaisesRegex(ValueError, 'hard-linked'):
            formatter.source_files(self.root)
        self.assertEqual(protected.read_bytes(), before)

    def test_junction_guard_without_windows(self):
        with patch.object(Path, 'is_junction', create=True, return_value=True):
            with self.assertRaisesRegex(ValueError, 'junction'):
                formatter.local_path(self.root, 'src/Main.hs')

    @unittest.skipUnless(os.name == 'nt', 'requires Windows junction support')
    def test_windows_junction_into_vendor_refused(self):
        target = self.root / 'vendor'
        target.mkdir()
        (target / 'DoNotFormat.hs').write_text('module DoNotFormat where\nvalue=1\n')
        link = self.root / 'src/linked'
        result = subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(target)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.addCleanup(lambda: os.rmdir(link) if link.exists() else None)
        with self.assertRaisesRegex(ValueError, 'junction'):
            formatter.source_files(self.root)

    def test_unknown_action_never_writes(self):
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            formatter.perform('chekc', self.root)

    def test_version_mismatch(self):
        result = subprocess.CompletedProcess([], 0, 'ormolu 0.8.0.0\n', '')
        with patch('subprocess.run', return_value=result), self.assertRaisesRegex(ValueError, 'version'):
            formatter.check_version(Path('ormolu'), '0.9.0.0', self.root)

    def fake_install(self, libraries=False):
        data = zipped(extra='libtest.1.dylib' if libraries else None)
        lock_path = self.root / 'tools/formatter.lock.json'
        lock = json.loads(lock_path.read_text())
        lock['profiles']['Linux-x86_64'].update(item(data))
        if libraries:
            lock['profiles']['Linux-x86_64']['members'] = ['ormolu', 'libtest.1.dylib']
        lock_path.write_text(json.dumps(lock))
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch.object(formatter, 'check_version'), patch('urllib.request.urlopen', return_value=io.BytesIO(data)):
            result = formatter.install(self.root)
        return Path(result['path'])

    def test_install_then_verified_reuse_without_network(self):
        executable = self.fake_install()
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch.object(formatter, 'check_version'), patch('urllib.request.urlopen', side_effect=AssertionError('network')):
            self.assertEqual(formatter.install(self.root)['status'], 'reused')
            self.assertEqual(formatter.verified(self.root), executable)

    def test_cached_sibling_libraries_verified_before_execution(self):
        executable = self.fake_install(libraries=True)
        library = executable.parent / 'libtest.1.dylib'
        self.assertEqual(library.read_bytes(), b'other')
        library.write_bytes(b'tampered')
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch('subprocess.run', side_effect=AssertionError('must not execute')):
            with self.assertRaisesRegex(ValueError, 'differs'):
                formatter.verified(self.root)
            library.unlink()
            with self.assertRaisesRegex(ValueError, 'Incomplete formatter cache'):
                formatter.verified(self.root)

    def test_incomplete_cache_has_recovery_guidance(self):
        executable = self.fake_install()
        (executable.parent / 'archive.zip').unlink()
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch('urllib.request.urlopen', side_effect=AssertionError('network')):
            with self.assertRaisesRegex(ValueError, 'Incomplete formatter cache.*Inspect it, remove only'):
                formatter.install(self.root)

    def test_modified_cache_rejected(self):
        executable = self.fake_install()
        executable.write_bytes(b'tampered')
        with patch.object(formatter, 'profile_key', return_value='Linux-x86_64'), patch('subprocess.run', side_effect=AssertionError('must not execute')):
            with self.assertRaisesRegex(ValueError, 'differs'):
                formatter.verified(self.root)


@unittest.skipUnless(INTEGRATION, 'use --integration after explicit install')
class RealFormatterTests(unittest.TestCase):
    def test_hand_authored_project_without_scaffold_or_cabal(self):
        executable = formatter.verified(formatter.ROOT)
        with tempfile.TemporaryDirectory(prefix='hand authored formatter ') as temporary:
            project = Path(temporary).resolve()
            (project / 'tools').mkdir()
            (project / 'src').mkdir()
            (project / 'formatter.json').write_text(json.dumps({'schema': 1, 'source_roots': ['src']}))
            (project / 'src/Main.hs').write_text('module Main where\nmain= print (2 :: Int)\n')
            for name in ['formatter.py', 'formatter.lock.json']:
                shutil.copy2(formatter.ROOT / 'tools' / name, project / 'tools' / name)
            shutil.copytree(executable.parent, project / executable.parent.relative_to(formatter.ROOT))
            command = [sys.executable, str(project / 'tools/formatter.py')]
            self.assertEqual(subprocess.run([*command, 'check'], capture_output=True).returncode, 1)
            self.assertEqual(subprocess.run([*command, 'write'], capture_output=True).returncode, 0)
            self.assertEqual(subprocess.run([*command, 'check'], capture_output=True).returncode, 0)

    def test_independent_game_check_write_and_protection(self):
        executable = formatter.verified(formatter.ROOT)
        with tempfile.TemporaryDirectory(prefix='formatter generated game ') as temporary:
            destination = create_game('format-game', Path(temporary).resolve() / 'game', 'Format game')
            cache_relative = executable.parent.relative_to(formatter.ROOT)
            shutil.copytree(executable.parent, destination / cache_relative)
            result = formatter.perform('check', destination)
            self.assertEqual(result['exit_code'], 0, result)
            source = destination / 'src/Untidy.hs'
            source.write_text('module Untidy where\nvalue=  1\n')
            original = source.read_bytes()
            vendor = destination / 'vendor/game-transition/src/Game/Transition.hs'
            vendor_before = vendor.read_bytes()
            self.assertEqual(formatter.perform('check', destination)['exit_code'], 1)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(formatter.perform('write', destination)['exit_code'], 0)
            self.assertNotEqual(source.read_bytes(), original)
            self.assertEqual(formatter.perform('check', destination)['exit_code'], 0)
            self.assertEqual(vendor.read_bytes(), vendor_before)
            command = [sys.executable, str(destination / 'tools/formatter.py'), 'path']
            result = subprocess.run(command, cwd=destination, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip().startswith(str(destination)))


if __name__ == '__main__':
    unittest.main()
