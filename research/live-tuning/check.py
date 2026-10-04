#!/usr/bin/env python3
import os, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent
GHC=os.environ.get('GHC','ghc')
def run(args, **kwargs):
    p=subprocess.run(args,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30,**kwargs)
    assert p.returncode==0,p.stdout
    return p.stdout
(ROOT/'.build').mkdir(exist_ok=True)
for main, directory, binary in [('Tests.hs','tests','tests-bin'),('Main.hs','app','game')]:
    print(run([GHC,'-O0','-Wall','-Werror','-outputdir',f'.build/{directory}',main,'-o',f'.build/{binary}']),end='')
print(run(['.build/tests-bin']),end='')
with tempfile.TemporaryDirectory(prefix='host-check-',dir=ROOT) as tmp:
    folder=Path(tmp)
    for name,data in [('valid','revision 1 moveBudget 5'),('invalid','revision 2 moveBudget 99'),('partial','revision 2'),('huge','9'*10000),('overflow','revision 2 moveBudget 18446744073709551622'),('negative-overflow','revision 2 moveBudget -18446744073709551610'),('win','revision 2 moveBudget 6')]:
        (folder/name).write_text(data)
    commands=['r',f'load {folder}/valid','restart','new',*(['r']*5)]
    for name in ['invalid','partial','huge','missing','valid','overflow','negative-overflow']: commands.append(f'load {folder}/{name}')
    commands += [f'load {folder}/win','new',*(['r']*6),'r','quit']
    log=run(['.build/game'],input='\n'.join(commands)+'\n')
    lines=log.splitlines()
    assert '[.@....G] PLAYING | moves=7 session=r0/8 staged=r1/5' in lines
    assert '[@.....G] PLAYING | moves=8 session=r0/8 staged=r1/5' in lines
    rejects=[i for i,line in enumerate(lines) if line.startswith('REJECTED:')]
    assert len(rejects)==7
    assert all(lines[i+1]=='[.....@G] OUT OF MOVES | moves=0 session=r1/5 staged=r1/5' for i in rejects)
    assert lines[-1]==lines[-2]=='[......@] WON | moves=0 session=r2/6 staged=r2/6'
    (ROOT/'.build'/'host-check.log').write_text(log)
print('PASS: real CLI host admission, restart/new, 7 failures retain state, recovery after failure, final-move win, repeated terminal input')
