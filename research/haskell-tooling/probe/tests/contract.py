#!/usr/bin/env python3
"""Independent fixtures, differential Python reference plus specification assertions."""
import json, os, pathlib, shutil, subprocess, sys, time, statistics, signal
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT/'bin/fp-game-probe'
reference = os.environ.get('FP_GAME_REFERENCE')
if not reference or not pathlib.Path(reference).is_file():
    raise SystemExit('Set FP_GAME_REFERENCE to an existing reference fp_game.py file')
REFERENCE = pathlib.Path(reference).resolve()
# Use explicit caller PATH; optional bin-directory additions are opt-in.
extra_bins = [os.environ[key] for key in ['FP_GAME_GHC_BIN', 'FP_GAME_CABAL_BIN'] if os.environ.get(key)]
tool_path = os.pathsep.join(extra_bins + [os.environ.get('PATH', '')])
for tool in ['ghc', 'cabal']:
    if not shutil.which(tool, path=tool_path):
        raise SystemExit(f'{tool} must be on PATH (or set the corresponding FP_GAME_*_BIN directory)')
(ROOT/'evidence').mkdir(exist_ok=True)
WORK = ROOT/'tests/work'
WORK.mkdir(exist_ok=True)
PROJECT = WORK/'game space 日本語 ; literal'
PROJECT.mkdir(exist_ok=True)
(PROJECT/'src').mkdir(exist_ok=True)
(PROJECT/'src/Main.hs').write_bytes('module Main where\r\nmain :: IO ()\r\nmain = putStrLn "日本語"\r\n'.encode())
(PROJECT/'probe-game.cabal').write_text('cabal-version: 3.0\nname: probe-game\nversion: 0.1.0.0\nbuild-type: Simple\nexecutable probe-game\n  main-is: Main.hs\n  hs-source-dirs: src\n  default-language: GHC2021\n  build-depends: base\n')
(PROJECT/'cabal.project').write_text('packages: .\nactive-repositories: :none\n')
CONFIG = PROJECT/'fp-game.json'
CONFIG.write_text(json.dumps({'source_dirs':['src']}))
ENV = dict(os.environ, PATH=tool_path)
EMPTY = WORK/'empty-bin'; EMPTY.mkdir(exist_ok=True)
FAKE = WORK/'fake tools 日本語'; FAKE.mkdir(exist_ok=True)
for name in ['ghc','cabal']:
 p=FAKE/name
 p.write_text(f'#!{sys.executable}\nimport sys,json\nprint(json.dumps(sys.argv[1:],ensure_ascii=False))\nsys.stderr.buffer.write("diagnostic 日本語".encode()+b"\\xff")\nsys.exit(7)\n')
 p.chmod(0o755)
records=[]
def call(engine,args,project=PROJECT,cwd=WORK,env=ENV,json_mode=True):
 command=([str(BIN)] if engine=='haskell' else [sys.executable,str(REFERENCE)])+args
 if project is not None: command+=['--project',str(project)]
 if json_mode: command+=['--json']
 start=time.perf_counter(); p=subprocess.run(command,cwd=cwd,env=env,capture_output=True,timeout=30)
 elapsed=time.perf_counter()-start
 result=json.loads(p.stdout) if json_mode else None
 if json_mode:
  assert not p.stderr,(command,p.stderr)
  assert p.returncode == result['exit_code'],(command,p.returncode,result)
  assert set(result)==({'status','exit_code','stdout','stderr'} if 'status' in result else {'command','exit_code','stdout','stderr'}), result
 records.append({'engine':engine,'args':args,'seconds':elapsed,'exit_code':p.returncode})
 return p,result

def pair(args,**kw):
 return [call(e,args,**kw)[1] for e in ['python','haskell']]

def same_error(args,message,**kw):
 a,b=pair(args,**kw)
 assert a==b,(a,b)
 assert b['exit_code']==1 and message in b['stderr'],b

same_error(['check','absent.hs'],'existing .hs')
(PROJECT/'bad.txt').write_text('no')
same_error(['check','bad.txt'],'existing .hs')
OUT=WORK/'Outside.hs'; OUT.write_text('module Outside where\nx=1\n')
same_error(['check',str(OUT)],'existing .hs')
(PROJECT/'src/linked.hs').symlink_to(OUT) if not (PROJECT/'src/linked.hs').exists() else None
same_error(['check','src/linked.hs'],'existing .hs')
same_error(['check','src/Main.hs'],'GHC is missing',env=dict(ENV,PATH=str(EMPTY)))
same_error(['build'],'Cabal is missing',env=dict(ENV,PATH=str(EMPTY)))
same_error(['build'],'Project directory does not exist',project=WORK/'absent')
CONFIG.write_text(json.dumps({'source_dirs':['../']}))
same_error(['check','src/Main.hs'],'source directories must remain inside')
CONFIG.write_text(json.dumps({'source_dirs':['src']}))
# Fake tools establish arrays, literal metacharacters, exit and UTF-8 replacement semantics.
for args in [['build'],['check'],['check','src/Main.hs']]:
 a,b=pair(args,env=dict(ENV,PATH=str(FAKE)))
 assert a['exit_code']==b['exit_code']==7
 assert a['stderr']==b['stderr']=='diagnostic 日本語�'
 ac,bc=a['command'],b['command']
 if len(args)==2:
  ac[ac.index('-outputdir')+1]='TEMP'; bc[bc.index('-outputdir')+1]='TEMP'
 assert ac==bc,(ac,bc)
 assert a['command'][0]==str(FAKE/('ghc' if len(args)==2 else 'cabal'))
# Real GHC/Cabal: only GHC-bundled base in the independent game.
for args in [['build'],['check'],['check','src/Main.hs']]:
 a,b=pair(args); assert a['exit_code']==b['exit_code']==0,(a,b)
