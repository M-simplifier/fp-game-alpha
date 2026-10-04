#!/usr/bin/env python3
import base64
import hashlib
from pathlib import Path
import tempfile
import unittest
from check import verify_records, write_files


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = b"\x00binary\xff\r\nkept\r\n"
        (self.root / "payload").write_bytes(base64.b64encode(self.data) + b"\n")
        self.row = dict(path="data/input.cbor", stored="payload", encoding="base64",
                        sha256=hashlib.sha256(self.data).hexdigest(), bytes=len(self.data))

    def test_binary_roundtrip(self):
        files = verify_records(self.root, [self.row])
        write_files(self.root / "output", files)
        self.assertEqual((self.root / "output/data/input.cbor").read_bytes(), self.data)
        with self.assertRaises(FileExistsError):
            write_files(self.root / "output", files)

    def test_bad_base64(self):
        (self.root / "payload").write_bytes(b"@@@\n")
        with self.assertRaises(ValueError):
            verify_records(self.root, [self.row])

    def test_corrupt_valid_payload(self):
        (self.root / "payload").write_bytes(base64.b64encode(b"changed") + b"\n")
        with self.assertRaises(ValueError):
            verify_records(self.root, [self.row])

    def test_noncanonical_encoding(self):
        for payload in [b"Zg==", b"Zg==\n\n", b"Zh==\n"]:
            (self.root / "payload").write_bytes(payload)
            with self.assertRaises(ValueError):
                verify_records(self.root, [self.row])

    def test_bad_hash_or_size(self):
        for field, value in [("sha256", "0" * 64), ("bytes", len(self.data) + 1)]:
            with self.assertRaises(ValueError):
                verify_records(self.root, [dict(self.row, **{field: value})])

    def test_traversal(self):
        for name in [".", "..", "../escape", "/absolute", "data/../escape", "a//b", "a/./b", "a\\b"]:
            for field in ("path", "stored"):
                with self.assertRaises(ValueError):
                    verify_records(self.root, [dict(self.row, **{field: name})])

    def test_duplicate_and_conflict(self):
        with self.assertRaises(ValueError):
            verify_records(self.root, [self.row, self.row])
        (self.root / "payload2").write_bytes((self.root / "payload").read_bytes())
        with self.assertRaises(ValueError):
            verify_records(self.root, [dict(self.row, path="a"), dict(self.row, stored="payload2", path="a/b")])

    def test_symlink(self):
        (self.root / "link").symlink_to(self.root / "payload")
        with self.assertRaises(ValueError):
            verify_records(self.root, [dict(self.row, stored="link")])


if __name__ == "__main__":
    unittest.main()
