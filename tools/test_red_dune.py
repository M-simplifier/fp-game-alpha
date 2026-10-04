"""Offline publication/preservation checks; no game or compiler execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

import formatter
import publication

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT / 'references/red-dune'
ALLOWLIST_SHA = 'cbc89e3ebf906b80d02036700986cffaac0cda01ecd6768aecf3b6666dec8009'
spec = importlib.util.spec_from_file_location('red_dune_restore', REF / 'tools/check.py')
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)


class RedDuneImport(unittest.TestCase):
    def test_exact_selection_and_transfer(self):
        self.assertEqual(hashlib.sha256((REF / 'SOURCE-ALLOWLIST.json').read_bytes()).hexdigest(), ALLOWLIST_SHA)
        names = json.loads((REF / 'SOURCE-ALLOWLIST.json').read_text())['files']
        self.assertEqual(len(names), 194)
        self.assertEqual(len(set(names)), 194)
        selected = {n.removeprefix('references/red-dune/') for n in publication.selected_files()
                    if n.startswith('references/red-dune/')}
        self.assertEqual(selected, set(names))
        provenance = json.loads((ROOT / 'publication/provenance.json').read_text())
        for name in names:
            with self.subTest(path=name):
                data = restore.read_file(REF, name)
                self.assertNotIn('\0', data.decode('utf-8'))
                self.assertEqual(hashlib.sha256(data).hexdigest(),
                                 provenance['references/red-dune/' + name]['transfer_sha256'])
                self.assertFalse(name.endswith('.cbor'))

    def test_original_inputs_and_foundation(self):
        rows = restore.manifest(REF, 'RESTORE-MANIFEST.json')
        decoded = restore.verify_records(REF, rows)
        self.assertEqual(len(decoded), 181)
        originals = [row for file in ['SOURCE-SELECTION.json', 'FIXTURE-SELECTION.json']
                     for row in json.loads((REF / file).read_text())['files']]
        self.assertEqual(len(originals), 178)
        self.assertEqual(len({row['path'] for row in originals}), 178)
        original_names = {row['path'] for row in originals}
        original_rows = [row for row in rows if row['path'] in original_names]
        self.assertEqual(sum(row['encoding'] == 'raw' for row in original_rows), 107)
        self.assertEqual(sum(row['encoding'] == 'base64' for row in original_rows), 71)
        for row in originals:
            self.assertEqual(hashlib.sha256(decoded[row['path']]).hexdigest(), row['sha256'])
        core = restore.verify_records(ROOT, restore.manifest(REF, 'FOUNDATION-MANIFEST.json'), encoded=False)
        self.assertEqual(len(core), 9)

    def test_optional_and_unformatted(self):
        self.assertNotIn('red-dune', (ROOT / 'cabal.project').read_text())
        self.assertFalse(any(p.is_relative_to(REF) for p in formatter.source_files(ROOT)))
        config = json.loads((ROOT / 'formatter.json').read_text())
        self.assertIn('references/red-dune', [r['path'] for r in config['preserved_source_roots']])


if __name__ == '__main__':
    unittest.main()
