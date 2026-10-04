"""Cache-boundary tests only; mocked compiler calls are not Haskell evidence."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('check_core', Path(__file__).with_name('check-core.py'))
check_core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_core)


class CacheBoundary(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.archives = self.root / 'archives'
        self.archives.mkdir()
        self.archive = self.archives / 'sample-1.tar.gz'
        with tarfile.open(self.archive, 'w:gz') as bundle:
            for name, value in [('A.hs', b'original A\n'), ('B.hs', b'original B\n')]:
                info = tarfile.TarInfo('sample-1/' + name)
                info.size = len(value)
                bundle.addfile(info, io.BytesIO(value))
        self.expected = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.target = self.root / '.build/afterlight-core/sources/sample-1'
        self.target.mkdir(parents=True)

    def tearDown(self):
        self.directory.cleanup()

    def invoke(self, expected_code):
        with patch.object(check_core, 'FOUNDATION', self.root), \
             patch.object(check_core, 'DEPENDENCIES', [('sample', '1', self.expected)]), \
             patch.object(check_core.shutil, 'which', return_value='mock-tool'), \
             patch.object(check_core.subprocess, 'check_output', return_value='test-version\n'), \
             patch.object(check_core.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)) as run, \
             patch('sys.argv', ['check-core.py', '--archives', str(self.archives)]), \
             patch('sys.stderr', new_callable=io.StringIO), self.assertRaises(SystemExit) as stopped:
            check_core.main()
        self.assertEqual(stopped.exception.code, expected_code)
        self.assertEqual(run.call_count, 1 if expected_code == 0 else 0)

    def test_valid_archive_and_repair_regular_cache(self):
        (self.target / 'A.hs').write_bytes(b'edited')
        self.invoke(0)
        self.assertEqual((self.target / 'A.hs').read_bytes(), b'original A\n')
        self.assertEqual((self.target / 'B.hs').read_bytes(), b'original B\n')

    def test_wrong_archive_hash_never_reaches_compiler(self):
        self.archive.write_bytes(b'wrong')
        self.invoke(2)

    def test_extra_cache_file_never_reaches_compiler(self):
        (self.target / 'Extra.hs').write_bytes(b'extra')
        self.invoke(2)

    def test_hardlink_cache_rejected_before_overwrite(self):
        a = self.target / 'A.hs'
        a.write_bytes(b'keep')
        (self.target / 'B.hs').hardlink_to(a)
        self.invoke(2)
        self.assertEqual(a.read_bytes(), b'keep')

    def test_symlink_cache_rejected_before_overwrite(self):
        a = self.target / 'A.hs'
        a.write_bytes(b'keep')
        try:
            (self.target / 'B.hs').symlink_to(a)
        except OSError as error:
            self.skipTest(f'Symlink creation unavailable: {error}')
        self.invoke(2)
        self.assertEqual(a.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
