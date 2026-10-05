"""Wrapper falsifications; no solver or compiler is needed."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('sbv_runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class GateTests(unittest.TestCase):
    def test_exact_result_map(self):
        runner.check_results(dict(runner.EXPECTED))

    def test_unknown_error_missing_extra_and_false_positive(self):
        for value in ('unknown', 'error', 'sat', None, True):
            bad = dict(runner.EXPECTED)
            bad['integer_bounds_general'] = value
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                runner.check_results(bad)
        for bad in ({}, {**runner.EXPECTED, 'extra': 'unsat'}):
            with self.assertRaises(RuntimeError): runner.check_results(bad)

    def test_aggregate_marker_alone_cannot_pass(self):
        for text in ('REPLAY_PASS', 'ASSERTIONS_TOTAL 127011\nREPLAY_PASS', ''):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                runner.check_replay(text)

    def test_immutable_original_inputs(self):
        self.assertGreater(len(runner.verify_inputs()), 30)

    def test_nonempty_run_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'keep').write_text('existing result')
            with self.assertRaises(RuntimeError): runner.Run(Path(directory), 'doctor', 'public')
            self.assertEqual((Path(directory) / 'keep').read_text(), 'existing result')

    def test_timeout_is_not_a_counterexample(self):
        with tempfile.TemporaryDirectory() as directory:
            run = runner.Run(Path(directory) / 'run', 'doctor', 'public')
            with self.assertRaises(RuntimeError):
                run.command('timeout-test', [sys.executable, '-c', 'import time; time.sleep(20)'], timeout=0.1)
            self.assertEqual(run.receipt['commands'][0]['status'], 'timeout')
            self.assertTrue(run.receipt['commands'][0]['timed_out'])

    def test_nonzero_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            run = runner.Run(Path(directory) / 'run', 'doctor', 'public')
            with self.assertRaises(RuntimeError):
                run.command('bad-exit', [sys.executable, '-c', 'print("unsat"); raise SystemExit(7)'])
            self.assertEqual(run.receipt['commands'][0]['exit_code'], 7)
            self.assertEqual(run.receipt['commands'][0]['status'], 'tool-error')

    def test_tool_paths_are_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            run = runner.Run(Path(directory) / 'run', 'doctor', 'public')
            run.tool_paths[str(Path(directory) / 'bin/ghc')] = 'GHC'
            run.tool_paths[str(Path(directory) / 'bin/ghc-pkg')] = 'GHC_PKG'
            self.assertEqual(run.redact(str(Path(directory) / 'bin/ghc-pkg')), '<GHC_PKG>')


@unittest.skipUnless(os.environ.get('SBV_VERIFIED_RUN'), 'Set SBV_VERIFIED_RUN after an actual check run')
class ReceiptFalsifications(unittest.TestCase):
    def test_actual_receipt_and_tampering(self):
        source = Path(os.environ['SBV_VERIFIED_RUN']).resolve()
        with contextlib.redirect_stdout(io.StringIO()): runner.verify_receipt(source)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy2(source / 'receipt.json', root / 'receipt.json')
            shutil.copytree(source / 'logs', root / 'logs')
            (root / 'work').mkdir()
            for folder in ('source', 'frozen-0.4', 'metadata', 'logs'):
                shutil.copytree(source / 'work' / folder, root / 'work' / folder)
            shutil.copy2(source / 'work/sbv-cancellation-lab.cabal', root / 'work/sbv-cancellation-lab.cabal')
            plan = Path('work/dist-newstyle/cache/plan.json')
            (root / plan).parent.mkdir(parents=True)
            shutil.copy2(source / plan, root / plan)
            original = json.loads((root / 'receipt.json').read_text())
            changes = {
                'schema': lambda r: r.update(schema='other'),
                'mode': lambda r: r.update(mode='other'),
                'profile': lambda r: r.update(profile='other'),
                'claim': lambda r: r.update(claim='whole-game-proved'),
                'unknown': lambda r: r['solver_results'].update(integer_bounds_general='unknown'),
                'nonzero': lambda r: r['commands'][0].update(exit_code=1),
                'missing-command': lambda r: r['commands'].pop(),
                'tool-version': lambda r: r['versions'].update(ghc='9.6.3'),
                'package-plan': lambda r: r.update(package_versions=[]),
                'bridge-count': lambda r: r.update(sbv_helper_bridge_inputs=1),
            }
            for name, change in changes.items():
                receipt = copy.deepcopy(original)
                change(receipt)
                (root / 'receipt.json').write_text(json.dumps(receipt))
                with self.subTest(name=name), self.assertRaises(RuntimeError):
                    runner.verify_receipt(root)
            (root / 'receipt.json').write_text(json.dumps(original))
            for file in (Path('work/source/Proof.hs'), plan, Path('logs/replay.log')):
                before = (root / file).read_bytes()
                (root / file).write_bytes(before + b'changed')
                with self.subTest(file=str(file)), self.assertRaises(RuntimeError):
                    runner.verify_receipt(root)
                (root / file).write_bytes(before)


if __name__ == '__main__':
    unittest.main()
