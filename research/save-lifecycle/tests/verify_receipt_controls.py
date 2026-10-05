"""Reject altered receipt copies; never mutate the original successful run."""
import argparse, contextlib, io, json, pathlib, shutil, sys, tempfile
sys.dont_write_bytecode=True
root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run-dir',type=pathlib.Path,required=True)
args=parser.parse_args()
sys.path.insert(0,str(root/'scripts'))
import run_experiment as r
run=args.run_dir.resolve()
results=[]
def edit_log(path,e,name,fn):
    record=next(x for x in e['runs'] if x['name']==name)
    log=path/record['log'];log.write_text(fn(log.read_text()))
    record['log_sha256']=r.sha(log)
def bad_trace(text):
    lines=text.splitlines()
    row=json.loads(lines[0][6:]);row['epoch']=True;lines[0]='STATE '+json.dumps(row)
    return '\n'.join(lines)+'\n'
def mutate(name,path,e):
    if name=='missing-named-outcome':e['runs'].pop()
    elif name=='wrong-named-invariant':edit_log(path,e,'mutant-Epoch',lambda t:t.replace('Invariant NoStaleSaved is violated.','Invariant WrongName is violated.'))
    elif name=='wrong-version-metadata':e['versions']['ghc-version']='9.6.6'
    elif name=='wrong-tool-metadata':e['tools']['seed']=2
    elif name=='changed-copied-core':
        p=path/'work/vendor/colony0.2/src/Colony/Save.hs';p.write_bytes(p.read_bytes()+b'\n-- changed\n')
    elif name=='missing-generated-artifact':(path/'work/model/Tracebranchinflight.tla').unlink()
    elif name=='changed-jar':
        p=path/'tools/tla2tools-v1.7.4.jar';p.write_bytes(p.read_bytes()+b'bad')
    elif name=='log-path-escape':e['runs'][0]['log']='../outside.log'
    elif name=='invalid-typed-thirteen-field-trace':edit_log(path,e,'replay-mutant-Epoch',bad_trace)
    elif name=='unknown-result':edit_log(path,e,'safety',lambda t:t+'\nunknown\n')
    elif name=='timeout-record':e['runs'][0]['timed_out']=True
    elif name=='unexpected-mutant-acceptance':next(x for x in e['runs'] if x['name']=='mutant-Epoch')['exit_code']=0
cases=['missing-named-outcome','wrong-named-invariant','wrong-version-metadata','wrong-tool-metadata',
       'changed-copied-core','missing-generated-artifact','changed-jar','log-path-escape',
       'invalid-typed-thirteen-field-trace','unknown-result','timeout-record','unexpected-mutant-acceptance']
with contextlib.redirect_stdout(io.StringIO()):r.verify(run)
for name in cases:
    with tempfile.TemporaryDirectory(prefix='tlc-receipt-control-',dir=run/'tmp') as directory:
        path=pathlib.Path(directory)
        for folder in ['tools','logs','work']:shutil.copytree(run/folder,path/folder)
        e=json.loads((run/'evidence.json').read_text());mutate(name,path,e)
        (path/'evidence.json').write_text(json.dumps(e))
        try:
            with contextlib.redirect_stdout(io.StringIO()):r.verify(path)
        except (RuntimeError,ValueError,AssertionError,KeyError,FileNotFoundError) as error:
            results.append({'name':name,'status':'rejected-as-expected','reason':str(error).replace(directory,'$CONTROL_DIR')})
        else:raise RuntimeError('INVALID RECEIPT ACCEPTED: '+name)
out={'schema':'save-lifecycle-verifier-negative-controls-v1','source_runner_sha256':r.sha(root/'scripts/run_experiment.py'),'control_script_sha256':r.sha(pathlib.Path(__file__)),'cases':results}
(run/'verification-negative-controls.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps({'negative_controls':len(results),'status':'all-rejected'}))
