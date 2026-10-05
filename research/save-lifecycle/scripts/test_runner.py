"""No Java/GHC/download needed: test the public runner's failure boundaries."""
import copy
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from bridge import FIELDS, parse_haskell, validate_row
from run_experiment import (Experiment, ROOT, SUCCESS, classify, expected_runs,
                            parse_counts, verify_sources)


class ClassifierTests(unittest.TestCase):
    def test_success_needs_marker(self):
        self.assertEqual(classify(0, '', 0, (SUCCESS,)), 'tool-error')
        self.assertEqual(classify(0, SUCCESS, 0, (SUCCESS,)), 'passed-scoped')

    def test_counterexample_needs_exact_exit_and_name(self):
        marker = 'Invariant NoStaleSaved is violated.'
        self.assertEqual(classify(12, marker, 12, (marker,), negative=True), 'expected-counterexample')
        self.assertEqual(classify(1, marker, 12, (marker,), negative=True), 'tool-error')
        self.assertEqual(classify(12, 'Invariant TypeOK is violated.', 12, (marker,), negative=True), 'tool-error')

    def test_arbitrary_failure_is_not_counterexample(self):
        self.assertEqual(classify(12, 'JVM failed', 12, ('Invariant NoStaleSaved is violated.',), negative=True), 'tool-error')

    def test_unexpected_acceptance(self):
        self.assertEqual(classify(0, SUCCESS, 12, ('Invariant NoStaleSaved is violated.',), negative=True), 'unexpected-acceptance')

    def test_unknown_and_timeout_remain_distinct(self):
        self.assertEqual(classify(0, 'UNKNOWN'), 'unknown')
        self.assertEqual(classify(12, 'unknown', 12, (), True, True), 'timeout')

    def test_contradictory_success_is_failure(self):
        self.assertEqual(classify(0, SUCCESS + '\nError: invalid model', 0, (SUCCESS,)), 'tool-error')

    def test_jvm_resource_error_is_failure(self):
        self.assertEqual(classify(0, SUCCESS + '\nOutOfMemoryError', 0, (SUCCESS,)), 'tool-error')

    def test_counts(self):
        self.assertEqual(parse_counts('583,932 states generated, 79,227 distinct states found, 0 states left on queue.'),
                         {'generated': 583932, 'distinct': 79227, 'queued': 0})
        self.assertIsNone(parse_counts('incomplete result'))

    def test_required_named_runs(self):
        names = expected_runs()
        self.assertEqual(len(names), 42)
        self.assertEqual(names['unfair-liveness-control'][0], 13)
        self.assertEqual(names['validate-mutantPersist'][0], 11)
        self.assertNotIn('validate-correctedPersist', names)


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.row = json.loads((ROOT / 'fixtures/mutant-epoch.json').read_text())[0]

    def test_exactly_thirteen_fields(self):
        self.assertEqual(len(FIELDS), 13)
        self.assertEqual(validate_row(copy.deepcopy(self.row)), self.row)

    def test_missing_field_rejected(self):
        for field in FIELDS:
            row = copy.deepcopy(self.row)
            del row[field]
            with self.assertRaises(ValueError):
                validate_row(row)

    def test_extra_field_rejected(self):
        with self.assertRaises(ValueError):
            validate_row(dict(self.row, unexpected=1))

    def test_boolean_is_not_integer(self):
        for field in ['epoch', 'branch', 'revision', 'active', 'receipt', 'request']:
            with self.assertRaisesRegex(ValueError, 'non-integer scalar'):
                validate_row(dict(self.row, **{field: True}))

    def test_boolean_numeric_vectors_rejected(self):
        for field in ['captured', 'capturedBranch', 'accepted', 'acceptedEpoch']:
            row = copy.deepcopy(self.row)
            row[field][0] = True
            with self.assertRaises(ValueError):
                validate_row(row)

    def test_bad_domains_rejected(self):
        for field, value in [('saved', 1), ('phase', ['bogus'] * 4), ('event', 'bogus'), ('captured', [0])]:
            with self.assertRaises(ValueError):
                validate_row(dict(self.row, **{field: value}))

    def test_no_observations_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'empty.log'
            path.write_text('some output\n')
            with self.assertRaises(ValueError):
                parse_haskell(path)

    def test_optimized_interpreter_rejected(self):
        result = subprocess.run([sys.executable, '-O', str(ROOT / 'scripts/bridge.py'), '--help'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Python optimization mode is unsupported', result.stderr)

    def test_invalid_typed_reference_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            ref = directory / 'reference.json'
            log = directory / 'haskell.log'
            ref.write_text(json.dumps([dict(self.row, epoch=True)]))
            log.write_text('STATE ' + json.dumps(self.row) + '\n')
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/bridge.py'), 'compare', str(ref), str(log)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('non-integer scalar epoch', result.stderr)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = pathlib.Path(self.temp.name)
        with patch.dict(os.environ, {'GHC': sys.executable, 'GHC_PKG': sys.executable, 'JAVA': sys.executable}):
            self.experiment = Experiment(self.directory)
        for name in ['logs', 'work', 'home', 'tmp']:
            (self.directory / name).mkdir()

    def test_arbitrary_process_error(self):
        with self.assertRaisesRegex(RuntimeError, 'tool-error'):
            self.experiment.run('arbitrary', [sys.executable, '-c', 'raise SystemExit(12)'], expected=12,
                                markers=('Invariant NoStaleSaved is violated.',), negative=True)

    def test_timeout_kills_process_group(self):
        # The grandchild must not live long enough to create its marker.
        marker = self.directory / 'survived'
        child = f'import time,pathlib; time.sleep(0.7); pathlib.Path({str(marker)!r}).write_text("bad")'
        parent = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{child!r}]); time.sleep(10)'
        with self.assertRaisesRegex(RuntimeError, 'timeout'):
            self.experiment.run('timeout', [sys.executable, '-c', parent], timeout=0.15)
        self.assertEqual(self.experiment.runs[-1]['status'], 'timeout')
        time.sleep(0.8)
        self.assertFalse(marker.exists())

    def test_machine_paths_redacted(self):
        log = self.experiment.run('redact', [sys.executable, '-c', f'print({str(self.directory)!r})'])
        self.assertIn('$RUN_DIR', log.read_text())
        self.assertNotIn(str(self.directory), json.dumps(self.experiment.runs))

    def test_failed_final_verification_rewrites_green_receipt(self):
        with patch('run_experiment.verify', side_effect=RuntimeError('deliberate verification failure')):
            with self.assertRaisesRegex(RuntimeError, 'deliberate verification failure'):
                self.experiment.publish({'status': 'passed-scoped'})
        receipt = json.loads((self.directory / 'evidence.json').read_text())
        self.assertEqual(receipt['status'], 'tool-error')
        self.assertIn('deliberate verification failure', receipt['error'])

    def test_bad_jar_fails_without_network(self):
        self.experiment.jar.parent.mkdir()
        self.experiment.jar.write_bytes(b'not TLC')
        with patch('urllib.request.urlopen') as network:
            with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                self.experiment.fetch()
            network.assert_not_called()

    def test_existing_run_is_not_overwritten(self):
        with self.assertRaisesRegex(RuntimeError, 'already contains a run'):
            self.experiment.execute()

    def test_source_tree_cannot_be_run_directory(self):
        with self.assertRaisesRegex(RuntimeError, 'must be outside'):
            Experiment(ROOT / 'unsafe-run')


class SourceTests(unittest.TestCase):
    def test_frozen_identity(self):
        self.assertEqual(verify_sources(), 49)


if __name__ == '__main__':
    unittest.main()
