#!/usr/bin/env python3
"""Opt-in, isolated reproduction of the pinned LiquidHaskell diagnostic.

An observation match is not a soundness pass. The division gate remains failed
when the intentionally false refinement is accepted by the historical stack.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
PINS = {"GHC": "9.6.3", "GHC_PKG": "9.6.3", "CABAL": "3.16.1.0", "Z3": "4.15.1"}
PACKAGE_PINS = {"liquidhaskell": "0.9.6.3.1", "liquidhaskell-boot": "0.9.6.3", "liquid-fixpoint": "0.9.6.3"}
EXPECTED = {"Contracts": "SAFE", "BadAddition": "UNSAFE", "BadSubtraction": "UNSAFE",
            "BadCheckedAddition": "UNSAFE", "VacuousContract": "SAFE", "BadVacuousCall": "UNSAFE",
            "BadTotality": "UNSAFE", "BadTermination": "UNSAFE", "CancelLoss": "SAFE",
            "DivAssumptionProbe": "SAFE", "DivNonzeroProbe": "UNSAFE", "NoDivFalseProbe": "UNSAFE"}
MINIMAL = ("Contracts", "BadAddition", "DivAssumptionProbe", "DivNonzeroProbe", "NoDivFalseProbe")
FLAGS = ["--total-Haskell", "--savequery", "--smttimeout=15000"]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class PrerequisiteError(RuntimeError):
    pass


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def execute(command, *, cwd=None, env=None, timeout=180):
    """Kill the whole Cabal/GHC/solver process group on the POSIX timeout."""
    started = time.monotonic()
    process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=os.name == "posix")
    timed_out = False
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        output, _ = process.communicate()
    return {"exit_code": process.returncode, "timed_out": timed_out,
            "timeout_seconds": timeout, "elapsed_seconds": round(time.monotonic() - started, 3),
            "output": output.decode("utf-8", errors="replace")}


def tool_versions():
    tools, versions = {}, {}
    flags = {"GHC": "--numeric-version", "GHC_PKG": "--version", "CABAL": "--numeric-version", "Z3": "--version"}
    for key, pinned in PINS.items():
        default = str(Path(tools["GHC"]).parent / "ghc-pkg") if key == "GHC_PKG" else key.lower()
        executable = shutil.which(os.environ.get(key, default))
        if not executable:
            raise PrerequisiteError(f"{key} is missing; supply {key} for the pinned {pinned} executable")
        result = execute([executable, flags[key]], timeout=20)
        found = re.search(r"\b(\d+\.\d+\.\d+(?:\.\d+)?)\b", result["output"])
        version = found.group(1) if found else None
        if result["timed_out"] or result["exit_code"] != 0 or version != pinned:
            raise PrerequisiteError(f"{key} requires {pinned}; found {version or 'unrecognized/error'}")
        tools[key], versions[key] = str(Path(executable).absolute()), version
    return tools, versions


def verify_sources():
    provenance = json.loads((ROOT / "provenance.json").read_text())
    hashes = {}
    for row in provenance["records"]:
        path = ROOT / row["published_path"]
        if not path.is_file() or digest(path) != row["published_sha256"]:
            raise PrerequisiteError(f"Source integrity mismatch: {row['published_path']}")
        hashes[row["published_path"]] = row["published_sha256"]
    return hashes


def run_path(value):
    if not value:
        raise PrerequisiteError("Supply --run-dir or RUN_DIR; no implicit in-tree build directory is used")
    path = Path(value).expanduser().resolve()
    # An ignored repository-level .build path is allowed; immutable inputs are not.
    if path == ROOT or ROOT in path.parents or path in ROOT.parents:
        raise PrerequisiteError("RUN_DIR must be separate from the experiment's immutable source tree")
    return path


def prepared_environment(run_dir, tools):
    env = os.environ.copy()
    home = run_dir / "cabal-home"
    env.update({"CABAL_DIR": str(home), "CABAL_CONFIG": str(home / "config"), "GHC_ENVIRONMENT": "-",
                "TMPDIR": str(run_dir / "tmp"), "TMP": str(run_dir / "tmp"), "TEMP": str(run_dir / "tmp"),
                "HOME": str(run_dir / "home"), "XDG_CONFIG_HOME": str(run_dir / "home/.config"),
                "XDG_CACHE_HOME": str(run_dir / "home/.cache"), "XDG_DATA_HOME": str(run_dir / "home/.local/share")})
    for key in ("GHC_PACKAGE_PATH", "GHCRTS", "LIQUIDHASKELL_OPTS", "LIQUID_DEV_MODE",
                "liquidhaskell_datadir", "liquidhaskell_boot_datadir", "liquid_fixpoint_datadir"):
        env.pop(key, None)
    env["PATH"] = os.pathsep.join([str(run_dir / "bin"), str(Path(tools["GHC"]).parent), env.get("PATH", "")])
    return env


def check_prepared(run_dir):
    marker = run_dir / "prepared.json"
    if not marker.is_file():
        raise PrerequisiteError("RUN_DIR has no prepared.json; run prepare --fetch-dependencies first")
    prepared = json.loads(marker.read_text())
    current = verify_sources()
    for name, expected in current.items():
        if name.startswith(("source/", "fixtures/", "metadata/")) or name in ("cabal.project", "cabal.project.freeze", "liquidhaskell-contract-lab.cabal"):
            path = run_dir / "lab" / name
            if not path.is_file() or digest(path) != expected:
                raise PrerequisiteError(f"Prepared input mismatch: {name}; use a fresh RUN_DIR")
    if not prepared.get("dependencies_verified"):
        raise PrerequisiteError("Prepared dependency archives are not verified; use prepare --fetch-dependencies")
    vendor_inputs = prepared.get("vendor_input_sha256", {})
    if not vendor_inputs:
        raise PrerequisiteError("Prepared vendor identity is missing; use a fresh RUN_DIR")
    for name, expected in vendor_inputs.items():
        path = run_dir / "lab/vendor" / name
        if not path.is_file() or digest(path) != expected:
            raise PrerequisiteError(f"Prepared dependency source mismatch: {name}")
    return prepared


def package_databases(run_dir):
    return [p for p in (run_dir / "lab/dist-newstyle/packagedb/ghc-9.6.3",
                        run_dir / "cabal-store/ghc-9.6.3/package.db") if p.is_dir()]


def check_packages(run_dir, tools, env):
    databases = package_databases(run_dir)
    if not databases:
        raise PrerequisiteError("Pinned LiquidHaskell package database is absent; run build first")
    args = [tools["GHC_PKG"], "--global"] + ["--package-db=" + str(p) for p in databases]
    packages = {}
    for name, version in PACKAGE_PINS.items():
        result = execute(args + ["field", name, "version", "--simple-output"], env=env, timeout=20)
        found = result["output"].strip().split()
        if result["exit_code"] != 0 or result["timed_out"] or found != [version]:
            raise PrerequisiteError(f"Pinned package {name}=={version} missing or ambiguous")
        packages[name] = version
    return packages


def fetch_package(package, lab):
    name, version = package["name"], package["version"]
    filename = f"{name}-{version}.tar.gz"
    expected_url = f"https://hackage-content.haskell.org/package/{name}-{version}/{filename}"
    if package["url"] != expected_url:
        raise PrerequisiteError(f"Unexpected noncanonical package URL for {name}")
    target = lab / "downloads" / filename
    with urllib.request.urlopen(expected_url, timeout=120) as response:
        data = response.read(package["bytes"] + 1)
    if len(data) != package["bytes"] or hashlib.sha256(data).hexdigest() != package["sha256"]:
        raise PrerequisiteError(f"Dependency archive identity mismatch: {filename}")
    target.write_bytes(data)
    return target


def prepare(run_dir, fetch):
    hashes = verify_sources()
    if run_dir.exists():
        raise PrerequisiteError("Refusing to overwrite an existing RUN_DIR; select a fresh directory")
    run_dir.mkdir(parents=True)
    lab = run_dir / "lab"
    lab.mkdir()
    for name in ("source", "fixtures", "metadata"):
        shutil.copytree(ROOT / name, lab / name)
    for name in ("cabal.project", "cabal.project.freeze", "liquidhaskell-contract-lab.cabal"):
        shutil.copyfile(ROOT / name, lab / name)
    home = run_dir / "cabal-home"
    home.mkdir()
    (run_dir / "bin").mkdir()
    (run_dir / "tmp").mkdir()
    (run_dir / "home").mkdir()
    # Explicit Cabal paths keep stores, caches, logs, config and generated env local.
    (home / "config").write_text("active-repositories: :none\nstore-dir: " + str(run_dir / "cabal-store") +
                                "\nremote-repo-cache: " + str(home / "packages") +
                                "\nlogs-dir: " + str(home / "logs") + "\n", encoding="utf-8")
    record = {"status": "prepared_sources", "dependencies_verified": False, "compiler_solver_executed": False,
              "input_sha256": hashes, "runner_sha256": digest(__file__)}
    write_json(run_dir / "prepared.json", record)
    if fetch:
        if not hasattr(tarfile, "data_filter"):
            raise PrerequisiteError("This Python lacks safe tar extraction; use Python 3.12 or newer")
        packages = json.loads((lab / "metadata/dependency-lock.json").read_text())["packages"]
        (lab / "downloads").mkdir()
        (lab / "vendor").mkdir()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda item: fetch_package(item, lab), packages))
        for item in packages:
            prefix = f"{item['name']}-{item['version']}"
            cabal_file = lab / "metadata/hackage" / (prefix + ".cabal")
            if digest(cabal_file) != item["cabal_sha256"]:
                raise PrerequisiteError(f"Official Cabal revision mismatch: {prefix}")
            with tarfile.open(lab / "downloads" / (prefix + ".tar.gz")) as archive:
                if any(not Path(m.name).parts or Path(m.name).parts[0] != prefix for m in archive.getmembers()):
                    raise PrerequisiteError(f"Unexpected archive root: {prefix}")
                archive.extractall(lab / "vendor", filter="data")
            shutil.copyfile(cabal_file, lab / "vendor" / prefix / (item["name"] + ".cabal"))
        record["vendor_input_sha256"] = {str(p.relative_to(lab / "vendor")): digest(p)
                                          for p in sorted((lab / "vendor").rglob("*")) if p.is_file()}
        record.update(status="prepared", dependencies_verified=True, dependency_packages=len(packages),
                      dependency_download_bytes=sum(p["bytes"] for p in packages))
        write_json(run_dir / "prepared.json", record)
    return record


def configure_tools(run_dir, tools):
    if os.name != "posix":
        raise PrerequisiteError("The pinned shared-plugin reproduction currently requires a POSIX host")
    (run_dir / "home").mkdir(exist_ok=True)
    (run_dir / "tmp").mkdir(exist_ok=True)
    # A process-local solver name is needed because the plugin invokes z3 by name.
    import shlex
    wrapper = run_dir / "bin/z3"
    wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(tools["Z3"]) + ' "$@"\n', encoding="utf-8")
    wrapper.chmod(0o755)
    local = run_dir / "lab/cabal.project.local"
    local.write_text("with-compiler: " + tools["GHC"] + "\nwith-hc-pkg: " + tools["GHC_PKG"] + "\n", encoding="utf-8")


def sanitized(text, run_dir, tools):
    for name, value in sorted(tools.items(), key=lambda item: len(item[1]), reverse=True):
        text = text.replace(value, "${" + name + "}")
    return text.replace(str(run_dir), "${RUN_DIR}").replace(str(ROOT), "${SOURCE_DIR}")


def command_record(result, command, run_dir, tools):
    return {**{k: v for k, v in result.items() if k != "output"},
            "argv": [sanitized(str(x), run_dir, tools) for x in command]}


def build(run_dir, retry=False):
    tools, versions = tool_versions()
    print(json.dumps({"verified_tool_versions": versions}), flush=True)
    check_prepared(run_dir)
    previous = run_dir / "build-result.json"
    attempts = run_dir / "build-attempts"
    if previous.exists() and not retry:
        raise PrerequisiteError("Build evidence exists; use --retry-build to preserve it and record a new attempt")
    attempts.mkdir(exist_ok=True)
    if previous.exists() and not any(attempts.iterdir()):
        archived = attempts / "001"
        archived.mkdir()
        shutil.copyfile(previous, archived / "result.json")
        shutil.copyfile(run_dir / "build.log", archived / "build.log")
    attempt = len(list(attempts.iterdir())) + 1
    attempt_dir = attempts / f"{attempt:03d}"
    attempt_dir.mkdir()
    configure_tools(run_dir, tools)
    env = prepared_environment(run_dir, tools)
    command = [tools["CABAL"], "build", "--offline", "--with-compiler=" + tools["GHC"],
               "--with-hc-pkg=" + tools["GHC_PKG"], "lib:liquidhaskell-contract-lab"]
    # Native C-probe linkage is a host setup parameter, not a logical LH option.
    command += ["--hsc2hs-option=" + option for option in shlex.split(os.environ.get("HSC2HS_OPTIONS", ""))]
    result = execute(command, cwd=run_dir / "lab", env=env, timeout=7200)
    (run_dir / "build.log").write_text(result["output"], encoding="utf-8")
    (attempt_dir / "build.log").write_text(result["output"], encoding="utf-8")
    report = {"status": "timeout" if result["timed_out"] else "tool_error", "versions": versions,
              "command": command_record(result, command, run_dir, tools), "runner_sha256": digest(__file__), "attempt": attempt}
    write_json(run_dir / "build-result.json", report)
    write_json(attempt_dir / "result.json", report)
    if result["timed_out"] or result["exit_code"] != 0:
        raise PrerequisiteError("Pinned plugin build failed; inspect RUN_DIR/build.log")
    report["packages"] = check_packages(run_dir, tools, env)
    report["status"] = "built"
    write_json(run_dir / "build-result.json", report)
    write_json(attempt_dir / "result.json", report)
    return report


def classify(module, result, expected_source=None):
    log = ANSI.sub("", result["output"])
    if result["timed_out"]:
        return "timeout"
    if re.search(r"SMT Says:\s*Unknown|\bunknown\b|timed out", log, re.I):
        return "unknown"
    if re.search(r"unrecognized|panic!|internal error|exception|segmentation fault", log, re.I):
        return "tool_error"
    headings = list(re.finditer(r"(?m)^\[\s*\d+\s+of\s+\d+\]\s+Compiling\s+(\S+)\s+\(\s*([^,\n]+)", log))
    allowed_paths = {"source/" + module + ".hs"}
    if expected_source is not None:
        allowed_paths.add(str(expected_source))
    matches = [(index, match) for index, match in enumerate(headings)
               if match.group(1) == module and match.group(2).strip() in allowed_paths]
    if len(matches) != 1:
        return "tool_error"
    index, heading = matches[0]
    block = log[heading.start():headings[index + 1].start() if index + 1 < len(headings) else len(log)]
    safe_counts = re.findall(r"LIQUID: SAFE \(([0-9]+) constraints checked\)", block)
    unsafe_count = block.count("LIQUID: UNSAFE")
    diagnostics = list(re.finditer(r"(?m)^\s*([^\n]*?\.hs):\d[^\n]*", block))
    target_mismatch = any(match.group(1).strip() in allowed_paths and "Liquid Type Mismatch" in
                          block[match.start():diagnostics[i + 1].start() if i + 1 < len(diagnostics) else len(block)]
                          for i, match in enumerate(diagnostics))
    safe = len(safe_counts) == 1 and int(safe_counts[0]) > 0 and unsafe_count == 0
    unsafe = unsafe_count == 1 and not safe_counts and target_mismatch
    if result["exit_code"] == 0 and safe and not unsafe:
        return "SAFE"
    if result["exit_code"] == 1 and unsafe:
        return "UNSAFE"
    return "tool_error"


def division_gate(probe_observed, runtime_matched):
    # A diagnostic change cannot establish soundness; the only conclusive gate
    # observation in this experiment is failure for the false accepted claim.
    return "failed" if probe_observed == "SAFE" and runtime_matched else "not_established"


def check(run_dir, minimal=False, require_sound=False):
    tools, versions = tool_versions()
    print(json.dumps({"verified_tool_versions": versions}), flush=True)
    prepared = check_prepared(run_dir)
    configure_tools(run_dir, tools)
    env = prepared_environment(run_dir, tools)
    packages = check_packages(run_dir, tools, env)
    target = run_dir / "checks"
    if target.exists():
        raise PrerequisiteError("Checker evidence already exists; use a fresh RUN_DIR")
    (target / "logs").mkdir(parents=True)
    modules = MINIMAL if minimal else tuple(EXPECTED)
    report = {"status": "running", "scope": "minimal" if minimal else "all-twelve", "versions": versions,
              "packages": packages, "observation_reproduced": False, "division_soundness_gate": "not_evaluated",
              "runner_sha256": digest(__file__), "input_sha256": prepared["input_sha256"], "cases": {}}
    result_path = run_dir / "check-result.json"
    write_json(result_path, report)
    for module in modules:
        output = target / "objects" / module
        output.mkdir(parents=True)
        generated = run_dir / "lab/source/.liquid"
        query_files = [generated / (module + ".hs" + suffix) for suffix in (".fq", ".smt2")]
        for path in query_files:
            path.unlink(missing_ok=True)
        command = [tools["CABAL"], "exec", "--offline", "--", tools["GHC"], "--make", "-fforce-recomp", "-O0",
                   "-no-user-package-db", "-package", "liquidhaskell", "-fplugin=LiquidHaskell"]
        command += ["-fplugin-opt=LiquidHaskell:" + f for f in FLAGS]
        command += ["-isource", "-outputdir", str(output), "-c", "source/" + module + ".hs"]
        result = execute(command, cwd=run_dir / "lab", env=env, timeout=180)
        (target / "logs" / (module + ".log")).write_text(result["output"], encoding="utf-8")
        observed = classify(module, result, run_dir / "lab/source" / (module + ".hs"))
        capture_present = all(path.is_file() and path.stat().st_size > 0 for path in query_files)
        report["cases"][module] = {**command_record(result, command, run_dir, tools), "expected": EXPECTED[module],
                                  "observed": observed, "query_files_present": capture_present,
                                  "query_sha256": {path.suffix: digest(path) for path in query_files if path.is_file()},
                                  "matched": observed == EXPECTED[module] and capture_present}
        write_json(result_path, report)
    # The ordinary runtime bridge is intentionally compiled without the LH plugin.
    runtime_dir = target / "runtime"
    runtime_dir.mkdir()
    executable = runtime_dir / "runtime"
    compile_command = [tools["GHC"], "--make", "-fforce-recomp", "-O0", "-Wall", "-Werror", "-XGHC2021",
                       "-no-user-package-db", "-ifixtures/frozen-0.4/src", "-isource", "-outputdir", str(runtime_dir),
                       "source/Runtime.hs", "-o", str(executable)]
    compiled = execute(compile_command, cwd=run_dir / "lab", env=env, timeout=180)
    (target / "logs/runtime-compile.log").write_text(compiled["output"], encoding="utf-8")
    report["runtime_compile"] = command_record(compiled, compile_command, run_dir, tools)
    runtime = {"exit_code": None, "timed_out": False, "output": ""}
    if compiled["exit_code"] == 0 and not compiled["timed_out"]:
        runtime = execute([executable], cwd=run_dir / "lab", env=env, timeout=180)
    (target / "logs/runtime.log").write_text(runtime["output"], encoding="utf-8")
    markers = ["25 pairs, 50 comparisons", "5016 triples", "result=0 deliberately-claimed-result=99 isFalse=True"]
    runtime_ok = runtime["exit_code"] == 0 and not runtime["timed_out"] and all(x in runtime["output"] for x in markers)
    report["runtime"] = {k: v for k, v in runtime.items() if k != "output"}
    report["runtime"]["matched"] = runtime_ok
    check_prepared(run_dir)  # Verify included immutable inputs again after execution.
    report["division_soundness_gate"] = division_gate(report["cases"]["DivAssumptionProbe"]["observed"], runtime_ok)
    report["observation_reproduced"] = runtime_ok and all(x["matched"] for x in report["cases"].values())
    report["status"] = "observation_reproduced_with_failed_soundness_gate" if report["observation_reproduced"] else "mismatch"
    report["soundness_claim"] = False
    report["full_solver_capture_replay"] = "not_run; generated partial .smt2 files are not standalone replay evidence"
    write_json(result_path, report)
    return report, 1 if require_sound or not report["observation_reproduced"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("doctor", "verify-sources", "prepare", "build", "check"))
    parser.add_argument("--run-dir", default=os.environ.get("RUN_DIR"))
    parser.add_argument("--fetch-dependencies", action="store_true", help="Opt in to 121 pinned official Hackage downloads")
    parser.add_argument("--minimal", action="store_true", help="Run the five primary diagnostic modules plus the runtime bridge")
    parser.add_argument("--require-sound-div", action="store_true", help="Return failure for the known false acceptance")
    parser.add_argument("--retry-build", action="store_true", help="Preserve earlier build evidence and record an explicit retry")
    args = parser.parse_args()
    try:
        if sys.flags.optimize or os.environ.get("PYTHONOPTIMIZE"):
            raise PrerequisiteError("Run without Python optimization/PYTHONOPTIMIZE")
        if args.command == "verify-sources":
            print(json.dumps({"status": "verified", "source_files": len(verify_sources()), "checker": "not_run"}))
        elif args.command == "doctor":
            _, versions = tool_versions()
            print(json.dumps({"status": "tool_versions_match", "versions": versions, "plugin_build": "not_checked"}, indent=2))
        elif args.command == "prepare":
            print(json.dumps(prepare(run_path(args.run_dir), args.fetch_dependencies), indent=2))
        elif args.command == "build":
            print(json.dumps(build(run_path(args.run_dir), args.retry_build), indent=2))
        else:
            report, status = check(run_path(args.run_dir), args.minimal, args.require_sound_div)
            print(json.dumps(report, indent=2))
            return status
        return 0
    except (PrerequisiteError, OSError, ValueError, tarfile.TarError) as error:
        print("PREREQUISITE/EXECUTION ERROR: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
