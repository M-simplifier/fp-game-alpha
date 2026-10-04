"""Offline mutation checks: successor provenance must not weaken source auditing."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

GAME = Path(__file__).resolve().parents[1]


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.game = Path(self.temp.name) / 'references/afterlight'
        shutil.copytree(GAME, self.game)
        self.manifest = self.game / 'docs/TEST-OPTIMIZATION-MANIFEST.json'

    def audit(self, success):
        result = subprocess.run([sys.executable, str(self.game / 'scripts/audit-source.py')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def mutate_manifest(self, change):
        value = json.loads(self.manifest.read_text())
        change(value)
        self.manifest.write_text(json.dumps(value))

    def test_reviewed_successor(self):
        self.audit(True)

    def test_all_successor_bytes_locked(self):
        for name in ['test/Parity.hs', 'test/TerrainEquality.hs', 'afterlight-arena.cabal']:
            with self.subTest(name=name):
                path = self.game / name
                before = path.read_bytes()
                path.write_bytes(before + b'\n')
                self.audit(False)
                path.write_bytes(before)

    def test_missing_manifest(self):
        self.manifest.unlink()
        self.audit(False)

    def test_false_predecessor(self):
        self.mutate_manifest(lambda v: v['files'][0].update(previous_formatted_sha256='0' * 64))
        self.audit(False)

    def test_duplicate_record(self):
        self.mutate_manifest(lambda v: v['files'].append(v['files'][0]))
        self.audit(False)

    def test_out_of_scope_record(self):
        self.mutate_manifest(lambda v: v['files'].append({'path': 'src/Garden/World.hs'}))
        self.audit(False)

    def test_oracle_cannot_be_successor(self):
        self.mutate_manifest(lambda v: v['files'][0].update(path='test/oracle/Original/Garden/World.hs'))
        self.audit(False)

    def test_traversal_cannot_be_successor(self):
        self.mutate_manifest(lambda v: v['files'][0].update(path='test/../src/Garden/World.hs'))
        self.audit(False)

    def test_oracle_tampering(self):
        baseline = json.loads((self.game / 'docs/BASELINE-MANIFEST.json').read_text())
        path = self.game / baseline['oracle'][0]['path']
        path.write_bytes(path.read_bytes() + b'\n')
        self.audit(False)

    def test_unrelated_formatted_source_tampering(self):
        path = self.game / 'src/Garden/World.hs'
        path.write_bytes(path.read_bytes() + b'\n')
        self.audit(False)


if __name__ == '__main__':
    unittest.main()