(PROJECT/'src/Broken.hs').write_text('module Broken where\nx :: Int\nx = "wrong"\n')
a,b=pair(['check','src/Broken.hs']); assert a['exit_code']==b['exit_code']==1
assert 'error:' in a['stderr'] and 'error:' in b['stderr']
# Explicit project wins over cwd; standalone default deliberately uses cwd (Python defaults tool root).
_,b=call('haskell',['check','src/Main.hs'],cwd=ROOT); assert b['exit_code']==0
_,b=call('haskell',['check','src/Main.hs'],project=None,cwd=PROJECT); assert b['exit_code']==0
# Config parser is typed and fails cleanly for invalid shape, malformed or non-UTF8 data.
for data in [b'{',b'{"source_dirs":1}',b'{"source_dirs":[1]}',b'\xff']:
 CONFIG.write_bytes(data)
 _,b=call('haskell',['check','src/Main.hs']); assert b['status']=='error' and b['exit_code']==1
CONFIG.write_text(json.dumps({'source_dirs':['src']}))
# Text mode keeps compiler stderr separate and propagates nonzero status.
p,_=call('haskell',['build'],env=dict(ENV,PATH=str(FAKE)),json_mode=False)
assert p.returncode==7 and 'diagnostic 日本語�'==p.stderr.decode()
# Unsupported command is explicit, no pretend drop-in coverage.
p=subprocess.run([str(BIN),'scaffold'],capture_output=True); assert p.returncode==2 and b'Usage:' in p.stderr
# Relocate both project and standalone binary; hide old project path by renaming it.
MOVED=WORK/'relocated 日本語'; shutil.move(str(PROJECT),str(MOVED))
MOVEDBIN=WORK/'relocated tool'; shutil.copy2(BIN,MOVEDBIN)
oldbin=BIN; BIN=MOVEDBIN
try:
 for args in [['build'],['check','src/Main.hs']]:
  _,b=call('haskell',args,project=None,cwd=MOVED); assert b['exit_code']==0,b
finally:
 BIN=oldbin; shutil.move(str(MOVED),str(PROJECT))
# Process timeout must kill a child too, not just return while compiler work continues.
SLOW=WORK/'slow-bin'; SLOW.mkdir(exist_ok=True)
marker=WORK/'detached-marker'
if marker.exists(): marker.unlink()
p=SLOW/'ghc'
p.write_text(f'#!{sys.executable}\nimport subprocess,time,sys\nsubprocess.Popen([sys.executable,"-c",{("import time,pathlib;time.sleep(2);pathlib.Path("+repr(str(marker))+").write_text(\"bad\")")!r}])\ntime.sleep(10)\n')
p.chmod(0o755)
_,b=call('haskell',['check','src/Main.hs'],env=dict(ENV,PATH=str(SLOW),FP_GAME_PROBE_TIMEOUT_SECONDS='1'))
assert b['exit_code']==1 and 'timed out' in b['stderr']; time.sleep(2); assert not marker.exists()
assert not list((PROJECT/'.build').glob('check-*'))
# Explicit Linux cancellation checks: descendants and temporary directories.
# SIGTERM is translated into a main-thread exception; cleanup finishes before exit 143.
for cancellation in [signal.SIGINT, signal.SIGTERM]:
 p=subprocess.Popen([str(BIN),'check','src/Main.hs','--project',str(PROJECT),'--json'],env=dict(ENV,PATH=str(SLOW)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 time.sleep(.3); p.send_signal(cancellation); p.communicate(timeout=5)
 assert p.returncode != 0
 if cancellation == signal.SIGTERM: assert p.returncode == 143
 time.sleep(2); assert not marker.exists()
 assert not list((PROJECT/'.build').glob('check-*'))
# Spawn failure retains command-result schema, rather than pretending a compiler error.
(FAKE/'ghc').write_text('#!/nonexistent/interpreter\n')
(FAKE/'ghc').chmod(0o755)
a,b=pair(['check','src/Main.hs'],env=dict(ENV,PATH=str(FAKE)))
assert a['exit_code']==b['exit_code']==1 and 'command' in b
# Safety improvements over existing Python implementation: refuse linked build state/config.
unsafe=WORK/'unsafe';unsafe.mkdir(exist_ok=True)
(unsafe/'.build').symlink_to(PROJECT/'.build') if not (unsafe/'.build').exists() else None
_,b=call('haskell',['build'],project=unsafe)
assert b['status']=='error' and 'inside this project' in b['stderr']
config_link=PROJECT/'.build/cabal.config'
config_link.unlink(); config_link.symlink_to(OUT)
_,b=call('haskell',['build']); assert b['status']=='error' and 'symbolic link' in b['stderr']
assert OUT.read_text()=='module Outside where\nx=1\n'
config_link.unlink()

# Warm startup includes argument validation/JSON and the known missing-tool path.
startups=[]
for _ in range(20):
 start=time.perf_counter(); call('haskell',['check','src/Main.hs'],env=dict(ENV,PATH=str(EMPTY))); startups.append(time.perf_counter()-start)
report={'status':'passed','invocations':len(records),'records':records,'warm_missing_tool_median_seconds':statistics.median(startups),'warm_missing_tool_min_seconds':min(startups),'scope':'POSIX process-group tests; independent base-only project; existing tool dependencies', 'ghc_version':subprocess.check_output(['ghc','--numeric-version'],env=ENV,text=True).strip(), 'cabal_version':subprocess.check_output(['cabal','--numeric-version'],env=ENV,text=True).strip()}
(ROOT/'evidence/contract-results.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
print(json.dumps({k:v for k,v in report.items() if k!='records'},indent=2))
