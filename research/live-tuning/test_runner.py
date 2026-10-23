"""Failure-boundary tests; simulated tool output is never gameplay evidence."""
import importlib.util
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('tuning_check', ROOT / 'check.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_load_protocol_does_not_receive_spaces_from_the_repository_path(self):
        with tempfile.TemporaryDirectory(prefix='tuning caller with spaces ') as temporary:
            root = Path(temporary)
            def observe(command, **kwargs):
                if 'input' in kwargs:
                    self.assertEqual(Path(command[0]).parent, root / '.build')
                    for line in kwargs['input'].splitlines():
                        if line.startswith('load '):
                            self.assertEqual(len(line.split()), 2, line)
                            self.assertFalse(Path(line.split()[1]).is_absolute())
                    raise RuntimeError('load protocol inspected')
                return subprocess.CompletedProcess(command, 0, '')
            with patch.object(runner, 'ROOT', root), patch.object(runner.subprocess, 'run', side_effect=observe), \
                    contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, 'load protocol inspected'):
                runner.main()

    def test_bad_tool_and_host_output_fail_even_with_optimization(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / 'check.py'
            script.write_bytes((ROOT / 'check.py').read_bytes())
            for flags in [[], ['-O']]:
                for code in [0, 23]:
                    probe = ('import runpy,subprocess; from unittest.mock import patch; '
                             f'result=subprocess.CompletedProcess([], {code}, "wrong host output");\n'
                             'with patch("subprocess.run", return_value=result): '
                             f'runpy.run_path({str(script)!r}, run_name="__main__")')
                    with self.subTest(flags=flags, tool_exit=code):
                        result = subprocess.run([sys.executable, *flags, '-c', probe],
                                                capture_output=True, text=True, timeout=10)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn('PASS:', result.stdout)
                        self.assertIn('RuntimeError', result.stderr)
                        self.assertIn('wrong host output' if code else 'Staging', result.stderr)

    def test_each_admission_and_continuation_check_is_required(self):
        staging = '[.@....G] PLAYING | moves=7 session=r0/8 staged=r1/5'
        restart = '[@.....G] PLAYING | moves=8 session=r0/8 staged=r1/5'
        unchanged = '[.....@G] OUT OF MOVES | moves=0 session=r1/5 staged=r1/5'
        terminal = '[......@] WON | moves=0 session=r2/6 staged=r2/6'
        lines = [staging, restart, *['REJECTED: invalid rules', unchanged] * 7,
                 terminal, terminal]
        runner.verify_host_log('\n'.join(lines))
        bad_logs = [[], lines[1:], [lines[0], *lines[2:]],
                    lines[:2] + lines[4:], lines[:-1],
                    [line.replace('OUT OF MOVES', 'PLAYING') for line in lines],
                    [*lines[:2], 'REJECTED: truncated']]
        for bad in bad_logs:
            with self.subTest(log=bad), self.assertRaises(RuntimeError):
                runner.verify_host_log('\n'.join(bad))

    def test_optimized_benchmark_stops_before_creating_or_rewriting_artifacts(self):
        # Never run a benchmark or refresh the curated measurements in this test.
        probe = ('import runpy; from unittest.mock import patch;\n'
                 'with patch("tempfile.TemporaryDirectory", side_effect=AssertionError("benchmark body ran")): '
                 f'runpy.run_path({str(ROOT / "bench.py")!r}, run_name="__main__")')
        result = subprocess.run([sys.executable, '-O', '-c', probe],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('benchmark observations require assertions', result.stderr)
        self.assertNotIn('AssertionError: benchmark body ran', result.stderr)


if __name__ == '__main__':
    unittest.main()
