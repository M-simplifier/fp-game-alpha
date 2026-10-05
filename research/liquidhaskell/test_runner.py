"""Runner contract tests. These do not execute or stand in for LiquidHaskell."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("lh_runner", Path(__file__).with_name("check.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def result(log, code=0, timed_out=False):
    return {"output": log, "exit_code": code, "timed_out": timed_out}


class RunnerTests(unittest.TestCase):
    def test_source_identity(self):
        self.assertGreater(len(runner.verify_sources()), 100)

    def test_copied_revision_metadata_license_map(self):
        index = json.loads((runner.ROOT / "metadata/licenses/index.json").read_text())
        self.assertEqual(len(index["packages"]), 121)
        retained = set()
        for package in index["packages"]:
            metadata = runner.ROOT / package["cabal_metadata"]
            retained.add(metadata.name)
            self.assertEqual(runner.digest(metadata), package["cabal_metadata_sha256"])
            for notice in package["license_files"]:
                self.assertEqual(runner.digest(runner.ROOT / notice["path"]), notice["sha256"])
            if not package["license_files"]:
                self.assertIn(package["package"], {"monad-loops", "liquidhaskell-boot"})
                self.assertEqual(package["license_declaration_source"], package["cabal_metadata"])
        self.assertEqual(retained, {p.name for p in (runner.ROOT / "metadata/hackage").glob("*.cabal")})

    def test_positive_semantics(self):
        self.assertEqual(runner.classify("Contracts", result("[1 of 1] Compiling Contracts ( source/Contracts.hs, objects/Contracts.o )\nLIQUID: SAFE (23 constraints checked)")), "SAFE")

    def test_negative_semantics(self):
        self.assertEqual(runner.classify("BadAddition", result("[1 of 1] Compiling BadAddition ( source/BadAddition.hs, objects/BadAddition.o )\nLIQUID: UNSAFE\nsource/BadAddition.hs:5: error:\nLiquid Type Mismatch", 1)), "UNSAFE")

    def test_arbitrary_failure_never_negative_control(self):
        self.assertEqual(runner.classify("BadAddition", result("source/BadAddition.hs: cannot find package", 1)), "tool_error")

    def test_wrong_module_is_not_evidence(self):
        self.assertEqual(runner.classify("Contracts", result("source/Other.hs\nLIQUID: SAFE (23 constraints checked)")), "tool_error")

    def test_zero_constraints_is_not_proof(self):
        self.assertEqual(runner.classify("Contracts", result("[1 of 1] Compiling Contracts ( source/Contracts.hs, objects/Contracts.o )\nLIQUID: SAFE (0 constraints checked)")), "tool_error")

    def test_division_observation_is_never_soundness_pass(self):
        self.assertEqual(runner.division_gate("SAFE", True), "failed")
        self.assertEqual(runner.division_gate("UNSAFE", True), "not_established")
        self.assertEqual(runner.division_gate("SAFE", False), "not_established")

    def test_dependency_safe_does_not_validate_zero_target(self):
        log = ("[1 of 2] Compiling Contracts ( source/Contracts.hs, out/Contracts.o )\nLIQUID: SAFE (23 constraints checked)\n"
               "[2 of 2] Compiling CancelLoss ( source/CancelLoss.hs, out/CancelLoss.o )\nLIQUID: SAFE (0 constraints checked)")
        self.assertEqual(runner.classify("CancelLoss", result(log)), "tool_error")

    def test_dependency_unsafe_does_not_validate_target(self):
        log = "source/BadAddition.hs: error: dependency Other failed\nLIQUID: UNSAFE\nOther.hs: Liquid Type Mismatch"
        self.assertEqual(runner.classify("BadAddition", result(log, 1)), "tool_error")

    def test_dependency_safe_and_target_unsafe(self):
        log = ("[1 of 2] Compiling Contracts ( source/Contracts.hs, out/Contracts.o )\nLIQUID: SAFE (23 constraints checked)\n"
               "[2 of 2] Compiling BadCheckedAddition ( source/BadCheckedAddition.hs, out/BadCheckedAddition.o )\n"
               "LIQUID: UNSAFE\nsource/BadCheckedAddition.hs:5: error:\nLiquid Type Mismatch")
        self.assertEqual(runner.classify("BadCheckedAddition", result(log, 1)), "UNSAFE")

    def test_wrong_path_and_duplicate_verdicts(self):
        log = "[1 of 1] Compiling Contracts ( wrong/Contracts.hs, out/Contracts.o )\nLIQUID: SAFE (23 constraints checked)"
        self.assertEqual(runner.classify("Contracts", result(log)), "tool_error")
        log = log.replace("wrong/", "source/") + "\nLIQUID: SAFE (23 constraints checked)"
        self.assertEqual(runner.classify("Contracts", result(log)), "tool_error")

    def test_ambient_options_are_removed(self):
        keys = ("LIQUIDHASKELL_OPTS", "LIQUID_DEV_MODE", "GHCRTS", "GHC_PACKAGE_PATH",
                "liquidhaskell_datadir", "liquidhaskell_boot_datadir", "liquid_fixpoint_datadir")
        with patch.dict(os.environ, dict.fromkeys(keys, "untrusted-inherited-value")):
            env = runner.prepared_environment(Path("/tmp/isolated"), {"GHC": "/opt/bin/ghc"})
        self.assertTrue(all(key not in env for key in keys))
        self.assertEqual(env["HOME"], "/tmp/isolated/home")
        self.assertEqual(env["XDG_CACHE_HOME"], str(Path("/tmp/isolated") / "home" / ".cache"))

    def test_timeout_and_unknown_separate(self):
        self.assertEqual(runner.classify("Contracts", result("", -9, True)), "timeout")
        self.assertEqual(runner.classify("Contracts", result("source/Contracts.hs\nSMT Says: Unknown", 1)), "unknown")

    def test_reject_unsafe_wrong_exit(self):
        self.assertEqual(runner.classify("BadAddition", result("[1 of 1] Compiling BadAddition ( source/BadAddition.hs, objects/BadAddition.o )\nLIQUID: UNSAFE\nsource/BadAddition.hs:5: error:\nLiquid Type Mismatch", 2)), "tool_error")

    def test_required_run_dir(self):
        with self.assertRaises(runner.PrerequisiteError):
            runner.run_path(None)
        with self.assertRaises(runner.PrerequisiteError):
            runner.run_path(str(runner.ROOT / "source"))

    def test_missing_tool(self):
        with patch.dict(os.environ, {"GHC": "/nonexistent/pinned-ghc"}):
            with self.assertRaisesRegex(runner.PrerequisiteError, "GHC is missing"):
                runner.tool_versions()

    def test_wrong_version(self):
        with patch.object(runner.shutil, "which", return_value="/fake/ghc"), patch.object(runner, "execute", return_value=result("9.6.7")):
            with self.assertRaisesRegex(runner.PrerequisiteError, "requires 9.6.3"):
                runner.tool_versions()

    def test_exact_versions(self):
        with patch.object(runner.shutil, "which", return_value="/fake/tool"), patch.object(runner, "execute", side_effect=[result("9.6.3"), result("GHC package manager version 9.6.3"), result("3.16.1.0"), result("Z3 version 4.15.1 - 64 bit")]):
            _, versions = runner.tool_versions()
            self.assertEqual(versions, runner.PINS)

    def test_prepare_does_not_claim_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "run"
            prepared = runner.prepare(path, False)
            self.assertFalse(prepared["compiler_solver_executed"])
            self.assertFalse(prepared["dependencies_verified"])
            with self.assertRaises(runner.PrerequisiteError):
                runner.check_prepared(path)
            with self.assertRaises(runner.PrerequisiteError):
                runner.prepare(path, False)

    def test_environment_uses_isolated_store(self):
        env = runner.prepared_environment(Path("/tmp/example-run"), {"GHC": "/opt/pinned-ghc/bin/ghc"})
        self.assertEqual(env["CABAL_CONFIG"], "/tmp/example-run/cabal-home/config")
        self.assertEqual(env["TMPDIR"], "/tmp/example-run/tmp")
        self.assertNotIn("GHC_PACKAGE_PATH", env)

    def test_reject_changed_input(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "run"
            runner.prepare(path, False)
            (path / "lab/source/Contracts.hs").write_text("changed")
            with self.assertRaisesRegex(runner.PrerequisiteError, "Prepared input mismatch"):
                runner.check_prepared(path)


if __name__ == "__main__":
    unittest.main()
