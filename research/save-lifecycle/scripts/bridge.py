#!/usr/bin/env python3
"""Trace encoding only: it never implements transition/invariant logic.
TLC -> event file -> independently compiled Haskell -> complete-state equality.
Haskell -> literal TLA sequence -> TLC Init/Next-constrained path validation.
"""
import argparse,json,re,pathlib,sys
if sys.flags.optimize:
 raise RuntimeError("Python optimization mode is unsupported; evidence checks must stay enabled")
FIELDS=['epoch','branch','revision','active','phase','captured','capturedBranch','accepted','acceptedEpoch','receipt','saved','event','request']
def validate_row(row):
 if set(row)!=set(FIELDS): raise ValueError('missing or unexpected trace field')
 for key in ['epoch','branch','revision','active','receipt','request']:
  if type(row[key]) is not int: raise ValueError('non-integer scalar '+key)
 if type(row['saved']) is not bool: raise ValueError('non-boolean saved')
 if row['event'] not in ['Init','Start','Persist','Fail','Callback','Drop','Edit','Load','NewBranch']:raise ValueError('unknown event')
 for key in ['captured','capturedBranch','accepted','acceptedEpoch']:
  if type(row[key]) is not list or len(row[key])!=4 or any(type(x) is not int for x in row[key]):raise ValueError('bad numeric vector '+key)
 if type(row['phase']) is not list or len(row['phase'])!=4 or any(x not in ['unused','writing','persisted','failed'] for x in row['phase']):raise ValueError('bad phase vector')
 return row
def tla(v):
 if isinstance(v,bool): return 'TRUE' if v else 'FALSE'
 if isinstance(v,int): return str(v)
 if isinstance(v,str): return json.dumps(v)
 if isinstance(v,list): return '<<'+', '.join(tla(x) for x in v)+'>>'
 if isinstance(v,dict): return '['+', '.join(k+' |-> '+tla(v[k]) for k in FIELDS)+']'
 raise ValueError(v)
def parse_tlc(path):
 text=path.read_text()
 assert 'Invariant ' in text and ' is violated.' in text, 'Not an invariant counterexample'
 result=[]
 for block in re.split(r'^State \d+:.*$',text,flags=re.M)[1:]:
  values={}
  for key,val in re.findall(r'^/\\ (\w+) = (.+)$',block,flags=re.M):
   assert key in FIELDS, key
   val=val.replace('<<','[').replace('>>',']').replace('TRUE','true').replace('FALSE','false')
   values[key]=json.loads(val)
  assert set(values)==set(FIELDS),set(FIELDS)-set(values)
  result.append(validate_row(values))
 assert len(result)>1
 return result
def parse_haskell(path):
 rows=[json.loads(line[6:]) for line in path.read_text().splitlines() if line.startswith('STATE ')]
 if not rows:raise ValueError('no state observations')
 return [validate_row(x) for x in rows]
def emit_module(rows,path):
 path=path.with_suffix('.tla')
 name=path.stem
 assert re.fullmatch('[A-Za-z][A-Za-z0-9]*',name)
 init=' /\\ '.join(k+' = Observed[1].'+k for k in FIELDS)
 nxt=' /\\ '.join(k+"' = Observed[position+1]."+k for k in FIELDS)
 path.write_text(f'''--------------------- MODULE {name} ---------------------
EXTENDS SaveLifecycle
VARIABLE position
Observed == {tla(rows)}
TraceInit == Init /\\ position = 1 /\\ {init}
TraceNext == \\/ /\\ position < Len(Observed) /\\ Next /\\ position' = position+1
                /\\ {nxt}
             \\/ /\\ position = Len(Observed) /\\ UNCHANGED <<vars, position>>
=============================================================================
''')
 path.with_suffix('.cfg').write_text('''INIT TraceInit
NEXT TraceNext
CONSTANTS
 EpochCount = 2
 IdCount = 2
 CheckEpoch = TRUE
 CheckActive = TRUE
 CheckPersist = TRUE
INVARIANTS TypeOK NoStaleSaved NoStaleAcceptance NoFalseSuccess UniqueResponse SavedSnapshotMatches ActiveCorresponds
CHECK_DEADLOCK TRUE
''')
def main():
 p=argparse.ArgumentParser(); sub=p.add_subparsers(dest='command',required=True)
 c=sub.add_parser('extract');c.add_argument('log',type=pathlib.Path);c.add_argument('prefix',type=pathlib.Path)
 c=sub.add_parser('compare');c.add_argument('reference',type=pathlib.Path);c.add_argument('haskell',type=pathlib.Path)
 c=sub.add_parser('encode');c.add_argument('haskell',type=pathlib.Path);c.add_argument('output',type=pathlib.Path)
 a=p.parse_args()
 if a.command=='extract':
  rows=parse_tlc(a.log);a.prefix.with_suffix('.json').write_text(json.dumps(rows,indent=2)+'\n')
  a.prefix.with_suffix('.events').write_text(''.join(f"{s['event']} {s['request']}\n" for s in rows[1:]))
  print(json.dumps({'states':len(rows),'events':len(rows)-1}))
 if a.command=='compare':
  rows=[validate_row(x) for x in json.loads(a.reference.read_text())];actual=parse_haskell(a.haskell)
  assert len(rows)==len(actual),(len(rows),len(actual))
  for i,(x,y) in enumerate(zip(rows,actual)):
   assert x==y,{'state':i+1,'differences':{k:[x[k],y[k]] for k in FIELDS if x[k]!=y[k]}}
  print(json.dumps({'matched_states':len(rows),'matched_fields_per_state':len(FIELDS)}))
 if a.command=='encode':
  rows=parse_haskell(a.haskell);emit_module(rows,a.output);print(json.dumps({'encoded_states':len(rows)}))
if __name__=='__main__':main()
