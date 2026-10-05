#!/usr/bin/env python3
"""Reproduce the seven pinned, selected-binder LiquidHaskell observations.

No installation is performed. Use the prepared sibling LiquidHaskell laboratory.
Recovered PASS files are never consulted as evidence for this invocation.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
RECOVERED = ROOT / "recovered"
FIXTURE_HASH = "082f8af0cb1a2de3e4faa62753b31a2d263e232fd729f318ac9d58a813f9ef75"
ANNOTATED_HASH = "d90d4fce3bf1d6220a4366b4d05316002919b5c6e50b7d4b9e43ef9571c8d46d"
PINS = {"GHC": "9.6.3", "GHC_PKG": "9.6.3", "CABAL": "3.16.1.0", "Z3": "4.15.1"}
PACKAGE_PINS = {"liquidhaskell": "0.9.6.3.1", "liquidhaskell-boot": "0.9.6.3", "liquid-fixpoint": "0.9.6.3"}
IGNORED_ENV = ("LIQUIDHASKELL_OPTS", "LIQUID_DEV_MODE", "GHC_PACKAGE_PATH", "GHCRTS",
               "liquidhaskell_datadir", "liquidhaskell_boot_datadir", "liquid_fixpoint_datadir")
BINDERS = ("quantityMax", "mkQty", "qtyValue", "zeroQty", "addQty", "subQty")
MUTATIONS = {
    "add-plus-one": ("addQty a b = mkQty (qtyValue a + qtyValue b)", "addQty a b = mkQty (qtyValue a + qtyValue b + 1)"),
    "sub-plus-one": ("subQty a b = mkQty (qtyValue a - qtyValue b)", "subQty a b = mkQty (qtyValue a - qtyValue b + 1)"),
    "upper-reversed": ('| n > quantityMax = Left "QuantityOverflow"', '| n < quantityMax = Left "QuantityOverflow"'),
    "upper-off-by-one": ('| n > quantityMax = Left "QuantityOverflow"', '| n >= quantityMax = Left "QuantityOverflow"'),
    "always-left": ('| otherwise = Right (Qty (fromInteger n))', '| otherwise = Left "QuantityOverflow"'),
    "missing-lower": ('| n < 0 = Left "QuantityUnderflow"', '| n < 0 = Right (Qty (fromInteger n))'),
}
CASES = ("good", *MUTATIONS)
PROCESS_TIMEOUT = 180
REPLAY_TIMEOUT = 90
MODEL_TIMEOUT = 30
SMT_CASES = {
    "01_max_fits_Int64": "unsat",
    "02_valid_add_no_Int64_overflow": "unsat",
    "03_valid_sub_no_Int64_overflow": "unsat",
    "04_add_acceptance_iff": "unsat",
    "05_sub_acceptance_iff": "unsat",
    "06_accepted_Int64_roundtrip": "unsat",
    "07_accepted_bits_sign_is_nonnegative": "unsat",
    "08_bounded_bv_add_cannot_wrap": "unsat",
    "09_cast_before_check_is_unsound_witness": "sat",
}
SCOPE = "Six selected quantity binders; pinned trusted imports and translation. Not full-module/game soundness, universal runtime equivalence, or machine-semantics proof."
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
COMPILING = re.compile(r"(?m)^\[\s*\d+\s+of\s+\d+\]\s+Compiling\s+(\S+)\s+\(([^\n]*)$")


class CheckError(RuntimeError):
    status = "check_error"


class PrerequisiteError(CheckError):
    status = "prerequisite_error"


class IntegrityError(CheckError):
    status = "integrity_error"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def verify_sources(root=ROOT):
    """Verify every transported input and all six exact one-edit mutants."""
    recovered = root / "recovered"
    provenance = json.loads((root / "provenance.json").read_text())
    records = provenance["records"]
    expected_paths = set()
    for record in records:
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != "recovered":
            raise IntegrityError("Invalid provenance path")
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise IntegrityError(f"Missing or symlinked recovered source: {relative}")
        if sha256(path) != record["packed_sha256"] or sha256(path) != record["destination_sha256"]:
            raise IntegrityError(f"Changed recovered source: {relative}")
        if relative.as_posix() in expected_paths:
            raise IntegrityError(f"Duplicate provenance path: {relative}")
        expected_paths.add(relative.as_posix())
    actual_paths = {p.relative_to(root).as_posix() for p in recovered.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
    if actual_paths != expected_paths:
        raise IntegrityError("Recovered file set differs from provenance")
    for record in provenance.get("adaptations", []):
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise IntegrityError("Invalid adapted-input path")
        path = root / relative
        if not path.is_file() or path.is_symlink() or sha256(path) != record["destination_sha256"]:
            raise IntegrityError(f"Adapted input differs: {relative}")
    original = (recovered / "fixtures/Colony/Units.hs").read_bytes()
    annotated = (recovered / "source/Colony/Units.hs").read_bytes()
    annotations = (recovered / "metadata/annotations.lh").read_bytes()
    if hashlib.sha256(original).hexdigest() != FIXTURE_HASH or hashlib.sha256(annotated).hexdigest() != ANNOTATED_HASH:
        raise IntegrityError("Frozen or annotated source identity changed")
    if annotated != original + annotations or re.sub(rb"\{-@.*?@-\}", b"", annotations, flags=re.S).strip():
        raise IntegrityError("Annotated source is not the exact fixture plus annotation-only suffix")
    if re.search(rb"\b(assume|ignore|unsafeCoerce|div|mod|lazy)\b", annotated):
        raise IntegrityError("Unexpected assumption or unsafe operation in checked source")
    for case, (old, new) in MUTATIONS.items():
        if annotated.count(old.encode()) != 1:
            raise IntegrityError(f"Mutation input not unique: {case}")
        expected = annotated.replace(old.encode(), new.encode())
        if (recovered / "mutations" / case / "Colony/Units.hs").read_bytes() != expected:
            raise IntegrityError(f"Mutation differs from historical one-edit case: {case}")
    return {"status": "exact_match", "files": len(records), "fixture_sha256": FIXTURE_HASH,
            "annotated_sha256": ANNOTATED_HASH, "historical_evidence_used_as_current": False}


def invoke(command, *, cwd, env, timeout):
    """Bound the entire tool process group, including solver grandchildren."""
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        return {"exit_code": process.returncode, "output": output, "timed_out": False}
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = process.communicate()
        return {"exit_code": process.returncode, "output": output, "timed_out": True}


def checked_output(command, *, cwd, env, timeout=30):
    result = invoke(command, cwd=cwd, env=env, timeout=timeout)
    output = result["output"].decode("utf-8", errors="replace")
    if result["timed_out"] or result["exit_code"] != 0:
        raise PrerequisiteError(f"Prerequisite command failed: {command!r}: {output[-3000:]}")
    return output.strip()


def tool_versions(environ=None):
    environ = os.environ.copy() if environ is None else environ.copy()
    if os.name != "posix":
        raise PrerequisiteError("This process-group runner requires POSIX; Windows is not certified")
    tools, versions = {}, {}
    for key, default in (("GHC", "ghc"), ("GHC_PKG", "ghc-pkg"), ("CABAL", "cabal"), ("Z3", "z3")):
        value = environ.get(key, default)
        executable = shutil.which(value, path=environ.get("PATH", ""))
        if executable is None:
            raise PrerequisiteError(f"Missing {key}; set {key} to the pinned executable ({PINS[key]})")
        # Preserve the configured compiler path so Cabal reuses the prepared
        # plan instead of treating an equivalent versioned symlink as a change.
        tools[key] = str(Path(executable).absolute())
        flag = "--version" if key in ("GHC_PKG", "Z3") else "--numeric-version"
        output = checked_output([tools[key], flag], cwd=ROOT, env=environ)
        if key == "Z3":
            match = re.fullmatch(r"Z3 version ([0-9.]+)(?:\s+[^\n]*)?", output)
        elif key == "GHC_PKG":
            match = re.fullmatch(r"GHC package manager version ([0-9.]+)", output)
        else:
            match = re.fullmatch(r"([0-9.]+)", output)
        version = match.group(1) if match else None
        if version != PINS[key]:
            raise PrerequisiteError(f"{key} must be {PINS[key]}; observed {output!r}")
        versions[key] = version
    return tools, versions


def prepared_environment(lh_run_dir, tools):
    lab = lh_run_dir / "lab"
    config = lh_run_dir / "cabal-home/config"
    for path in (lab / "cabal.project", lab / "cabal.project.freeze", config):
        if not path.is_file():
            raise PrerequisiteError(f"Missing prepared input: {path}; run the sibling LiquidHaskell setup/build first")
    for path in (lab / "source", lab / "vendor", *package_databases(lh_run_dir)):
        if not path.is_dir():
            raise PrerequisiteError(f"Missing prepared dependency directory: {path}")
    env = clean_environment(os.environ)
    env.update(tools)
    env.update({"CABAL_DIR": str(lh_run_dir / "cabal-home"), "CABAL_CONFIG": str(config),
                "GHC_ENVIRONMENT": "-"})
    env["PATH"] = os.pathsep.join([str(Path(tools["GHC"]).parent), env.get("PATH", "")])
    for package, version in PACKAGE_PINS.items():
        datadir = lab / "vendor" / f"{package}-{version}"
        if not datadir.is_dir():
            raise PrerequisiteError(f"Missing pinned package source/data directory: {datadir}")
        env[package.replace("-", "_") + "_datadir"] = str(datadir)
    trusted = json.loads((ROOT / "trusted-imports.json").read_text())
    for record in trusted:
        relative = record["path"]
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise IntegrityError("Invalid trusted import path")
        snapshot = RECOVERED / "metadata/trusted-source" / relative
        if not snapshot.is_file() or sha256(snapshot) != record["sha256"]:
            raise IntegrityError(f"Trusted source snapshot differs: {relative}")
        path = lab / "vendor" / relative
        if not path.is_file() or sha256(path) != record["sha256"]:
            raise PrerequisiteError(f"Pinned trusted import differs or is missing: {relative}")
    return env


def clean_environment(environ):
    """Prevent ambient options from silently changing the logical experiment."""
    env = dict(environ)
    for key in IGNORED_ENV:
        env.pop(key, None)
    return env


def verify_lh_preparation(lh_run_dir):
    """Use the sibling's current, hash-verified preparation contract."""
    path = ROOT.parents[1] / "liquidhaskell/check.py"
    if not path.is_file():
        raise PrerequisiteError("The sibling LiquidHaskell source/preparation runner is missing")
    spec = importlib.util.spec_from_file_location("quantity_lh_preparation", path)
    if spec is None or spec.loader is None:
        raise PrerequisiteError("Cannot load the sibling preparation checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        prepared = module.check_prepared(lh_run_dir)
    except module.PrerequisiteError as error:
        raise PrerequisiteError(str(error)) from error
    verify_build_record(lh_run_dir)
    return {"status": prepared["status"], "dependencies_verified": prepared["dependencies_verified"]}


def verify_build_record(lh_run_dir):
    build_record = lh_run_dir / "build-result.json"
    if not build_record.is_file():
        raise PrerequisiteError("The sibling plugin build has no terminal result; finish that build first")
    built = json.loads(build_record.read_text())
    if built.get("status") != "built" or built.get("versions") != PINS or built.get("packages") != PACKAGE_PINS:
        raise PrerequisiteError("The sibling plugin build has not recorded success with the exact tool/package pins")
    return built


def package_databases(lh_run_dir):
    return (lh_run_dir / "cabal-store/ghc-9.6.3/package.db",
            lh_run_dir / "lab/dist-newstyle/packagedb/ghc-9.6.3")


def cabal_command(lh_run_dir, tools, arguments):
    return [tools["CABAL"], "exec", "--offline", "--verbose=0",
            "--project-file=" + str(lh_run_dir / "lab/cabal.project"),
            "--with-compiler=" + tools["GHC"], "--with-hc-pkg=" + tools["GHC_PKG"],
            "--", *arguments]


def check_packages(lh_run_dir, tools, env):
    databases = ["--package-db=" + str(path) for path in package_databases(lh_run_dir)]
    observed = {}
    for name, version in PACKAGE_PINS.items():
        # Cabal 3.16 rewrites a direct ghc-pkg command as if it were GHC and
        # injects -package-env, which ghc-pkg does not accept. An argv-only
        # exec trampoline retains Cabal's environment without that rewriting.
        command = cabal_command(lh_run_dir, tools, [sys.executable, "-c",
                                                 "import os,sys; os.execv(sys.argv[1],sys.argv[1:])",
                                                 tools["GHC_PKG"], "--no-user-package-db", *databases,
                                                 "field", name, "version", "--simple-output"])
        output = checked_output(command, cwd=lh_run_dir / "lab", env=env, timeout=PROCESS_TIMEOUT)
        if output != version:
            raise PrerequisiteError(f"Expected exactly {name} {version} in prepared package databases; got {output!r}")
        observed[name] = output
    return observed


def compile_command(lh_run_dir, tools, source, outputdir):
    arguments = [tools["GHC"], "--make", "-fforce-recomp", "-O0", "-no-user-package-db"]
    for database in package_databases(lh_run_dir):
        arguments.extend(["-package-db", str(database)])
    arguments.extend(["-package", "liquidhaskell", "-fplugin=LiquidHaskell",
                      "-fplugin-opt=LiquidHaskell:--total-Haskell",
                      "-fplugin-opt=LiquidHaskell:--savequery",
                      "-fplugin-opt=LiquidHaskell:--smttimeout=15000"])
    arguments.extend("-fplugin-opt=LiquidHaskell:--check-var=" + binder for binder in BINDERS)
    arguments.extend(["-i" + str(source.parent), "-outputdir", str(outputdir), "-c", str(source),
                      "+RTS", "-K256m", "-RTS"])
    return cabal_command(lh_run_dir, tools, arguments)


def target_block(text, expected_source=None):
    """Associate diagnostics with the actual compiled target, not an import."""
    headers = list(COMPILING.finditer(text))
    targets = []
    for index, header in enumerate(headers):
        if header.group(1) != "Colony.Units":
            continue
        source = header.group(2).split(",", 1)[0].strip().strip('"')
        matches = source == str(expected_source) if expected_source is not None else source.replace("\\", "/").endswith("Colony/Units.hs")
        if matches:
            stop = headers[index + 1].start() if index + 1 < len(headers) else len(text)
            targets.append(text[header.end():stop])
    return targets[0] if len(targets) == 1 else None


def classify_case(case, exit_code, output, *, timed_out=False, expected_source=None):
    """A compiler failure is never itself an expected mutant rejection."""
    if case not in CASES:
        raise ValueError(f"Unknown case: {case}")
    text = ANSI.sub("", output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output)
    if timed_out or exit_code == 124:
        return "timeout"
    if re.search(r"(?i)\bunknown\b", text):
        return "unknown"
    if re.search(r"(?i)Stack space overflow|Cannot parse specification|cannot satisfy|Could not find module|Failed to load interface|panic!|unrecognized|internal error|exception|segmentation fault|out of memory|resource exhausted|could not execute|command not found|No such file or directory|SMT.*(?:timeout|timed out)|solver.*(?:timeout|timed out)", text):
        return "tool_error"
    text = target_block(text, expected_source)
    if text is None:
        return "tool_error"
    safe_counts = re.findall(r"LIQUID:\s*SAFE\s*\((\d+) constraints checked\)", text)
    verdicts = re.findall(r"LIQUID:\s*(SAFE|UNSAFE)\b", text)
    mismatch = "Liquid Type Mismatch" in text
    if case == "good":
        binders_seen = all(re.search(r"(?m)^\s*" + re.escape(binder) + r"\s*$", text) for binder in BINDERS)
        if exit_code == 0 and safe_counts == ["25"] and verdicts == ["SAFE"] and not mismatch and binders_seen:
            return "SAFE25"
        return "unexpected_result" if exit_code == 0 else "tool_error"
    if exit_code == 1 and verdicts == ["UNSAFE"] and mismatch and not safe_counts:
        return "UNSAFE"
    if exit_code == 0:
        return "unexpected_acceptance"
    return "tool_error"


def check_replay_output(query, captured, result):
    if result["timed_out"]:
        return "timeout", []
    actual = result["output"]
    answers = re.findall(rb"(?m)^(sat|unsat|unknown)\r?$", actual)
    if b"unknown" in answers:
        return "unknown", answers
    if result["exit_code"] != 0 or b"(error" in actual:
        return "tool_error", answers
    if actual.strip() != captured.strip() or len(answers) != query.count(b"(check-sat)"):
        return "replay_mismatch", answers
    return "EXACT_REPLAY_MATCH", answers


def classify_model(expected, result):
    output = result["output"].strip()
    if result["timed_out"]:
        return "timeout"
    if output == b"unknown":
        return "unknown"
    if result["exit_code"] != 0 or b"(error" in output:
        return "tool_error"
    if output != expected.encode("ascii"):
        return "unexpected_result"
    return "expected_SAT_counterexample" if expected == "sat" else "expected_UNSAT"


def check_models(run_dir, tools, env):
    results = []
    directory = run_dir / "smt-models"
    directory.mkdir()
    for name, expected in SMT_CASES.items():
        source = directory / (name + ".smt2")
        shutil.copyfile(RECOVERED / "runtime-validation/smt" / source.name, source)
        result = invoke([tools["Z3"], str(source)], cwd=run_dir, env=env, timeout=MODEL_TIMEOUT)
        (directory / (name + ".log")).write_bytes(result["output"])
        results.append({"case": name, "expected": expected, "status": classify_model(expected, result),
                        "exit_code": result["exit_code"], "timed_out": result["timed_out"],
                        "source_sha256": sha256(source), "process_timeout_seconds": MODEL_TIMEOUT})
    return results


def replay_case(case, run_dir, tools, env):
    directory = run_dir / "logs/solver-capture" / case
    streams = sorted(directory.glob("*.stdin.smt2"))
    if not streams:
        return [{"case": case, "status": "missing_capture"}]
    results = []
    for stream in streams:
        key = stream.name.removesuffix(".stdin.smt2")
        record = {"case": case, "stream": str(stream.relative_to(run_dir))}
        stdout = directory / (key + ".stdout.log")
        stderr = directory / (key + ".stderr.log")
        exit_file = directory / (key + ".exit")
        if not stdout.is_file() or not stderr.is_file() or stderr.read_bytes():
            results.append({**record, "status": "capture_error"})
            continue
        captured_exit = exit_file.read_text().strip() if exit_file.exists() else None
        if captured_exit not in (None, "0"):
            results.append({**record, "status": "capture_error", "captured_exit": captured_exit})
            continue
        result = invoke([tools["Z3"], str(stream)], cwd=run_dir, env=env, timeout=REPLAY_TIMEOUT)
        (directory / (key + ".replay.log")).write_bytes(result["output"])
        status, answers = check_replay_output(stream.read_bytes(), stdout.read_bytes(), result)
        results.append({**record, "status": status, "queries": len(answers),
                        "sat": answers.count(b"sat"), "unsat": answers.count(b"unsat"),
                        "captured_exit": captured_exit, "replay_exit": result["exit_code"]})
    if sum(result.get("queries", 0) for result in results) == 0:
        results.append({"case": case, "status": "missing_solver_answers"})
    return results


def initial_report(command):
    return {"schema": "quantity-lh-run-v1", "command": command, "status": "running",
            "started_utc": datetime.now(timezone.utc).isoformat(), "scope": SCOPE,
            "runner_sha256": sha256(__file__), "provenance_sha256": sha256(ROOT / "provenance.json"),
            "ignored_inherited_environment": list(IGNORED_ENV),
            "historical_evidence_is_current_run": False,
            "runtime_oracle": "not_run_by_this_checker", "historical_whole_tree_audit": "not_available",
            "lh": [{"case": case, "status": "not_run", "expected": "SAFE25" if case == "good" else "UNSAFE"} for case in CASES],
            "solver_replay": [], "smt_models": [], "all_named_observations_matched": False}


def fresh_run_directory(requested):
    if requested:
        path = Path(requested).resolve()
        # Neither source tree nor shared prepared laboratory may be used as output.
        if path == ROOT or ROOT in path.parents:
            raise PrerequisiteError("RUN_DIR must be outside the maintained checker source tree")
        if path.exists() and any(path.iterdir()):
            raise PrerequisiteError(f"RUN_DIR must be new or empty, preserving earlier evidence: {path}")
        path.mkdir(parents=True, exist_ok=True)
        return path
    parent = REPO / ".build/quantity-lh"
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="run-", dir=parent))


