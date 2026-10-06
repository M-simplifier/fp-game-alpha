#!/usr/bin/env python3
"""Independent regression oracle for the native Haskell supervisor.

This is test-only Python; tools/dev.sh runs the Haskell operational stack.
Run against a built red-dune-devloop binary in a quiet working tree. Source
replacements are atomic and restores compare owned bytes before writing; any
detected concurrent edit is left untouched. Do not run beside another editor. All saves, logs and copied packs stay in a fresh test folder.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
GAME = ROOT / "references/red-dune-live"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="Built native red-dune-devloop; otherwise use cabal list-bin")
    parser.add_argument("--cabal", default=os.environ.get("CABAL", "cabal"))
    parser.add_argument("--cabal-config", type=Path)
    parser.add_argument("--project-file", type=Path, default=ROOT / "cabal.project.red-dune-dev")
    parser.add_argument("--dist-dir", type=Path, default=ROOT / ".build/red-dune-dev/dist")
    parser.add_argument("--build-dir", type=Path, default=ROOT / ".build/red-dune-dev/regressions",
                        help="Parent of a fresh, isolated test folder")
    parser.add_argument("--port", type=int, help="Unused loopback port; default allocates a free port")
    parser.add_argument("--timeout", type=float, default=180, help="Per-phase timeout, seconds")
    parser.add_argument("--skip-core", action="store_true", help="Skip compiled-core rebuild/restore checks")
    args = parser.parse_args()
    for field in ("binary", "cabal_config", "project_file", "dist_dir", "build_dir"):
        value = getattr(args, field)
        if value is not None:
            setattr(args, field, value.resolve())
    if args.port is not None and not 1024 <= args.port <= 65535:
        parser.error("--port must be 1024..65535")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.binary is None:
        config = ["--config-file=" + str(args.cabal_config)] if args.cabal_config else []
        args.binary = Path(subprocess.check_output(
            [args.cabal, *config, "list-bin", "--project-file=" + str(args.project_file),
             "--builddir=" + str(args.dist_dir), "exe:red-dune-devloop"],
            cwd=ROOT, text=True).strip())
    if not args.binary.is_file():
        parser.error("Native binary does not exist; build exe:red-dune-devloop first")
    return args


class GuardedSource:
    """Compare before every write, including rollback, to preserve other edits."""
    def __init__(self, path):
        self.path = path
        self.original = path.read_bytes()
        self.owned = self.original

    def write(self, data, *, preserve_mtime=False):
        if self.path.read_bytes() != self.owned:
            raise RuntimeError(f"Concurrent edit at {self.path}; left those bytes untouched")
        stat = self.path.stat()
        fd, name = tempfile.mkstemp(prefix=self.path.name + ".devloop-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data)
            os.chmod(name, stat.st_mode & 0o777)
            # Check again immediately before replacement, narrowing the editor race.
            if self.path.read_bytes() != self.owned:
                raise RuntimeError(f"Concurrent edit at {self.path}; replacement cancelled")
            os.replace(name, self.path)
            self.owned = data
            if preserve_mtime:
                os.utime(self.path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(name)

    def restore(self):
        if self.path.read_bytes() != self.owned:
            raise RuntimeError(f"Concurrent edit at {self.path}; restoration cancelled")
        if self.owned != self.original:
            self.write(self.original)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def descendants(parent_pid):
    """Linux process-tree evidence for the native Unix lifecycle checks."""
    parents = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            parents.setdefault(int(fields[1]), []).append(int(entry.name))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    result, pending = [], [parent_pid]
    while pending:
        children = parents.get(pending.pop(), [])
        result.extend(children)
        pending.extend(children)
    return result


def running(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[0] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


class CheckRun:
    def __init__(self, args):
        self.args = args
        args.build_dir.mkdir(parents=True, exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix='native "quoted" 日本語 ', dir=args.build_dir))
        self.port = args.port or free_port()
        self.pack = self.folder / 'pack "quoted" 日本語.json'
        self.valid_pack = (GAME / "data/campaign-pack-v1.json").read_bytes()
        self.pack.write_bytes(self.valid_pack)
        self.command = [str(args.binary), "--cabal", args.cabal,
                        "--project-file", str(args.project_file), "--dist-dir", str(args.dist_dir),
                        "--build-dir", str(self.folder), "--port", str(self.port), "--pack", str(self.pack)]
        if args.cabal_config:
            self.command += ["--cabal-config", str(args.cabal_config)]
        self.log = (self.folder / "test-output.log").open("w")
        self.process = subprocess.Popen(self.command, cwd=ROOT, stdout=self.log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        self.checks = []

    def events(self):
        path = self.folder / "events.jsonl"
        if not path.exists():
            return []
        # Ignore a partially written final record while the process flushes it.
        return [json.loads(line) for line in path.read_text().split("\n")[:-1] if line]

    def await_phase(self, phase, offset=0):
        deadline = time.monotonic() + self.args.timeout
        while time.monotonic() < deadline:
            for event in self.events()[offset:]:
                if event["phase"] == phase:
                    return event
            if self.process.poll() is not None:
                raise RuntimeError(f"Supervisor exited {self.process.returncode}; inspect {self.folder}")
            time.sleep(0.02)
        raise TimeoutError(f"No {phase} within {self.args.timeout}s; inspect {self.folder}")

    def ready(self, offset=0, previous=None):
        event = self.await_phase("http-ready", offset)
        assert event["mode"] == "Paused", event
        assert event["renderedMs"] is None and event["inputMs"] is None, event
        if previous:
            assert event["authority"] != previous["authority"], event
        return event

    def reachable(self):
        with socket.socket() as probe:
            probe.settimeout(0.2)
            return probe.connect_ex(("127.0.0.1", self.port)) == 0

    def record(self, name, **details):
        result = {"test": name, "passed": True, **details}
        self.checks.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)

    def stop(self, repeated=False):
        if self.process.poll() is None:
            children = descendants(self.process.pid)
            self.process.send_signal(signal.SIGINT)
            if repeated:
                time.sleep(0.001)
                with contextlib.suppress(ProcessLookupError):
                    self.process.send_signal(signal.SIGINT)
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                # GHCi has its own group. Capture and remove every descendant
                # rather than only killing the supervisor's process group.
                for pid in reversed(children + descendants(self.process.pid)):
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(pid, signal.SIGKILL)
                self.process.kill()
                self.process.wait()
                raise
            deadline = time.monotonic() + 2
            while any(running(pid) for pid in children) and time.monotonic() < deadline:
                time.sleep(.02)
            survivors = [pid for pid in children if running(pid)]
            for pid in survivors:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
            assert not survivors, f"Native supervisor left live descendants: {survivors}"
        self.log.close()


def run_checks(args):
    source = GuardedSource(GAME / "src/RedDune/Policies.hs")
    core = GuardedSource(GAME / "core/Colony/KnownCatalog.hs")
    run = CheckRun(args)
    failure = None
    try:
        initial = run.ready()
        run.record("initial-native-http-ready-and-quoted-paths", event=initial)

        duplicate = subprocess.run(run.command, cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=10)
        assert duplicate.returncode != 0 and "supervisor owns" in duplicate.stdout, duplicate.stdout
        run.record("same-folder-lock")
        occupied_command = run.command.copy()
        occupied_command[occupied_command.index("--build-dir") + 1] = str(run.folder / "occupied")
        occupied = subprocess.run(occupied_command, cwd=ROOT, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, timeout=10)
        assert occupied.returncode != 0 and "port is occupied" in occupied.stdout, occupied.stdout
        run.record("occupied-port-refusal")

        offset = len(run.events())
        source.write(source.original + b"\n-- Native regression: content edit with preserved mtime.\n", preserve_mtime=True)
        changed = run.ready(offset, initial)
        assert changed["route"] == "ghci-reload" and changed["revision"] != initial["revision"], changed
        run.record("content-hash-detects-preserved-mtime-atomic-edit", event=changed)

        offset = len(run.events())
        source.write(source.original + b"\nnativeDevloopBroken =\n")
        broken = run.await_phase("failed", offset)
        assert not run.reachable(), "Old host survived a syntax error"
        run.record("syntax-failure-removes-old-host", event=broken)
        offset = len(run.events())
        source.write(source.original + b"\n-- Native regression: repaired source.\n")
        repaired = run.ready(offset, changed)
        assert repaired["route"] == "ghci-reload", repaired
        run.record("repair-reuses-stopped-interpreter", event=repaired)

        offset = len(run.events())
        source.write(source.original + b"\n-- Native regression: rapid source A.\n")
        first = run.await_phase("checking", offset)
        source.write(source.original + b"\n-- Native regression: rapid source B.\n")
        superseded = run.await_phase("superseded", offset)
        current = run.ready(offset, repaired)
        assert superseded["revision"] == first["revision"] != current["revision"]
        assert not any(e["phase"] == "http-ready" and e["revision"] == first["revision"]
                       for e in run.events()[offset:])
        run.record("superseded-source-never-announced-ready", event=superseded)

        if not args.skip_core:
            offset = len(run.events())
            core.write(core.original + b"\n-- Native regression: compiled dependency edit.\n")
            rebuilt = run.ready(offset, current)
            assert rebuilt["route"] == "cabal-core-and-repl", rebuilt
            run.record("core-edit-rebuilds-cabal-dependencies", event=rebuilt)
            current = rebuilt

        offset = len(run.events())
        core.restore()
        source.restore()
        restored = run.ready(offset, current)
        run.record("original-source-restored", event=restored)
        offset = len(run.events())
        run.pack.write_text("{ invalid content pack")
        invalid_pack = run.await_phase("failed", offset)
        assert not run.reachable(), "Old host survived an invalid initial pack"
        run.record("invalid-pack-closes-host", event=invalid_pack)
        offset = len(run.events())
        run.pack.write_bytes(run.valid_pack)
        fixed_pack = run.ready(offset, restored)
        run.record("pack-repair-starts-fresh-campaign", event=fixed_pack)

        run.stop(repeated=True)
        assert run.process.returncode == 0 and not run.reachable()
        assert run.events()[-1]["phase"] == "stopped"
        run.record("double-sigint-stops-and-joins")
    except BaseException as error:
        failure = error
    finally:
        # Stop first, then restore only bytes still owned by this oracle.
        try:
            run.stop()
        except BaseException as error:
            failure = failure or error
        for item in (source, core):
            try:
                item.restore()
            except BaseException as error:
                failure = failure or error
        report = {"checks": run.checks, "sourceRestored": source.path.read_bytes() == source.original,
                  "coreRestored": core.path.read_bytes() == core.original,
                  "sourceSha256": hashlib.sha256(source.original).hexdigest(),
                  "exitCode": run.process.returncode, "portClosed": not run.reachable(),
                  "error": str(failure) if failure else None}
        report_path = run.folder / "result.json"
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("Regression report: " + str(report_path), flush=True)
    if failure:
        raise failure


def main():
    args = arguments()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    # Serializes these mutation tests with another invocation of this oracle.
    with (ROOT / ".build/native-devloop-regression.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run_checks(args)


if __name__ == "__main__":
    main()
