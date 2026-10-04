#!/usr/bin/env python3
"""Isolated scratch copies only. GHC supplied via GHC env or existing default."""
import datetime, hashlib, json, os, platform, queue, shutil, statistics, subprocess, tempfile, threading, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent
GHC = os.environ.get('GHC', 'ghc')
N = int(os.environ.get('SAMPLES', '7'))
records = []
flags = ['-O0', '-Wall', '-Werror']
class Session:
    def __init__(self, command, cwd):
        self.p = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.q = queue.Queue()
        def reader():
            for line in self.p.stdout: self.q.put(line.rstrip('\n'))
        threading.Thread(target=reader, daemon=True).start()
    def send(self, text): self.p.stdin.write(text+'\n'); self.p.stdin.flush()
    def until(self, predicate):
        lines=[]
        while True:
            line=self.q.get(timeout=15); lines.append(line)
            if predicate(line): return lines
    def close(self, command):
        self.send(command); self.p.wait(timeout=10)
        assert self.p.returncode == 0

def run(command, cwd):
    p = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    assert p.returncode == 0, p.stdout
    return p.stdout

def record(label, start, output, **more):
    records.append(dict(label=label, seconds=time.perf_counter()-start, output=output, **more))

def save(path, value):
    tmp = path.with_suffix('.tmp'); tmp.write_text(value); tmp.replace(path)

with tempfile.TemporaryDirectory(prefix='tuning-benchmark-', dir=ROOT) as tmp:
    work=Path(tmp)
    for name in ['Game.hs','Main.hs','Probe.hs']: shutil.copy2(ROOT/name,work/name)
    source=work/'Game.hs'; original=source.read_text()
    build=[GHC,*flags,'-outputdir','obj','Probe.hs','-o','probe']
    t=time.perf_counter(); out=run(build,work); record('native-cold-artifacts-build',t,out)
    for i in range(N):
        t=time.perf_counter(); out=run(build,work); record('native-warm-unchanged-build',t,out)
    # Interactive native process preparation is reported separately.
    t=time.perf_counter(); out=run([GHC,*flags,'-outputdir','app-obj','Main.hs','-o','game'],work); record('interactive-host-build',t,out)
    t=time.perf_counter(); app=Session([str(work/'game')],work); out=app.until(lambda s:s.startswith('[')); record('data-host-start-first-board',t,out)
    for i in range(N):
        budget=6+i%2
        save(work/'rules.txt',f'revision {i+1} moveBudget {budget}\n')
        t=time.perf_counter()  # saved edit to complete observed response
        app.send('load rules.txt\nnew\nr')
        expected=f'moves={budget-1} session=r{i+1}/{budget}'
        out=app.until(lambda s: s.startswith('[.@') and expected in s)
        assert any('ACCEPTED' in s for s in out)
        record('data-saved-to-new-session-first-input',t,out)
    app.close('quit')
    for i in range(N):
        budget=6+i%2
        save(source,original.replace('defaultBudget = 8',f'defaultBudget = {budget}'))
        t=time.perf_counter(); out=run(build,work); built=time.perf_counter()
        observation=run([str(work/'probe')],work)
        assert f'moves={budget-1} session=r0/{budget}' in observation,observation
        record('native-edited-build-launch-first-input',t,out+observation,build_seconds=built-t)
    save(source,original)
    t=time.perf_counter(); repl=Session([GHC,'--interactive','-ignore-dot-ghci','-v0',*flags,'Game.hs'],work)
    repl.send('putStrLn observeInitial')
    out=repl.until(lambda s:s.startswith('[.@')); record('ghci-start-load-first-input',t,out)
    for i in range(N):
        budget=6+i%2
        save(source,original.replace('defaultBudget = 8',f'defaultBudget = {budget}'))
        t=time.perf_counter(); repl.send(':reload\nputStrLn observeInitial')
        out=repl.until(lambda s:s.startswith('[.@'))
        assert f'moves={budget-1} session=r0/{budget}' in out[-1],out
        record('ghci-edited-reload-new-session-first-input',t,out)
    repl.close(':quit')
metadata=dict(measured_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), cpu=next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')), 'unknown'), ghc=run([GHC,'--numeric-version'],ROOT).strip(),platform=platform.platform(),flags=flags,samples=N,source_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.glob('*.hs')},scope='Existing compiler and OS caches; cold means empty build artifact directory only. Bytecode GHCi. Native is compile+link+process start; data and GHCi are persistent. No browser/wasm or visual paint measured. All observations include a new session and accepted rightward input; output strings forced through stdout.')
summary={label:dict(n=len(xs),median_ms=statistics.median(xs)*1000,min_ms=min(xs)*1000,max_ms=max(xs)*1000) for label in dict.fromkeys(r['label'] for r in records) for xs in [[r['seconds'] for r in records if r['label']==label]]}
(ROOT/'measurements.json').write_text(json.dumps(dict(metadata=metadata,summary=summary,records=records),indent=2))
print(json.dumps(summary,indent=2))