def run(args):
    if args.command == "source-check":
        try:
            print(json.dumps(verify_sources(), indent=2))
            return 0
        except (CheckError, OSError, ValueError, KeyError) as error:
            print(json.dumps({"status": "integrity_error", "error": str(error)}))
            return 1
    try:
        run_dir = fresh_run_directory(args.run_dir or os.environ.get("RUN_DIR"))
    except (CheckError, OSError) as error:
        print(json.dumps({"status": "prerequisite_error", "error": str(error)}))
        return 2
    report = initial_report(args.command)
    report["run_dir"] = str(run_dir)
    write_json(run_dir / "result.json", report)
    exit_code = 1
    try:
        report["source_identity_before"] = verify_sources()
        tools, versions = tool_versions()
        report["tools"], report["versions"] = tools, versions
        supplied = args.lh_run_dir or os.environ.get("LH_RUN_DIR")
        if not supplied:
            raise PrerequisiteError("Pass --lh-run-dir (or LH_RUN_DIR) for the sibling's already prepared and built laboratory")
        lh_run_dir = Path(supplied).resolve()
        if run_dir == lh_run_dir or lh_run_dir in run_dir.parents or run_dir in lh_run_dir.parents:
            raise PrerequisiteError("Quantity RUN_DIR and LH_RUN_DIR must be disjoint")
        report["lh_run_dir"] = str(lh_run_dir)
        report["lh_preparation"] = verify_lh_preparation(lh_run_dir)
        env = prepared_environment(lh_run_dir, tools)
        temporary = run_dir / "tmp"
        temporary.mkdir()
        env.update({"TMPDIR": str(temporary), "TMP": str(temporary), "TEMP": str(temporary)})
        for variable, directory in (("HOME", "home"), ("XDG_CONFIG_HOME", "xdg/config"),
                                    ("XDG_CACHE_HOME", "xdg/cache"), ("XDG_DATA_HOME", "xdg/data"),
                                    ("XDG_STATE_HOME", "xdg/state")):
            path = run_dir / directory
            path.mkdir(parents=True)
            env[variable] = str(path)
        report["packages"] = check_packages(lh_run_dir, tools, env)
        if args.command == "doctor":
            report["status"] = "ready"
            exit_code = 0
        else:
            for directory in ("source", "mutations"):
                shutil.copytree(RECOVERED / directory, run_dir / directory)
            (run_dir / "bin").mkdir()
            (run_dir / "logs").mkdir()
            wrapper = run_dir / "bin/z3"
            shutil.copyfile(RECOVERED / "scripts/capture-z3.py", wrapper)
            wrapper.chmod(0o755)
            if Path(tools["Z3"]).resolve() == wrapper.resolve():
                raise PrerequisiteError("Z3_REAL cannot refer to its capture wrapper")
            env["PATH"] = str(run_dir / "bin") + os.pathsep + env["PATH"]
            env["Z3_REAL"] = tools["Z3"]
            report["capture_wrapper_sha256"] = sha256(wrapper)
            report["smt_models"] = check_models(run_dir, tools, env)
            for index, case in enumerate(CASES):
                source = run_dir / ("source" if case == "good" else "mutations/" + case) / "Colony/Units.hs"
                outputdir = run_dir / "build" / case
                outputdir.mkdir(parents=True)
                captures = run_dir / "logs/solver-capture" / case
                captures.mkdir(parents=True)
                case_env = {**env, "Z3_CAPTURE_DIR": str(captures)}
                command = compile_command(lh_run_dir, tools, source, outputdir)
                result = invoke(command, cwd=lh_run_dir / "lab", env=case_env, timeout=PROCESS_TIMEOUT)
                log = run_dir / "logs" / (case + ".log")
                log.write_bytes(result["output"])
                status = classify_case(case, result["exit_code"], result["output"], timed_out=result["timed_out"], expected_source=source)
                queries = [source.parent / ".liquid" / (source.name + extension) for extension in (".fq", ".smt2")]
                query_hashes = {str(path.relative_to(run_dir)): sha256(path) for path in queries if path.is_file() and path.stat().st_size > 0}
                report["lh"][index].update({"status": status, "exit_code": result["exit_code"],
                    "timed_out": result["timed_out"], "log": str(log.relative_to(run_dir)), "command": command,
                    "process_timeout_seconds": PROCESS_TIMEOUT, "source_sha256": sha256(source),
                    "query_files_present": len(query_hashes) == 2, "query_sha256": query_hashes})
                report["solver_replay"].extend(replay_case(case, run_dir, tools, env))
                write_json(run_dir / "result.json", report)
                print(f"{case}: {status}", flush=True)
            report["source_identity_after"] = verify_sources()
            report["lh_preparation_after"] = verify_lh_preparation(lh_run_dir)
            for case in CASES:
                rel = ("source" if case == "good" else "mutations/" + case) + "/Colony/Units.hs"
                if sha256(run_dir / rel) != sha256(RECOVERED / rel):
                    raise IntegrityError(f"Staged checked source changed during execution: {case}")
            matched = all(case["status"] == case["expected"] and case["query_files_present"] for case in report["lh"])
            replayed = bool(report["solver_replay"]) and all(item["status"] == "EXACT_REPLAY_MATCH" for item in report["solver_replay"])
            models_matched = len(report["smt_models"]) == len(SMT_CASES) and all(item["status"] in ("expected_UNSAT", "expected_SAT_counterexample") for item in report["smt_models"])
            report["all_named_observations_matched"] = matched
            report["status"] = "PASS_SCOPED_LH_REPLAY_AND_MODELS" if matched and replayed and models_matched else "failed"
            exit_code = 0 if matched and replayed and models_matched else 1
    except (CheckError, OSError, ValueError, KeyError) as error:
        report["status"] = error.status if isinstance(error, CheckError) else "tool_error"
        report["error"] = str(error)
        exit_code = 2 if isinstance(error, PrerequisiteError) else 1
    finally:
        report["finished_utc"] = datetime.now(timezone.utc).isoformat()
        write_json(run_dir / "result.json", report)
    print(json.dumps({"status": report["status"], "result": str(run_dir / "result.json"),
                      "error": report.get("error")}, indent=2))
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("source-check", "doctor", "check"))
    parser.add_argument("--lh-run-dir", help="Already prepared/built sibling LiquidHaskell run directory")
    parser.add_argument("--run-dir", help="Fresh quantity output directory (or RUN_DIR); defaults to a unique .build/quantity-lh/run-*")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
