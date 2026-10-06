'use strict';
// Native HTTP acceptance, not browser rendering/input acceptance.
const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');const net=require('node:net');const crypto=require('node:crypto');
const binary=process.argv[2];if(!binary)throw new Error('Usage: node tools/test_http.cjs /absolute/path/to/red-dune-host');
const cwd=path.resolve(__dirname,'..'),store=fs.mkdtempSync(path.join(os.tmpdir(),'red-dune-host-test-'));
const port=19000+Math.floor(Math.random()*10000),base=`http://127.0.0.1:${port}`,client=crypto.randomUUID();
const server=spawn(binary,['--port',String(port)],{cwd,env:{...process.env,RED_DUNE_STORE:store},stdio:['ignore','pipe','pipe']});
let output='';server.stdout.on('data',d=>output+=d);server.stderr.on('data',d=>output+=d);
let state,sequence=0,keepalive=null;const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function req(route,body,who=client,extra={}){const response=await fetch(base+route,{method:body?'POST':'GET',headers:{'X-Red-Dune-Client':who,...(body?{'Content-Type':'application/json'}:{}),...extra},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});const data=await response.json();return {response,data};}
async function observe(){const {data}=await req('/api/state');assert.ok(data.view,JSON.stringify(data));state=data;return data;}
function envelope(body){return {...body,requestId:`${client}-${++sequence}`,requestCounter:String(sequence),runtimeId:state.shell.runtimeId,sessionEpoch:state.shell.session.epochCounter};}
async function action(body){const result=await req('/api/command',envelope(body));state=result.data;return state;}
async function until(predicate,label,timeout=15000){const end=Date.now()+timeout;while(Date.now()<end){await observe();if(predicate(state))return state;await sleep(30);}throw new Error('Timeout: '+label+'\n'+JSON.stringify(state?.result));}
async function raw(message){return new Promise((resolve,reject)=>{const socket=net.createConnection({host:'127.0.0.1',port});let data='';socket.on('connect',()=>socket.end(message));socket.on('data',d=>data+=d);socket.on('end',()=>resolve(data));socket.on('error',reject);});}
async function main(){
 const deadline=Date.now()+30000;while(Date.now()<deadline){try{await observe();break;}catch{if(server.exitCode!==null)throw new Error(output);await sleep(100);}}assert.ok(state,'Host did not start: '+output);
 assert.ok(state.view.m1.buildOptions.length>20,'All supported construction options are projected');
 const duplicate=spawn(binary,['--port',String(port+1)],{cwd,env:{...process.env,RED_DUNE_STORE:store},stdio:'ignore'});const duplicateExit=await new Promise(resolve=>duplicate.once('close',resolve));assert.notEqual(duplicateExit,0,'second process cannot own the same store');
 const initial=state;await sleep(150);await observe();assert.equal(state.view.tick,initial.view.tick);assert.equal(state.view.boundary,initial.view.boundary);assert.equal(state.revision,initial.revision,'ownerless ticker must not mutate paused game');
 assert.equal((await action({op:'resume'})).result.status,'ownershipRejected');
 let result=await req('/api/claim',{});state=result.data;assert.equal(state.result.status,'ownershipGranted');keepalive=setInterval(()=>req('/api/heartbeat',{}).catch(()=>{}),700);
 result=await req('/api/claim',{},crypto.randomUUID());assert.equal(result.data.result.status,'ownershipRejected');
 result=await req('/api/command',{},client,{Origin:'https://evil.invalid'});assert.equal(result.response.status,403);
 const evilHost=await raw('GET /api/state HTTP/1.1\r\nHost: attacker.invalid\r\n\r\n');assert.match(evilHost,/403 Forbidden/);
 let malformed=await raw(`POST /api/command HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n`);assert.match(malformed,/400 Bad Request/);
 malformed=await raw(`POST /api/command HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: 70000\r\n\r\n`);assert.match(malformed,/400 Bad Request/);
 await observe();const unchanged=state.revision;assert.equal((await action({op:'frame',count:'4'})).result.status,'decodeRejected');assert.equal(state.revision,unchanged);
 const configure=envelope({op:'configure',preset:'survival'});state=(await req('/api/command',configure)).data;assert.equal(state.result.status,'accepted');const configured=state.revision;
 const receipt=state.result;state=(await req('/api/command',configure)).data;assert.deepEqual(state.result,receipt);assert.equal(state.revision,configured,'repeated request must not configure twice');
 state=(await req('/api/speed',configure)).data;assert.equal(state.result.status,'identityRejected','receipt identity includes route');
 const badCounter={...envelope({op:'pause'}),requestCounter:'18446744073709551616'};state=(await req('/api/command',badCounter)).data;assert.equal(state.result.status,'sessionRejected');
 state=(await req('/api/command',{...configure,preset:'off'})).data;assert.equal(state.result.status,'identityRejected');assert.equal(state.policies.enabled,true);
 const pump=state.view.sites.find(s=>s.recipe==='hand_water');assert.ok(pump,'Actual water production site');
 state=await action({op:'preview',command:{kind:'produce',site:pump.id}});assert.equal(state.result.status,'intentPreview');const command=state.result.envelope;
 const commit=envelope(command);state=(await req('/api/command',commit)).data;assert.equal(state.result.status,'boundaryCommitted');const commandRevision=state.revision;
 state=(await req('/api/command',commit)).data;assert.equal(state.revision,commandRevision);assert.ok(state.result.receipts.length);
 await action({op:'expand',prototype:'warehouse'});assert.ok(state.buildQueue.length,'Physical expansion queue');
 await action({op:'resume'});const runningTick=BigInt(state.view.tick);await sleep(1200);await observe();assert.ok(BigInt(state.view.tick)>runningTick,'One host clock advances real world');
 await req('/api/heartbeat',{});await action({op:'pause'});const pauseTick=state.view.tick;await sleep(160);await observe();assert.equal(state.view.tick,pauseTick);
 await action({op:'save'});await until(s=>s.save.current.status==='saved'&&!s.save.pending,'durable save');const checkpoint=state.save.current.lastSuccess.id;assert.ok(fs.statSync(path.join(store,checkpoint+'.rdg')).size>1000);
 const backup=store+'-offline';fs.renameSync(store,backup);fs.writeFileSync(store,'temporarily unavailable');
 try {await action({op:'save'});await until(s=>s.save.current.status==='failed'&&!s.save.pending,'failed save');assert.equal(state.view.mode,'Paused');}
 finally {fs.unlinkSync(store);fs.renameSync(backup,store);}
 assert.ok(fs.existsSync(path.join(store,checkpoint+'.rdg')),'failed save preserves earlier checkpoint');
 const brokenCheckpoint=crypto.randomUUID();fs.writeFileSync(path.join(store,brokenCheckpoint+'.rdg'),'not a valid checkpoint');
 await action({op:'library'});await until(s=>s.shell.catalog.status==='ready','catalog with corrupt checkpoint');assert.ok(state.shell.catalog.warnings.length,'corrupt checkpoints are visible warnings');assert.ok(state.shell.catalog.entries.some(e=>e.id===checkpoint));
 const beforeInvalidLoad=state.view.branch;await action({op:'previewLoad',entry:'../../outside-store',action:'restore'});await until(s=>s.shell.load.status==='failed','invalid checkpoint ID');assert.equal(state.view.branch,beforeInvalidLoad);
 await action({op:'previewLoad',entry:checkpoint,action:'restore'});assert.equal(state.shell.load.status,'reading');const earlyTicket=state.shell.load.ticket;
 await action({op:'cancelLoad',ticket:earlyTicket});assert.equal(state.shell.load.status,'cancelled');const cancelEpoch=state.shell.session.epochCounter;
 await until(s=>s.runtime.workers==='0','cancelled reader drained');assert.equal(state.shell.session.epochCounter,cancelEpoch);assert.equal(state.shell.load.status,'cancelled');
 await action({op:'previewLoad',entry:checkpoint,action:'restore'});await until(s=>s.shell.load.status==='preview','load preview');const previewTicket=state.shell.load.ticket;const oldBranch=state.view.branch;
 await action({op:'cancelLoad',ticket:previewTicket});assert.equal(state.shell.load.status,'cancelled');await sleep(100);await observe();assert.equal(state.view.branch,oldBranch);
 await action({op:'resume'});await sleep(120);await action({op:'pause'});
 await action({op:'previewLoad',entry:checkpoint,action:'restore'});await until(s=>s.shell.load.status==='preview','second preview');const ticket=state.shell.load.ticket;
 await action({op:'activateLoad',ticket,discardUnsaved:false});assert.equal(state.result.reason,'DiscardConfirmationRequired');
 const oldEpoch=state.shell.session.epochCounter;await action({op:'activateLoad',ticket,discardUnsaved:true});await until(s=>s.shell.load.status==='activated','durable activation');assert.notEqual(state.shell.session.epochCounter,oldEpoch);assert.notEqual(state.view.branch,oldBranch);assert.equal(state.view.mode,'Paused');
 state=(await req('/api/command',commit)).data;assert.equal(state.result.status,'sessionRejected','pre-activation command cannot re-enter new authority');
 await req('/api/heartbeat',{});await action({op:'resume'});clearInterval(keepalive);keepalive=null;await sleep(4500);await observe();assert.equal(state.view.mode,'Paused');assert.equal(state.runtime.owner,'none');const expiredTick=state.view.tick;await sleep(120);await observe();assert.equal(state.view.tick,expiredTick,'connectivity loss safely pauses');
 state=(await req('/api/claim',{})).data;
 const sourcePack=fs.readFileSync(path.join(cwd,'data/campaign-pack-v1.json'),'utf8');const largeRevision='9007199254740993';
 await action({op:'stagePackText',expectedRevision:state.pack.stagedRevision||state.pack.revision,packText:sourcePack.replace(/"revision": 1,/,`"revision": ${largeRevision},`)});
 assert.equal(state.result.status,'accepted');assert.equal(state.pack.stagedRevision,largeRevision,'raw pack integers survive browser transport without rounding');assert.match(state.pack.stagedIdentity,/^[0-9a-f]{64}$/);assert.notEqual(state.pack.stagedIdentity,state.pack.identity);const stagedIdentity=state.pack.stagedIdentity;
 await action({op:'stagePackText',expectedRevision:'1',packText:sourcePack});assert.equal(state.result.status,'admissionRejected');assert.equal(state.pack.stagedRevision,largeRevision);
 await action({op:'restart',scenario:'recovery',discardUnsaved:true});assert.equal(state.result.status,'restarted');assert.equal(state.campaign.scenario,'recovery');assert.equal(state.view.mode,'Paused');assert.equal(state.pack.revision,largeRevision);assert.equal(state.pack.identity,stagedIdentity);assert.equal(state.pack.stagedIdentity,null);assert.equal(state.save.current.status,'saved');assert.ok(fs.existsSync(path.join(store,state.save.current.lastSuccess.id+'.rdg')),'restart durable before visible');
 const staticResponse=await fetch(base+'/');assert.equal(staticResponse.status,200);assert.match(await staticResponse.text(),/campaignTitle/);assert.match(staticResponse.headers.get('content-security-policy'),/frame-ancestors 'none'/);
 console.log('PASS: store process lock, complete construction menu, corrupt-checkpoint warnings, path rejection, native HTTP start/observe, exclusive lease, origin/Host/bounds, exact command retry, policies, construction queue, ticker/pause, durable save, preview/cancel, fresh-branch activation, stale-session rejection, lease expiry, recovery restart, asset delivery');
 console.log('NOT RUN: actual browser rendering, keyboard and pointer acceptance');
}
main().catch(error=>{console.error(error);console.error(output);process.exitCode=1;}).finally(async()=>{clearInterval(keepalive);if(server.exitCode===null&&server.signalCode===null)await new Promise(resolve=>{const timer=setTimeout(()=>{server.kill('SIGKILL');resolve();},3000);server.once('close',()=>{clearTimeout(timer);resolve();});server.kill('SIGTERM');});fs.rmSync(store,{recursive:true,force:true});});
