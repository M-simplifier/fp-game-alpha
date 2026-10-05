#!/usr/bin/env python3
"""Transparent process-local Z3 stdin/stdout capture for reproducibility.
No commands are inserted, removed, or transformed. The official Z3 binary executes.
"""
import os,pathlib,subprocess,sys,threading,time,json
real=os.environ['Z3_REAL']
if '-in' not in sys.argv[1:]:os.execv(real,[real]+sys.argv[1:])
out=pathlib.Path(os.environ['Z3_CAPTURE_DIR']);out.mkdir(parents=True,exist_ok=True)
key=f'{time.time_ns()}-{os.getpid()}'
(out/(key+'.command.json')).write_text(json.dumps({'binary':real,'argv':sys.argv[1:]})+'\n')
p=subprocess.Popen([real]+sys.argv[1:],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def feed():
 with (out/(key+'.stdin.smt2')).open('wb') as log:
  try:
   while True:
    b=os.read(0,65536)
    if not b:break
    log.write(b);log.flush();p.stdin.write(b);p.stdin.flush()
  except BrokenPipeError:pass
  finally:
   try:p.stdin.close()
   except BrokenPipeError:pass

def relay(src,dst,name):
 with (out/(key+name)).open('wb') as log:
  while True:
   b=os.read(src.fileno(),65536)
   if not b:break
   log.write(b);log.flush();dst.write(b);dst.flush()
threading.Thread(target=feed,daemon=True).start()
e=threading.Thread(target=relay,args=(p.stderr,sys.stderr.buffer,'.stderr.log'),daemon=True);e.start()
relay(p.stdout,sys.stdout.buffer,'.stdout.log');rc=p.wait();e.join(timeout=2)
(out/(key+'.exit')).write_text(str(rc)+'\n')
sys.exit(rc)
