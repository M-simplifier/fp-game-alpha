"""Runner contract tests: these do not constitute a LiquidHaskell rerun."""

import argparse
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("quantity_checker", HERE / "check.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)
HEADER = "[1 of 1] Compiling Colony.Units ( /isolated/source/Colony/Units.hs, /isolated/build/Units.o )\n"
SAFE_BODY = "\n".join((*checker.BINDERS, "LIQUID: SAFE (25 constraints checked)")) + "\n"
UNSAFE_BODY = "LIQUID: UNSAFE\nLiquid Type Mismatch\n"
SAFE = HEADER + SAFE_BODY
UNSAFE = HEADER + UNSAFE_BODY


def result(output, code=0, timed_out=False):
    return {"output": output.encode() if isinstance(output, str) else output,
            "exit_code": code, "timed_out": timed_out}


class Sources(unittest.TestCase):
    def test_originals_and_six_mutants_are_exact(self):
        self.assertEqual(checker.verify_sources()["status"], "exact_match")
        self.assertEqual(len(checker.MUTATIONS), 6)
        self.assertEqual(len(checker.SMT_CASES), 9)

    def test_changed_mutant_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copytree(HERE / "recovered", root / "recovered")
            shutil.copyfile(HERE / "provenance.json", root / "provenance.json")
            shutil.copyfile(HERE / "trusted-imports.json", root / "trusted-imports.json")
            path = root / "recovered/mutations/always-left/Colony/Units.hs"
            path.write_bytes(path.read_bytes() + b"\n")
            with self.assertRaises(checker.IntegrityError):
                checker.verify_sources(root)

    def test_no_historical_pass_reports_in_current_inputs(self):
        records = json.loads((HERE / "provenance.json").read_text())["records"]
        self.assertFalse(any("historical-evidence" in row["path"] or "acceptance.json" in row["path"] for row in records))


class Classification(unittest.TestCase):
    def test_good_requires_exact_safe25_and_all_named_binders(self):
        self.assertEqual(checker.classify_case("good", 0, SAFE), "SAFE25")
        self.assertEqual(checker.classify_case("good", 0, SAFE.replace("25", "24")), "unexpected_result")
        self.assertEqual(checker.classify_case("good", 0, SAFE.replace("mkQty\n", "")), "unexpected_result")
        self.assertEqual(checker.classify_case("good", 0, ""), "tool_error")
        self.assertEqual(checker.classify_case("good", 0, SAFE + UNSAFE_BODY), "unexpected_result")

    def test_each_named_mutant_requires_unsafe_and_type_mismatch(self):
        for name in checker.MUTATIONS:
            with self.subTest(name=name):
                self.assertEqual(checker.classify_case(name, 1, UNSAFE), "UNSAFE")
                self.assertEqual(checker.classify_case(name, 1, "LIQUID: UNSAFE"), "tool_error")
                self.assertEqual(checker.classify_case(name, 1, "Liquid Type Mismatch"), "tool_error")
                self.assertEqual(checker.classify_case(name, 1, "Could not find module LiquidHaskell"), "tool_error")
                self.assertEqual(checker.classify_case(name, 2, UNSAFE), "tool_error")
                self.assertEqual(checker.classify_case(name, -11, UNSAFE), "tool_error")
                self.assertEqual(checker.classify_case(name, 0, SAFE), "unexpected_acceptance")

    def test_timeout_and_unknown_never_count_as_rejection(self):
        self.assertEqual(checker.classify_case("always-left", 1, UNSAFE, timed_out=True), "timeout")
        self.assertEqual(checker.classify_case("always-left", 124, UNSAFE), "timeout")
        self.assertEqual(checker.classify_case("always-left", 1, UNSAFE + "unknown\n"), "unknown")
        self.assertEqual(checker.classify_case("always-left", 1, UNSAFE + "SMT Says: Unknown\n"), "unknown")

    def test_crashes_do_not_count_despite_unsafe_marker(self):
        for message in ("Stack space overflow", "Cannot parse specification", "panic!", "cannot satisfy -package liquidhaskell", "solver timed out"):
            with self.subTest(message=message):
                self.assertEqual(checker.classify_case("always-left", 1, UNSAFE + message), "tool_error")

    def test_unknown_case_is_rejected(self):
        with self.assertRaises(ValueError):
            checker.classify_case("new-mutant", 1, UNSAFE)

    def test_ansi_diagnostics(self):
        self.assertEqual(checker.classify_case("good", 0, "\x1b[32m" + SAFE + "\x1b[0m"), "SAFE25")

    def test_dependency_safe_count_cannot_satisfy_target(self):
        imported = "[1 of 2] Compiling Dependency ( Dependency.hs, Dependency.o )\n" + SAFE_BODY
        target = HEADER.replace("[1 of 1]", "[2 of 2]") + SAFE_BODY.replace("25", "0")
        self.assertEqual(checker.classify_case("good", 0, imported + target), "unexpected_result")
        self.assertEqual(checker.classify_case("good", 0, imported + HEADER), "unexpected_result")

    def test_unrelated_mismatch_cannot_satisfy_target(self):
        imported = "[1 of 2] Compiling Dependency ( Dependency.hs, Dependency.o )\n" + UNSAFE_BODY
        self.assertEqual(checker.classify_case("always-left", 1, imported + HEADER + "LIQUID: UNSAFE\n"), "tool_error")
        later = "[2 of 2] Compiling Dependency ( Dependency.hs, Dependency.o )\n" + UNSAFE_BODY
        self.assertEqual(checker.classify_case("always-left", 1, HEADER + "LIQUID: UNSAFE\n" + later), "tool_error")

    def test_actual_case_path_and_unique_target_verdict_are_required(self):
        self.assertEqual(checker.classify_case("good", 0, SAFE, expected_source=Path("/other/mutant/Colony/Units.hs")), "tool_error")
        self.assertEqual(checker.classify_case("good", 0, SAFE + SAFE_BODY), "unexpected_result")
        self.assertEqual(checker.classify_case("always-left", 1, UNSAFE + UNSAFE_BODY), "tool_error")
        self.assertEqual(checker.classify_case("good", 0, SAFE + SAFE), "tool_error")


class Prerequisites(unittest.TestCase):
    def test_ambient_liquid_scope_and_data_overrides_are_removed(self):
        inherited = {name: "untrusted-override" for name in checker.IGNORED_ENV}
        inherited.update(PATH="/tools", LD_LIBRARY_PATH="/native-runtime")
        cleaned = checker.clean_environment(inherited)
        self.assertEqual(cleaned, {"PATH": "/tools", "LD_LIBRARY_PATH": "/native-runtime"})
        self.assertTrue(all(name in inherited for name in checker.IGNORED_ENV))

    def test_missing_tool_fails_closed(self):
        with self.assertRaisesRegex(checker.PrerequisiteError, "Missing GHC"):
            checker.tool_versions({"PATH": ""})

    def test_wrong_tool_versions_fail_closed(self):
        versions = ["9.6.3", "GHC package manager version 9.6.3", "3.16.1.0", "Z3 version 4.15.1 - 64 bit"]
        for index, replacement in enumerate(("9.6.7", "GHC package manager version 9.6.7", "3.12.1.0", "Z3 version 4.15.2 - 64 bit")):
            outputs = versions.copy()
            outputs[index] = replacement
            with self.subTest(tool=index), patch.object(checker.shutil, "which", return_value=sys.executable), patch.object(checker, "checked_output", side_effect=outputs):
                with self.assertRaises(checker.PrerequisiteError):
                    checker.tool_versions({"PATH": ""})

    def test_exact_version_pins(self):
        outputs = ["9.6.3", "GHC package manager version 9.6.3", "3.16.1.0", "Z3 version 4.15.1 - 64 bit"]
        with patch.object(checker.shutil, "which", return_value=sys.executable), patch.object(checker, "checked_output", side_effect=outputs):
            _, versions = checker.tool_versions({"PATH": ""})
        self.assertEqual(versions, checker.PINS)

    def test_missing_prepared_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(checker.PrerequisiteError, "Missing prepared input"):
                checker.prepared_environment(Path(tmp), {})

    def test_sibling_build_must_have_completed_with_all_exact_pins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(checker.PrerequisiteError):
                checker.verify_build_record(root)
            path = root / "build-result.json"
            complete = {"status": "built", "versions": checker.PINS, "packages": checker.PACKAGE_PINS}
            for incomplete in ({"status": "running"}, {**complete, "status": "tool_error"}, {**complete, "packages": {}}):
                path.write_text(json.dumps(incomplete))
                with self.assertRaises(checker.PrerequisiteError):
                    checker.verify_build_record(root)
            path.write_text(json.dumps(complete))
            self.assertEqual(checker.verify_build_record(root), complete)

    def test_package_pins_are_checked_through_offline_cabal_exec(self):
        tools = {name: "/tools/" + name.lower() for name in checker.PINS}
        with patch.object(checker, "checked_output", side_effect=list(checker.PACKAGE_PINS.values())) as command:
            pins = checker.check_packages(Path("/prepared"), tools, {})
        self.assertEqual(pins, checker.PACKAGE_PINS)
        self.assertEqual(command.call_count, 3)
        for call in command.call_args_list:
            args = call.args[0]
            self.assertIn("exec", args)
            self.assertIn("--offline", args)
            self.assertIn("--project-file=/prepared/lab/cabal.project", args)
            self.assertIn("--package-db=/prepared/lab/dist-newstyle/packagedb/ghc-9.6.3", args)
            self.assertIn("--package-db=/prepared/cabal-store/ghc-9.6.3/package.db", args)
            self.assertIn("--no-user-package-db", args)
            self.assertEqual(args[args.index("--") + 1], sys.executable)

    def test_missing_wrong_and_ambiguous_plugin_package_rejected(self):
        tools = {name: "/tools/" + name.lower() for name in checker.PINS}
        for output in ("", "0.9.8.2", "0.9.6.3.1 0.9.6.3.1"):
            with self.subTest(output=output), patch.object(checker, "checked_output", return_value=output):
                with self.assertRaises(checker.PrerequisiteError):
                    checker.check_packages(Path("/prepared"), tools, {})

    def test_exact_compiler_flags_preserved(self):
        tools = {name: "/tools/" + name.lower() for name in checker.PINS}
        command = checker.compile_command(Path("/prepared"), tools, Path("/isolated/source/Colony/Units.hs"), Path("/isolated/build/good"))
        flags = [arg for arg in command if "--check-var=" in arg]
        self.assertEqual(flags, ["-fplugin-opt=LiquidHaskell:--check-var=" + name for name in checker.BINDERS])
        self.assertIn("-fplugin-opt=LiquidHaskell:--total-Haskell", command)
        self.assertIn("-fplugin-opt=LiquidHaskell:--savequery", command)
        self.assertIn("-fplugin-opt=LiquidHaskell:--smttimeout=15000", command)
        self.assertEqual(command[-3:], ["+RTS", "-K256m", "-RTS"])
        self.assertEqual(checker.PROCESS_TIMEOUT, 180)


class ReplayAndModels(unittest.TestCase):
    def test_exact_replay(self):
        query = b"(check-sat)\n(check-sat)\n"
        status, answers = checker.check_replay_output(query, b"sat\nunsat\n", result("sat\nunsat\n"))
        self.assertEqual(status, "EXACT_REPLAY_MATCH")
        self.assertEqual(len(answers), 2)

    def test_replay_rejects_unknown_error_timeout_mismatch_and_truncation(self):
        query = b"(check-sat)\n"
        cases = ((result("unknown"), "unknown"), (result("unsat", 1), "tool_error"),
                 (result("unsat", timed_out=True), "timeout"), (result("sat"), "replay_mismatch"),
                 (result('(error "bad query")'), "tool_error"), (result(""), "replay_mismatch"))
        for actual, expected in cases:
            self.assertEqual(checker.check_replay_output(query, b"unsat", actual)[0], expected)
        self.assertEqual(checker.check_replay_output(query * 2, b"unsat", result("unsat"))[0], "replay_mismatch")

    def test_no_stream_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = checker.replay_case("good", Path(tmp), {}, {})
        self.assertEqual(rows, [{"case": "good", "status": "missing_capture"}])

    def test_named_sat_model_is_required(self):
        self.assertEqual(checker.classify_model("sat", result("sat")), "expected_SAT_counterexample")
        self.assertEqual(checker.classify_model("sat", result("unsat")), "unexpected_result")
        self.assertEqual(checker.classify_model("unsat", result("unsat")), "expected_UNSAT")
        for actual, expected in ((result("unknown"), "unknown"), (result("unsat", 1), "tool_error"), (result("unsat", timed_out=True), "timeout")):
            self.assertEqual(checker.classify_model("unsat", actual), expected)


class Execution(unittest.TestCase):
    def test_existing_run_never_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "result.json").write_text('{"status":"PASS"}')
            with self.assertRaises(checker.PrerequisiteError):
                checker.fresh_run_directory(tmp)

    def test_missing_dependencies_write_failed_result_with_not_run_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            args = argparse.Namespace(command="check", run_dir=str(output), lh_run_dir="/missing")
            with patch.object(checker, "tool_versions", side_effect=checker.PrerequisiteError("Missing GHC")), redirect_stdout(io.StringIO()):
                self.assertEqual(checker.run(args), 2)
            report = json.loads((output / "result.json").read_text())
        self.assertEqual(report["status"], "prerequisite_error")
        self.assertFalse(report["all_named_observations_matched"])
        self.assertTrue(all(case["status"] == "not_run" for case in report["lh"]))

    def test_complete_mock_run_requires_all_results(self):
        # This tests orchestration only; fake compiler output is never research evidence.
        for rejected, expected_exit in ((True, 0), (False, 1)):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                args = argparse.Namespace(command="check", run_dir=str(output), lh_run_dir=str(Path(tmp) / "prepared"))
                tools = {name: "/tools/" + name.lower() for name in checker.PINS}
                def fake_invoke(command, **kwargs):
                    source = Path(command[-4])
                    (source.parent / ".liquid").mkdir()
                    for extension in (".fq", ".smt2"):
                        (source.parent / ".liquid" / (source.name + extension)).write_text("mock query; not research evidence")
                    header = f"[1 of 1] Compiling Colony.Units ( {source}, {source.with_suffix('.o')} )\n"
                    if "/source/" in command[-4]:
                        return result(header + SAFE_BODY)
                    return result(header + UNSAFE_BODY, 1) if rejected else result("could not load package", 1)
                model_rows = [{"case": name, "status": "expected_UNSAT" if expected == "unsat" else "expected_SAT_counterexample"} for name, expected in checker.SMT_CASES.items()]
                with patch.object(checker, "tool_versions", return_value=(tools, checker.PINS)), \
                     patch.object(checker, "verify_lh_preparation", return_value={}), \
                     patch.object(checker, "prepared_environment", return_value={"PATH": ""}), \
                     patch.object(checker, "check_packages", return_value=checker.PACKAGE_PINS), \
                     patch.object(checker, "check_models", return_value=model_rows), \
                     patch.object(checker, "invoke", side_effect=fake_invoke), \
                     patch.object(checker, "replay_case", return_value=[{"status": "EXACT_REPLAY_MATCH", "queries": 1}]), \
                     redirect_stdout(io.StringIO()):
                    self.assertEqual(checker.run(args), expected_exit)
                report = json.loads((output / "result.json").read_text())
                self.assertEqual(report["status"], "PASS_SCOPED_LH_REPLAY_AND_MODELS" if rejected else "failed")
                self.assertEqual(len(report["lh"]), 7)

    @unittest.skipUnless(os.name == "posix", "POSIX process group contract")
    def test_timeout_is_terminal(self):
        actual = checker.invoke([sys.executable, "-c", "import time; time.sleep(10)"], cwd=HERE, env=os.environ.copy(), timeout=0.05)
        self.assertTrue(actual["timed_out"])
        self.assertNotEqual(actual["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
