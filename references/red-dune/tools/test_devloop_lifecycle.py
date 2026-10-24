#!/usr/bin/env python3
"""Deterministic native supervisor lifecycle regressions with a fake interpreter.

No game source is edited. The fixture controls command completion, a loopback
readiness server, and a deliberately non-cooperative :quit. Real GHCi/source
compilation is covered separately by test_devloop.py.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

from test_devloop import ROOT, running

FAKE_INTERPRETER = r'''#!/usr/bin/env python3
import http.server,json,pathlib,re,sys,threading,time,uuid,os
folder=pathlib.Path(__file__).resolve().parent
(folder/'pids').open('a').write(str(os.getpid())+'\n')
server=None;worker=None;state=None
class Handler(http.server.BaseHTTPRequestHandler):
 protocol_version="HTTP/1.1"
 def do_GET(self):
  data=json.dumps(state).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
class Server(http.server.HTTPServer):allow_reuse_address=True
def stop():
 global server,worker
 if server is not None:
  server.shutdown();server.server_close();worker.join();server=None;worker=None
def hs_string(value):
 value=re.sub(r'\\([0-9]+)',lambda match:chr(int(match.group(1))),value).replace('\\&','')
 return json.loads(value)
if (folder/'pause-startup').exists():
 (folder/'pause-startup').unlink();(folder/'startup-entered').touch()
 while not (folder/'release-startup').exists():time.sleep(.005)
 (folder/'release-startup').unlink()
print('Ok, 8 modules loaded.',flush=True)
for raw in sys.stdin:
 line=raw.rstrip('\n')
 if line==':reload':
  gate=folder/'pause-reload'
  if gate.exists():
   gate.unlink();(folder/'reload-entered').touch()
   while not (folder/'release-reload').exists():time.sleep(.005)
   (folder/'release-reload').unlink()
  if (folder/'fail-reload').exists():
   (folder/'fail-reload').unlink();print('error: transient B failed\nFailed, no modules loaded.',flush=True)
  else:print('Ok, 8 modules loaded.',flush=True)
 elif line.startswith('dev <- Main.start '):
  match=re.match(r'dev <- Main.start "([0-9a-f]+)" ([0-9]+) ',line)
  revision,port=match.groups();identity=str(uuid.uuid4())
  state={'shell':{'devRevision':revision,'runtimeId':identity,'session':{'authority':identity}},'view':{'mode':'Paused'}}
  server=Server(('127.0.0.1',int(port)),Handler);worker=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01});worker.start()
 elif line=='Main.stop dev':stop()
 elif line==':quit':
  (folder/'quit-entered').touch()
  if (folder/'hang-quit').exists():time.sleep(60)
  stop();break
 elif 'System.IO.writeFile ' in line:
  match=re.search(r'System.IO.writeFile (".*") ("RED_DUNE_COMMAND[^"]*")$',line)
  if match:
   target,token=map(hs_string,match.groups());sys.stdout.flush();sys.stderr.flush();pathlib.Path(target).write_text(token)
'''


class Fixture:
    def __init__(self, binary, folder, timeout):
        self.folder, self.timeout = folder, timeout
        folder.mkdir(parents=True)
        self.project = folder / 'fixture.project'
        self.project.write_text('-- isolated fixture project\n')
        self.pack = folder / 'fixture-pack.json'
        self.pack.write_text('initial')
        self.fake = folder / 'fake-cabal'
        self.fake.write_text(FAKE_INTERPRETER)
        self.fake.chmod(0o755)
        self.build = folder / 'session'
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        self.log = (folder / 'run.log').open('w')
        self.process = subprocess.Popen([str(binary), '--cabal', str(self.fake),
            '--project-file', str(self.project), '--build-dir', str(self.build),
            '--port', str(self.port), '--pack', str(self.pack)], cwd=ROOT,
            stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)

    def events(self):
        path = self.build / 'events.jsonl'
        if not path.exists(): return []
        return [json.loads(line) for line in path.read_text().split('\n')[:-1] if line]

    def wait(self, condition, description):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            found = condition()
            if found: return found
            if self.process.poll() is not None:
                raise RuntimeError(f'Supervisor exited {self.process.returncode} waiting for {description}: {self.folder}')
            time.sleep(.005)
        raise TimeoutError(f'Waiting for {description}: {self.folder}')

    def phase(self, name, offset=0):
        return self.wait(lambda: next((e for e in self.events()[offset:] if e['phase'] == name), None), name)

    def file(self, name):
        return self.wait(lambda: (self.folder / name).exists(), name)

    def no_children(self):
        pids = self.folder / 'pids'
        return not pids.exists() or not any(running(int(pid)) for pid in pids.read_text().splitlines())

    def finish(self, *, allow_failure=False):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
        self.process.wait(timeout=self.timeout)
        if not allow_failure: assert self.process.returncode == 0, self.process.returncode
        assert self.no_children(), f'Live interpreter left behind: {self.folder}'
        with socket.socket() as probe:
            assert probe.connect_ex(('127.0.0.1', self.port)) != 0, 'Listener remained live'

    def cleanup(self):
        try:
            self.finish(allow_failure=True)
        finally:
            pids = self.folder / 'pids'
            if pids.exists():
                for pid in pids.read_text().splitlines():
                    if running(int(pid)):
                        with contextlib.suppress(ProcessLookupError):
                            os.kill(int(pid), signal.SIGKILL)
            if self.process.poll() is None:
                self.process.kill();self.process.wait()
            self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, default=ROOT / '.build/red-dune-dev/lifecycle-regressions')
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    args.build_dir.mkdir(parents=True, exist_ok=True)
    parent = Path(tempfile.mkdtemp(prefix='native-lifecycle-', dir=args.build_dir.resolve()))
    results = []
    for artifact in ('supervisor.lock', 'events.jsonl', 'compiler.log', 'status.json', 'status.json.tmp', 'command.done'):
        for alias in ('symlink', 'hardlink', 'directory'):
            folder = parent / ('alias-' + artifact + '-' + alias)
            folder.mkdir()
            victim = folder / 'valuable'
            victim.write_bytes(b'keep these bytes exactly')
            target = folder / artifact
            if alias == 'symlink': target.symlink_to(victim)
            elif alias == 'hardlink': os.link(victim, target)
            else: target.mkdir()
            rejected = subprocess.run([str(args.binary.resolve()), '--build-dir', str(folder)],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=args.timeout)
            assert rejected.returncode != 0, (artifact, alias)
            diagnostic = rejected.stdout.decode('utf-8', errors='replace')
            assert 'Refusing aliased or unexpected development path:' in diagnostic, diagnostic
            assert str(target) in diagnostic, diagnostic
            assert victim.read_bytes() == b'keep these bytes exactly', (artifact, alias)
    result = {'test': 'artifact-alias-refusal', 'passed': True, 'cases': 18}
    results.append(result);print(json.dumps(result), flush=True)
    for case in ('interrupt-rebuild-teardown', 'interrupt-outermost-cleanup', 'rapid-undo-to-superseded-source', 'generation-fence-success-aba', 'generation-fence-failure-aba', 'core-generation-rebuild-aba'):
        fixture = Fixture(args.binary.resolve(), parent / case, args.timeout)
        try:
            fixture.phase('http-ready')
            if case in ('generation-fence-success-aba', 'generation-fence-failure-aba', 'core-generation-rebuild-aba'):
                rebuilding = case == 'core-generation-rebuild-aba'
                target = fixture.project if rebuilding else fixture.pack
                (fixture.folder / ('pause-startup' if rebuilding else 'pause-reload')).touch()
                if case == 'generation-fence-failure-aba':
                    (fixture.folder / 'fail-reload').touch()
                offset = len(fixture.events())
                target.write_text('-- source A' if rebuilding else 'source A')
                checked = fixture.phase('checking', offset)
                fixture.file('startup-entered' if rebuilding else 'reload-entered')
                stamp = target.stat()
                target.write_text('-- source B' if rebuilding else 'source B')
                target.write_text('-- source A' if rebuilding else 'source A')
                os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                (fixture.folder / ('release-startup' if rebuilding else 'release-reload')).touch()
                fixture.phase('superseded', offset)
                ready = fixture.phase('http-ready', offset)
                assert ready['revision'] == checked['revision'], (checked, ready)
                assert not any(e['phase'] == 'failed' for e in fixture.events()[offset:])
                if rebuilding:
                    assert len((fixture.folder / 'pids').read_text().splitlines()) >= 3
                    assert ready['route'] == 'cabal-core-and-repl'
                fixture.finish()
            elif case == 'rapid-undo-to-superseded-source':
                (fixture.folder / 'pause-reload').touch()
                offset = len(fixture.events())
                fixture.pack.write_text('source A')
                checked = fixture.phase('checking', offset)
                fixture.file('reload-entered')
                fixture.pack.write_text('source B')
                (fixture.folder / 'release-reload').touch()
                fixture.phase('superseded', offset)
                # Revert before the old 100 ms waitForChange would poll. Correct
                # code retries even though this equals its just-superseded hash.
                fixture.pack.write_text('source A')
                ready = fixture.phase('http-ready', offset)
                assert ready['revision'] == checked['revision'], (checked, ready)
                fixture.finish()
            else:
                (fixture.folder / 'hang-quit').touch()
                if case == 'interrupt-rebuild-teardown':
                    fixture.project.write_text('-- changed compiled dependency configuration\n')
                else:
                    # A synchronous status-write error enters closeSession before
                    # any signal was sent. Its first signal must still reap.
                    status = fixture.build / 'status.json'
                    status.unlink();status.mkdir()
                    fixture.pack.write_text('trigger status failure')
                fixture.file('quit-entered')
                fixture.process.send_signal(signal.SIGINT)
                fixture.finish(allow_failure=case == 'interrupt-outermost-cleanup')
            result = {'test': case, 'passed': True, 'noLiveInterpreter': fixture.no_children()}
            results.append(result);print(json.dumps(result), flush=True)
        finally:
            fixture.cleanup()
    (parent / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Lifecycle regression report: ' + str(parent / 'result.json'))


if __name__ == '__main__':
    main()
