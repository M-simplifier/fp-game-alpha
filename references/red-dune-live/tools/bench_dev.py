#!/usr/bin/env python3
"""Independent HTTP benchmark of the native development command or release build.
Run only in an isolated, quiet worktree. Alternates one real rule, verifies its
visible value and accepted input, then restores owned source bytes. No browser
rendering/input timings are inferred. This file is never an operational watcher.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[3]
GAME = ROOT / 'references/red-dune-live'


def request(port, client, path, body=None):
    headers = {'X-Red-Dune-Client': client}
    if body is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(f'http://127.0.0.1:{port}'+path,
                                 data=None if body is None else json.dumps(body).encode(), headers=headers)
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=10) as response:
        return json.load(response)


def input_probe(port, policy, health):
    client = str(uuid.uuid4())
    state = request(port, client, '/api/claim', {})
    assert state['result']['status'] == 'ownershipGranted', state['result']
    assert all(c['health'] == str(health) for c in state['view']['colonies'])
    start = time.monotonic_ns()
    state = request(port, client, '/api/command', {
        'op':'configure','preset':'survival','requestId':client+'-1','requestCounter':'1',
        'runtimeId':state['shell']['runtimeId'],'sessionEpoch':state['shell']['session']['epochCounter']})
    elapsed = (time.monotonic_ns()-start)/1e6
    assert state['result']['status'] == 'accepted', state['result']
    assert state['policies']['enabled'] is True
    assert state['policies']['deliveries'][0]['target'] == str(policy)
    return {'httpInputMs':elapsed,'policyTarget':str(policy),'health':str(health)}


def summarize(values):
    values = sorted(values)
    return {'samples':len(values),'medianMs':statistics.median(values),
            'p95Ms':values[math.ceil(.95*len(values))-1], 'minMs':min(values),'maxMs':max(values)}


def stop(process):
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError('Process needed forced termination; graceful cleanup failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--route', choices=['supervisor','native'], required=True)
    parser.add_argument('--kind', choices=['leaf','core'], default='leaf')
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--supervisor', type=Path, help='Built native red-dune-devloop executable')
    parser.add_argument('--cabal', default=os.environ.get('CABAL','cabal'))
    parser.add_argument('--cabal-config', type=Path)
    parser.add_argument('--project-file', type=Path)
    parser.add_argument('--dist-dir', type=Path)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18287)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100 or not 1024 <= args.port <= 65535:
        parser.error('samples must be 1..100; port must be 1024..65535')
    if args.route == 'supervisor' and args.supervisor is None:
        parser.error('--supervisor is required')
    args.project_file = args.project_file or ROOT / ('cabal.project.red-dune-dev' if args.route=='supervisor' else 'cabal.project.red-dune-live')
    for key in ('cabal_config','project_file','dist_dir','build_dir','output','supervisor'):
        value = getattr(args,key)
        if value is not None:
            setattr(args,key,value.resolve())
    args.build_dir.mkdir(parents=True,exist_ok=True)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    target = GAME / ('core/Colony/Needs.hs' if args.kind=='core' else 'src/RedDune/Policies.hs')
    original = owned = target.read_bytes()
    mode = target.stat().st_mode & 0o777
    before,after = ((b'0 0 0 0 0 0 1000 (Fraction',b'0 0 0 0 0 0 999 (Fraction') if args.kind=='core'
                    else (b'Water 120000 40000 0,',b'Water 120001 40000 0,'))
    assert original.count(before)==1
    alternate = original.replace(before,after)
    report = {'schema':2,'route':args.route,'kind':args.kind,'scope':'HTTP, not actual browser',
              'source':str(target.relative_to(ROOT)), 'originalSha256':hashlib.sha256(original).hexdigest(),
              'percentile':'nearest-rank','samples':[]}
    process = None
    log = (args.build_dir/'measurement.log').open('a')
    config = ['--config-file='+str(args.cabal_config)] if args.cabal_config else []
    flags = ['--project-file='+str(args.project_file),'--builddir='+str(args.dist_dir or args.build_dir/'dist')]
    def events():
        path = args.build_dir/'events.jsonl'
        return [json.loads(s) for s in path.read_text().splitlines() if s.endswith('}')] if path.exists() else []
    def ready(index, tag):
        deadline = time.monotonic()+600
        while time.monotonic()<deadline:
            if args.route=='supervisor':
                for event in events()[index:]:
                    if event['phase']=='failed': raise RuntimeError(event)
                    if event['phase']=='http-ready': return event
            else:
                try:
                    state = request(args.port,'benchmark','/api/state')
                    assert state['shell']['devRevision']==tag and state['view']['mode']=='Paused'
                    return {'runtimeId':state['shell']['runtimeId'],'revision':tag}
                except OSError:
                    pass
            if process.poll() is not None: raise RuntimeError('Process exited; see measurement.log')
            time.sleep(.01)
        raise RuntimeError('Readiness timeout')
    def start_native(tag):
        nonlocal process
        start = time.monotonic_ns()
        subprocess.run([args.cabal,*config,'build',*flags,'exe:red-dune-live'],cwd=ROOT,
                       stdout=log,stderr=subprocess.STDOUT,check=True)
        binary = subprocess.check_output([args.cabal,*config,'list-bin',*flags,'exe:red-dune-live'],cwd=ROOT,text=True).strip()
        compiled = time.monotonic_ns()
        process = subprocess.Popen([binary,'--port',str(args.port)],cwd=GAME,start_new_session=True,
            stdout=log,stderr=subprocess.STDOUT,env={**os.environ,'RED_DUNE_STORE':str(args.build_dir/'saves'),'RED_DUNE_DEV_REVISION':tag})
        result = ready(0,tag)
        result.update(compileMs=(compiled-start)/1e6,hostReadyMs=(time.monotonic_ns()-compiled)/1e6,
                      detectionToReadyMs=(time.monotonic_ns()-start)/1e6,renderedMs=None,inputMs=None)
        return result
    try:
        startup = time.monotonic_ns()
        if args.route=='supervisor':
            index = len(events())
            command = [str(args.supervisor),'--project-file',str(args.project_file),
                       '--build-dir',str(args.build_dir),'--port',str(args.port),'--cabal',args.cabal]
            for flag,value in [('--cabal-config',args.cabal_config),('--dist-dir',args.dist_dir)]:
                if value: command += [flag,str(value)]
            process = subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            ready(index,None)
        else:
            start_native(hashlib.sha256(original).hexdigest());stop(process)
        report['startupMs'] = (time.monotonic_ns()-startup)/1e6
        runtimes = set()
        for sample in range(args.samples):
            payload = alternate if sample%2==0 else original
            assert target.read_bytes()==owned,'Concurrent source edit preserved; stop the measurement'
            index = len(events())
            fd,name = tempfile.mkstemp(dir=target.parent,prefix=target.name+'.bench-')
            with os.fdopen(fd,'wb') as output: output.write(payload)
            os.chmod(name,mode)
            assert target.read_bytes()==owned,'Concurrent source edit preserved; replacement cancelled'
            os.replace(name,target);owned=payload
            saved = time.time_ns()
            result = ready(index,None) if args.route=='supervisor' else start_native(hashlib.sha256(payload).hexdigest())
            result.update(sample=sample+1,sourceSavedNs=saved,saveToReadyMs=(time.time_ns()-saved)/1e6)
            assert result['runtimeId'] not in runtimes
            runtimes.add(result['runtimeId'])
            result.update(input_probe(args.port,120001 if args.kind=='leaf' and sample%2==0 else 120000,
                                      999 if args.kind=='core' and sample%2==0 else 1000))
            report['samples'].append(result)
            args.output.write_text(json.dumps(report,indent=2)+'\n')
            if args.route=='native': stop(process)
        report['summary']=summarize([s['saveToReadyMs'] for s in report['samples']])
    finally:
        try:
            stop(process)
        finally:
            if target.read_bytes()==owned:
                target.write_bytes(original);os.chmod(target,mode);report['restored']=True
            else:
                report['restored']=False
            log.close()
            args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['summary'],indent=2))


if __name__=='__main__': main()
