'use strict';
// Thin view + command adapter. No simulation, pathfinding, economy, RNG or
// authoritative entity creation lives here. IDs/quantities remain strings.
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
// Opt-in source identity; HTTP readiness is not browser acceptance evidence.
const development=window.location.hash==='#dev';
function devStatus(message){
  if(!development)return;
  let panel=document.querySelector('#devStatus');
  if(!panel){panel=document.createElement('p');panel.id='devStatus';panel.setAttribute('role','status');document.body.prepend(panel);}
  panel.textContent=message;
}

const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
const fmt=x=>{if(x===null||x===undefined)return '—';try{return BigInt(x).toLocaleString('ja-JP');}catch{return String(x??'—');}};
const labels={water:'清水',ration:'レーション',crops:'作物',fuel:'燃料',parts:'部品'};
const resource=r=>state?.view.resources.find(x=>x.id===r)?.label||labels[r]||r;
const units=r=>state?.view.resources.find(x=>x.id===r)?.unit||'';
const phases={Planned:'◇ 計画受理',WaitingInputs:'△ 入力待ち',Running:'▶ 稼働中',Completed:'✓ 完了',Cancelled:'× 取消済',RequestOpen:'◇ 配送受付',RequestCompleted:'✓ 配送完了',RequestCancelled:'× 配送取消済',RequestFailed:'! 配送失敗',MaintenancePlanned:'◇ 保全計画',MaintenanceRunning:'▶ 保全中',MaintenanceCompleted:'✓ 保全完了',MaintenanceCancelled:'× 保全取消済',Operational:'正常',MaintenanceWarning:'保全予告',MaintenanceDue:'保全期限',FacilityBroken:'故障',ConstructionPlanned:'◇ 建設計画受理',ConstructionWaitingInputs:'△ 建設材料待ち',ConstructionMovingInputs:'⇢ 建設材料輸送中',ConstructionReady:'◇ 施工準備完了',ConstructionRunning:'▶ 施工中',ConstructionCompleted:'✓ 完工',ConstructionCancelled:'× 建設取消済'};
let state=null, tab='production', selected={kind:'colony',id:null}, pending=null, busy=false, pollBusy=false;
let camera={x:0,y:0,z:1,r:0},cameraHistory=[],localJournal=[],lastFocus=null, formDraft={};
let renderOpsKey='', sessionGeneration=0, intentGeneration=0, pendingGeneration=null;
let responseRuntime=null;
let pendingCommand=null, pendingGhost=null, m1Draft={build:{},assignment:{}};
const loadUI={entry:null,action:null,starting:false,unresolvedStart:false,startTicket:null,confirming:false,cancelling:false,closeRequested:false,error:'',previewKey:null,renderKey:null,catalogKey:null,lastFocus:null};
const {StaleResponse,ResponseGate,RequestJournal}=RedDuneProtocol;
const responseGate=new ResponseGate();
const clientId=crypto.randomUUID();
const requestJournal=new RequestJournal(clientId);
let claimBusy=false,heartbeatBusy=false,policyEditGeneration=null,restartGeneration=null;
function sessionIdentity(data){const s=data?.shell?.session;return s?JSON.stringify([data.shell.runtimeId,s.authority,s.epochCounter,s.world,s.branch]):null;}
function activeLoad(){return ['reading','preview','activating','cancelling'].includes(state?.shell?.load.status);}
function resetSessionUI(){
  requestJournal.switched();sessionGeneration++;intentGeneration++;pending=null;pendingGeneration=null;pendingCommand=null;pendingGhost=null;busy=false;formDraft={};m1Draft={build:{},assignment:{}};selected={kind:'colony',id:null};renderOpsKey='';
  if($('#intent').open)$('#intent').close();
  for(const id of ['#policyDialog','#restartDialog'])if($(id).open)$(id).close();
  policyEditGeneration=null;restartGeneration=null;$('#packFile').value='';$('#packStatus').textContent='';
  loadUI.entry=null;loadUI.action=null;loadUI.starting=false;loadUI.unresolvedStart=false;loadUI.startTicket=null;loadUI.confirming=false;loadUI.cancelling=false;loadUI.error='';loadUI.previewKey=null;loadUI.renderKey=null;loadUI.catalogKey=null;
  $('#discardUnsaved').checked=false;
}
function acceptResponse(data,requestRuntime,isObservation){
  responseGate.accept(data,requestRuntime,isObservation);
  const shell=data.shell;
  if(data.view.m1!==null&&data.view.m1!==undefined)validateM1Projection(data.view.m1);
  const switched=state!==null&&sessionIdentity(state)!==sessionIdentity(data);
  responseRuntime=shell.runtimeId;
  if(switched)resetSessionUI();
  state=data;
  if(pending){
    const plan=pendingCommand?.kind==='cancelPlan'?data.view.m1?.plans.find(p=>p.id===pendingCommand.site):null;
    const staleRevision=pendingCommand?.kind==='cancelPlan'&&(!plan||plan.revision!==pendingCommand.revision);
    const staleOwner=pendingCommand?.kind==='deliver'&&[pendingCommand.source,pendingCommand.destination].some(id=>cacheGone(id,data.view));
    if(pending.boundary!==data.view.boundary||staleRevision||staleOwner){pending=null;pendingGeneration=null;pendingCommand=null;pendingGhost=null;intentGeneration++;$('#confirmIntent').disabled=true;$('#intentStatus').textContent=(staleOwner?'配送対象cacheが回収済み/撤去されました（gone）。対象':staleRevision?'建設計画のrevision':'境界')+'が変わったため、この意図は失効しました。閉じて新しく確認してください';}
  }
  render();reconcileLoad();devStatus(data.shell.devRevision?`DEV: checked ${data.shell.devRevision.slice(0,12)} · ${data.view.mode} · source reloadは新しいcampaignです`:'DEV: source revision未確認');
}
async function api(request,path='/api/command'){
  const requestRuntime=responseRuntime;
  if(request&&(!state||state.runtime.owner!=='mine'))throw new Error('このタブは閲覧中です。「操作権を取得」を選んでください');
  const record=request?requestJournal.prepare(request,state.shell,path):null;
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),8000);
  try{
    const resp=await fetch(path,{method:request?'POST':'GET',headers:{'X-Red-Dune-Client':clientId,...(request?{'Content-Type':'application/json'}:{})},body:record?.encoded,signal:controller.signal});
    const data=await resp.json();if(!resp.ok||data.error)throw new Error(data.error||`HTTP ${resp.status}`);
    if(record)requestJournal.resolved(record);
    try{acceptResponse(data,requestRuntime,!request);}catch(error){if(error instanceof StaleResponse){error.response=data;if(record)return data;}throw error;}
    renderRecovery();return data;
  }catch(error){
    if(record&&!(error instanceof StaleResponse)){requestJournal.uncertain(record);renderRecovery();}
    throw error;
  }finally{clearTimeout(timer);}
}
async function ownership(path){
  const requestRuntime=responseRuntime;
  const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Red-Dune-Client':clientId},body:JSON.stringify({clientId}),signal:AbortSignal.timeout(6000)});
  const data=await response.json();if(!response.ok||data.error)throw new Error(data.error||`HTTP ${response.status}`);
  acceptResponse(data,requestRuntime,false);return data;
}
async function claimControl(){if(claimBusy||document.hidden)return;claimBusy=true;try{const d=await ownership('/api/claim');if(d.result.reason)note(d.result.reason,'failed');}catch(error){reportError(error);}finally{claimBusy=false;}}
function renderRecovery(){
  const pending=requestJournal.pending;
  $('#retryRequest').hidden=!pending;
  $('#retryRequest').textContent=pending?'応答不明の操作を同じIDで照会・再送':'';
  $('#claimControl').hidden=state?.runtime.owner==='mine';
  $('#recoveryMessage').textContent=pending?'前の指示の結果は未確認です。新しい指示を止めています。同じ指示IDで安全に結果を確認できます':state?.runtime.fault?'ホスト障害で停止中。保存済みの進行は保持されています':state?.runtime.owner==='other'?'別のタブが操作しています。このタブは閲覧専用です':state?.runtime.owner==='none'?'操作権なし。時間は停止しています':activeLoad()?'保存の読込みを継続中です。「保存・枝の読込」で確認または取消してください':'接続が4秒以上途切れると、ホストは自動で時間を止めます';
}
$('#retryRequest').addEventListener('click',async()=>{const pending=requestJournal.pending;if(!pending)return;try{const data=await api(pending.request,pending.path);note(data.result.reason||'同じ指示IDの結果: '+data.result.status,data.result.reason?'failed':'accepted');if($('#intent').open)$('#intent').close();}catch(error){reportError(error);}renderRecovery();});
$('#claimControl').addEventListener('click',claimControl);
function refusal(data){return data.result.reason||data.result.status;}
function reportError(error){if(!(error instanceof StaleResponse))note(error.message,'failed');}
function note(text,status='intent'){localJournal.unshift({text,status,tick:state?.view.tick||'0'});localJournal=localJournal.slice(0,20);renderJournal();}
function button(text,action,cls=''){const b=el('button',text,cls);b.type='button';b.addEventListener('click',action);return b;}
function metric(label,value){const d=el('div',undefined,'metric');d.append(el('span',label),el('strong',value));return d;}
function cacheGone(id,view=state?.view){return !!view?.m1&&typeof id==='string'&&id.startsWith('GroundCache:')&&!view.m1.map.caches.some(c=>c.owner===id);}
function ownerLabel(id){return state.view.owners.find(x=>x.id===id)?.label||(cacheGone(id)?id+'（回収済み/撤去されました · gone）':id);}
function select(kind,id){const focusId=document.activeElement?.id;selected={kind,id};renderInspector();renderMap();if(focusId)document.getElementById(focusId)?.focus({preventScroll:true});}
function render(){
  const focused=document.activeElement; const focusId=focused?.id; const focusText=focused?.tagName==='BUTTON'?focused.textContent:null; const focusParent=focused?.closest('[id]')?.id;
  const detailsState=new Map([...document.querySelectorAll('details[data-cause]')].map(x=>[x.dataset.cause,x.open]));
  const v=state.view;if(selected.id===null)selected.id=v.colonies[v.colonies.length-1].id;
  const t=BigInt(v.tick), gameSeconds=t*3n, day=gameSeconds/86400n+1n, hours=gameSeconds/3600n%24n, mins=gameSeconds/60n%60n;
  $('#clock').replaceChildren(el('strong',`DAY ${day} · ${String(hours).padStart(2,'0')}:${String(mins).padStart(2,'0')}  ${v.mode==='Paused'?'Ⅱ 停止中':'▶ 進行中'}`),el('span',`tick ${fmt(v.tick)} · boundary ${fmt(v.boundary)}`));
  $('#pause').textContent=v.mode==='Paused'?'▶ 再開':'Ⅱ 一時停止';
  $$('[data-speed]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.speed===state.runtime?.speed?'true':'false'));
  $('#connection').textContent=`● Haskell live · ${state.runtime.owner==='mine'?'操作中':'閲覧'} · 20 Hz / ${state.runtime.speed}×`;
  renderRecovery();renderCampaign();
  $('#sessionState').textContent=`現在: World ${state.shell.session.world} / 枝 ${state.shell.session.branch} / ${state.shell.session.ruleset}${state.shell.session.dirty?' · 未保存の進行あり':''}`;
  renderScenario();renderSave();renderLibrary();renderCritical();renderMap();renderColonies();renderWork();renderInspector();renderJournal();
  const key=JSON.stringify([tab,v.sites.map(s=>[s.id,s.enabled]),v.owners.map(o=>[o.id,o.node]),v.m1?[v.m1.buildOptions,v.m1.workers,v.m1.targets,v.m1.activeShift]:null]);
  if(key!==renderOpsKey){renderOpsKey=key;renderOperations();}
  document.querySelectorAll('details[data-cause]').forEach(x=>{if(detailsState.has(x.dataset.cause))x.open=detailsState.get(x.dataset.cause);});
  if(focused&&!focused.isConnected){let replacement=focusId?document.getElementById(focusId):null;if(!replacement&&focusText){const scope=focusParent?document.getElementById(focusParent):document;replacement=[...(scope||document).querySelectorAll('button')].find(x=>x.textContent===focusText);}replacement?.focus({preventScroll:true});}
}
// S01 renderer: geometry, quantities, eligibility and preview outcomes are all
// projected by Haskell. Only screen-space transforms and editable drafts live here.
function validateM1Projection(m){
  if(m.version!=='1'||!m.map||!['placements','sources','roads','caches'].every(k=>Array.isArray(m.map[k]))||!['plans','workers','targets','buildOptions'].every(k=>Array.isArray(m[k])))throw new Error('S01 projectionの構造を確認できません。以前の表示を保持します');
  const decimal=x=>typeof x==='string'&&/^(0|[1-9][0-9]*)$/.test(x);
  if(!decimal(m.map.width)||!decimal(m.map.height)||m.map.width==='0'||m.map.height==='0'||!decimal(m.activeShift)||!decimal(m.credit))throw new Error('S01 projectionの数値形式を確認できません');
  if(m.plans.some(p=>!decimal(p.id)||!decimal(p.revision)||!Array.isArray(p.costs)||!Array.isArray(p.cancelLoss)||!Array.isArray(p.cancelReturn))||m.workers.some(w=>!Array.isArray(w.skills))||m.targets.some(t=>!t.target||!Array.isArray(t.rosters)||!t.crew||!Array.isArray(t.crew.available)||!Array.isArray(t.crew.selected))||m.buildOptions.some(o=>!Array.isArray(o.costs)))throw new Error('S01 projectionの計画・名簿を確認できません');
}
function renderScenario(){
  const m=state.view.m1;
  $$('[data-tab="construction"],[data-tab="workers"]').forEach(b=>b.hidden=!m);
  if(!m&&['construction','workers'].includes(tab)){tab='production';renderOpsKey='';$$('[data-tab]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.tab===tab)));}
  $('#legacyGuide').hidden=!!m;$('#mapSelectionHelp').hidden=!m;
  $('#scenarioIntro').textContent=m?`${m.scenario} · 現在勤務shift ${m.activeShift} · 信用 ${fmt(m.credit)}。建設計画、材料の実輸送、住民配属をつなぎます`:'北端の配給所には備蓄がありません。生産 → 現物輸送 → 配給をつなぎます';
  $('#scopeSummary').textContent=m?'建設・材料輸送・住民配属・生産・保全が同じHaskell世界で動きます。政策は通常の指示を実行し、物資を生成しません。研究・交易・co-opは含みません':'固定の設備作業員・運転手・保全crew。住民配属、建設、研究、契約、co-opは未実装';
  $('#mapProfile').textContent=m?`${m.scenario} / D0 ${m.map.width} × ${m.map.height} TILES`:'31 ROAD NODES / FOUR SETTLEMENTS';
  $('#mapLegend').textContent=m?'緑 完工 / 黄破線 計画 / 茶 施工 / ◆ cache / 青破線 未送信':'◇ 配給所　▰ 設備　● 車両';
  $('#map').setAttribute('viewBox',m?'0 0 1000 700':'0 0 1000 470');
  $('#map').setAttribute('role',m?'group':'img');
  $('#map').setAttribute('aria-label',m?'D0の実建物、建設計画、道路、自然源と地面cache':'4拠点を結ぶ道路、設備と現物輸送車');
}
const targetKey=t=>t?`${t.kind}:${t.id}`:'';
const targetText=t=>t?`${t.kind} #${t.id}`:'未配属';
function amountList(xs){return xs.length?xs.map(x=>`${resource(x.resource)} ${fmt(x.quantity)} ${units(x.resource)}`).join(' / '):'0';}
function portText(p){return p?`境界 (${p.boundary.x}, ${p.boundary.y}) → 接続tile (${p.connector.x}, ${p.connector.y})`:'portなし';}
function appendCrew(box,target){if(!target)return;const c=target.crew;box.append(el('p',`稼働可能crew ${c.available.join(', ')||'なし'} / 必要 ${c.required}人 · ${c.ready?'稼働条件を満たす':'待機'}`,c.ready?'good':'danger'),el('p',`実選出 ${c.selected.join(', ')||'なし'} · 原因 ${c.reason||'なし'} · ${target.busy?'Busy':'非Busy'}`));}
function renderConstructionForm(box){
  const m=state.view.m1,draft=m1Draft.build,form=el('form');form.id='constructionForm';
  box.append(el('p','ここでの入力は未送信。位置・費用・crew条件はHaskellのpreviewで確認します','meta'));
  const prototype=makeField(form,'buildPrototype','建設するもの',m.buildOptions.map(o=>[o.prototype,o.label+(o.enabled?'':' · '+(o.reason||'利用不可'))]),draft.prototype||m.buildOptions[0]?.prototype||'hand_pump');
  const colony=makeField(form,'buildColony','所属拠点',state.view.colonies.map(c=>[c.id,c.label]),draft.colony||state.view.colonies[0]?.id);
  const x=makeField(form,'buildX','D0 X tile（0基点）',null,draft.x||'66'),y=makeField(form,'buildY','D0 Y tile（0基点）',null,draft.y||'60');
  const rotation=makeField(form,'buildRotation','回転',[['R0','R0'],['R90','R90'],['R180','R180'],['R270','R270']],draft.rotation||'R0');
  const priority=makeField(form,'buildPriority','優先度',[['0','0 emergency'],['1','1 essential'],['2','2 normal'],['3','3 discretionary']],draft.priority||'2');
  const source=makeField(form,'buildSource','自然源（backendで適合を検証）',[['','指定なし'],...m.map.sources.map(s=>[s.id,`${s.kind} #${s.id} · ${resource(s.resource)} (${s.x},${s.y})`])],draft.source||'');
  const detail=el('div',undefined,'build-detail');detail.id='buildOptionDetail';form.append(detail);
  const saveDraft=()=>{m1Draft.build={prototype:prototype.value,colony:colony.value,x:x.value,y:y.value,rotation:rotation.value,priority:priority.value,source:source.value};};
  const submit=button('建設の意図を確認',()=>{saveDraft();const d=m1Draft.build;preview({kind:'placePlan',colony:d.colony,prototype:d.prototype,x:d.x,y:d.y,rotation:d.rotation,priority:d.priority,source:d.source||null});},'primary');submit.id='previewConstruction';
  const update=()=>{const o=m.buildOptions.find(o=>o.prototype===prototype.value),road=prototype.value==='road';if(road){rotation.value='R0';source.value='';}rotation.disabled=road;source.disabled=road;detail.replaceChildren();if(o)detail.append(el('p','全材料: '+amountList(o.costs)),el('p',`必要work ${fmt(o.required)} · crew ${fmt(o.crew)}人`),el('p',o.enabled?'計画可能。敷地やcommandの成立は確認時に検証':o.reason||'利用不可',o.enabled?'meta':'danger'));submit.disabled=!o?.enabled;saveDraft();};
  form.addEventListener('input',saveDraft);prototype.addEventListener('change',update);form.addEventListener('submit',e=>{e.preventDefault();submit.click();});form.append(submit);box.append(form);update();
  box.append(el('p','道路はR0・自然源なし。材料不足でも計画は作成可能ですが、全材料・crew・敷地条件が揃うまで施工は始まりません','meta'));
  const list=el('div',undefined,'m1-entity-list');m.plans.forEach(p=>list.append(button(`#${p.id} ${p.prototype} · ${p.phase}${p.blocked?' · '+p.blocked:''}`,()=>select('plan',p.id))));if(!m.plans.length)list.append(el('p','建設計画はまだありません','empty'));box.append(list);
}
function renderWorkerForm(box){
  const m=state.view.m1,draft=m1Draft.assignment,form=el('form');form.id='workerForm';
  box.append(el('p',`現在勤務shift ${m.activeShift}。名簿人数とは別に、稼働可能crew・待機理由をHaskellから表示します`,'meta'));
  const target=makeField(form,'workerTarget','配属先',m.targets.map(t=>[targetKey(t.target),t.label]),m.targets.some(t=>targetKey(t.target)===draft.target)?draft.target:targetKey(m.targets[0]?.target));
  const shift=makeField(form,'workerShift','対象shift',[['0','0 / A'],['1','1 / B'],['2','2 / C']],draft.shift||m.activeShift);
  const summary=el('div');summary.id='workerTargetSummary';const residents=el('fieldset',undefined,'resident-roster');residents.id='residentRoster';form.append(summary,residents);
  function paint(reset){
    const t=m.targets.find(t=>targetKey(t.target)===target.value),key=target.value+'@'+shift.value;
    if(reset||draft.key!==key){draft.residents=[...(t?.rosters.find(r=>r.shift===shift.value)?.residents||[])];draft.key=key;}
    draft.target=target.value;draft.shift=shift.value;summary.replaceChildren();residents.replaceChildren(el('legend','送信する名簿（全置換）'));
    if(t){summary.append(el('p',`${t.label} · colony ${t.colony} · 必要 ${t.required}人 · ${t.role}`));appendCrew(summary,t);t.rosters.forEach(r=>summary.append(el('p',`shift ${r.shift}: ${r.residents.join(', ')||'未配属'}`,'meta')));}
    m.workers.forEach(w=>{const row=el('div',undefined,'resident-option'),check=el('input');check.type='checkbox';check.id='resident-'+w.id;check.name='residents';check.value=w.id;check.checked=draft.residents.includes(w.id);
      check.addEventListener('change',()=>{draft.residents=check.checked?[...draft.residents.filter(id=>id!==w.id),w.id]:draft.residents.filter(id=>id!==w.id);});
      const text=el('label');text.htmlFor=check.id;text.append(el('strong',`#${w.id} · colony ${w.colony} · shift ${w.shift}`),el('span',`${w.status} · ${w.role||'未配属'} · ${targetText(w.target)}`),el('span',`健康 ${w.health} / 疲労 ${w.fatigue} / 床 ${typeof w.bed==='boolean'?(w.bed?'あり':'なし'):w.bed??'なし'}${w.forcedRestUntil?' / 強制休息until tick '+w.forcedRestUntil:''}`));row.append(check,text,button('技能',()=>select('worker',w.id),'worker-detail'));residents.append(row);
    });
  }
  target.addEventListener('change',()=>paint(true));shift.addEventListener('change',()=>paint(true));
  const submit=button('配属の意図を確認',()=>{const t=m.targets.find(t=>targetKey(t.target)===target.value);if(t)preview({kind:'assignWorkers',target:{...t.target},shift:shift.value,residents:[...draft.residents]});},'primary');submit.id='previewAssignment';submit.disabled=!m.targets.length;
  form.append(button('この名簿を空にする',()=>{draft.residents=[];paint(false);}),submit);form.addEventListener('submit',e=>{e.preventDefault();submit.click();});box.append(form);paint(false);
  box.append(el('p','運転者交代は同colonyの実住民配属の抽象です。通勤経路・乗降位置は未モデル化。旧driverが非勤務・強制休息・健康不可なら働かず、当該vehicle/shiftに実後任がいない間はNoDriverでedge残量・積荷・既支払燃料を保持します。交代自体の追加移動・再課金はありません','meta'),el('p','shift変更・別対象からの自動引き抜きは行いません。移動中の運転者解除等はBusyで失敗する場合があります。住民の適合・勤務条件はbackendが判定します','meta'),el('p','Transport技能の速度・容量・燃料bonusは未実装。配給所サービスは技能XPなし','meta'));
}
function renderPlanCancellation(box,p){
  box.append(el('p',`対象revision ${p.revision}。この境界の取消: ${p.cancelAllowed?'実行可能':'不可 · '+p.cancelFailure}`,p.cancelAllowed?'meta':'danger'));
  if(p.cancelAllowed)box.append(el('p','施工損失: '+amountList(p.cancelLoss),'danger'),el('p','到着済み現物からの返還: '+amountList(p.cancelReturn)));
  box.append(el('p','空の計画は無償取消。輸送中の材料は実Returnとなり、到着済み現物だけが返還対象です。完工済み設備は計画取消できません','meta'));
}
function renderM1Inspector(box,title,m){
  if(selected.kind==='plan'){
    const p=m.plans.find(p=>p.id===selected.id);if(!p)return false;title.textContent=`建設 #${p.id} · ${p.prototype}`;
    box.append(el('p',`${p.phase}${p.terminal?' · terminal':''} / job ${p.job}`),el('p',`(${p.x}, ${p.y}) ${p.rotation} · 自然源 ${p.source??'なし'}`),el('p',`${fmt(p.progress)} / ${fmt(p.required)} credit`),el('p','待機理由: '+(p.blocked||'なし')));
    p.costs.forEach(c=>{box.append(el('h3',resource(c.resource)),el('p',`必要 ${fmt(c.quantity)} / 現物 ${fmt(c.physical)} / 未受領 ${fmt(c.unreceived)}`));if(c.cause?.type)box.append(causeNode(c.cause,0));else if(c.cause)box.append(el('p','原因: '+c.cause));});
    appendCrew(box,m.targets.find(t=>t.target.kind==='construction'&&t.target.id===p.id));renderPlanCancellation(box,p);
    if(!p.terminal){const b=button('施工取消の意図を確認',()=>preview({kind:'cancelPlan',site:p.id,revision:p.revision}));b.id='previewPlanCancel';box.append(b);}
    [p.input,p.escrow].forEach(id=>{const o=state.view.owners.find(o=>o.id===id);if(o)box.append(stockPanel(o));});
    box.append(button('施工班を配属',()=>{m1Draft.assignment={target:targetKey({kind:'construction',id:p.id}),shift:m.activeShift};setTab('workers');}));return true;
  }
  if(selected.kind==='placement'){
    const p=m.map.placements.find(p=>p.id===selected.id);if(!p)return false;title.textContent=`${p.prototype} #${p.id}`;
    box.append(el('p',`${p.stage} · (${p.x}, ${p.y}) / ${p.width} × ${p.height} tile / ${p.rotation}`),el('p','自然源: '+(p.source??'なし')),el('p','実port: '+portText(p.port)));
    if(m.plans.some(x=>x.id===p.id))box.append(button('建設・取消の詳細',()=>select('plan',p.id)));
    if(state.view.sites.some(x=>x.id===p.id))box.append(button('生産・在庫の詳細',()=>select('site',p.id)));
    appendCrew(box,m.targets.find(t=>t.target.kind==='facility'&&t.target.id===p.id));return true;
  }
  if(selected.kind==='source'){
    const s=m.map.sources.find(s=>s.id===selected.id);if(!s)return false;title.textContent=`自然源 #${s.id}`;box.append(el('p',`${s.kind} / ${resource(s.resource)} · (${s.x}, ${s.y}) / ${s.width} × ${s.height} tile`),el('p','自然源は可搬在庫ではありません。採取・予約はkernelで処理されます','meta'));return true;
  }
  if(selected.kind==='cache'){
    const c=m.map.caches.find(c=>c.owner===selected.id);if(!c){title.textContent='GroundCache · '+selected.id;box.append(el('p','回収済み/撤去されました（gone）。この旧ownerへの配送意図は確定できません。最新の配送先を選び直してください','meta'));return true;}title.textContent='GroundCache · '+c.owner;
    box.append(el('p',`colony ${c.colony} / tile (${c.x}, ${c.y})`),el('p','reason: '+c.reasons.join(' / ')),el('p',`共用tile容量 ${fmt(c.capacity)} g / 現物 ${fmt(c.heldWeight)} / 空き ${fmt(c.freeWeight)}`),el('p',c.port?`実配送port (${c.port.x}, ${c.port.y})`:'未接続: 実配送portがないため配送できません',c.port?'meta':'danger'),el('p','通常のGroundCacheは非道路、TransportReturnは到着道路、Aidは別reason。有限の同一tile容量を共有し、満杯なら資産を消さずに待機します','meta'));
    c.stocks.forEach(s=>box.append(el('p',`${resource(s.resource)}: 現物 ${fmt(s.physical)} / 予約 ${fmt(s.reserved)} / 輸送中 ${fmt(s.inTransit)}`)));return true;
  }
  if(selected.kind==='worker'){
    const w=m.workers.find(w=>w.id===selected.id);if(!w)return false;title.textContent='住民 #'+w.id;box.append(el('p',`colony ${w.colony} · shift ${w.shift} · ${w.status}`),el('p',`${w.role||'未配属'} / ${targetText(w.target)}`),el('p',`健康 ${w.health} / 疲労 ${w.fatigue} / 床 ${typeof w.bed==='boolean'?(w.bed?'あり':'なし'):w.bed??'なし'}`));if(w.forcedRestUntil)box.append(el('p','強制休息until tick '+w.forcedRestUntil));
    w.skills.forEach(s=>box.append(el('h3',`${s.skill} · level ${s.level} / XP ${fmt(s.xp)}`),el('p',s.effect)));box.append(el('p','配給所サービスは技能XPを付与しません','meta'));return true;
  }
  return false;
}
function m1Geometry(m){const scale=Math.min(900/Number(m.map.width),620/Number(m.map.height));return {scale,point:p=>[50+Number(p.x)*scale,40+Number(p.y)*scale]};}
function m1Hit(group,kind,id,label){group.setAttribute('id',`m1-map-${kind}-${id}`);group.classList.add('map-hit');group.setAttribute('tabindex','0');group.setAttribute('role','button');group.setAttribute('aria-label',label);group.setAttribute('data-entity-kind',kind);group.setAttribute('data-entity-id',id);group.addEventListener('click',()=>select(kind,id));group.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();select(kind,id);}});if(selected.kind===kind&&selected.id===id)group.classList.add('m1-selected');}
function renderM1Map(g,m){
  const {scale,point}=m1Geometry(m);g.setAttribute('transform',`translate(${camera.x} ${camera.y}) translate(500 350) rotate(${camera.r}) scale(${camera.z}) translate(-500 -350)`);
  g.append(svg('rect',{x:50,y:40,width:Number(m.map.width)*scale,height:Number(m.map.height)*scale,fill:'#d5b890',stroke:'#78613f','stroke-width':2}),svg('text',{x:50,y:25},`D0 / ${m.map.width} × ${m.map.height} tile · (0,0) 左上`));
  m.map.sources.forEach(s=>{const [x,y]=point(s),group=svg('g');group.append(svg('rect',{x,y,width:Number(s.width)*scale,height:Number(s.height)*scale,fill:s.resource==='water'?'#84b3b8':'#a2a077',stroke:'#45625a','stroke-width':1}),svg('text',{x,y:y-5,class:'small'},`${s.kind} #${s.id}`));m1Hit(group,'source',s.id,`自然源 ${s.kind} #${s.id} (${s.x},${s.y})`);g.append(group);});
  m.map.roads.forEach(r=>{const [x,y]=point(r);g.append(svg('rect',{x,y,width:scale,height:scale,fill:'#67533f',class:'m1-road'}));});
  m.map.placements.forEach(p=>{const [x,y]=point(p),group=svg('g',{'data-stage':p.stage}),planned=p.stage==='PlanReserved',building=p.stage==='BuildingSite';group.append(svg('rect',{x,y,width:Number(p.width)*scale,height:Number(p.height)*scale,fill:planned?'#e6c262':building?'#b9683a':'#547d72',stroke:planned?'#735421':building?'#653523':'#203e39','stroke-width':building?2:1.4,'stroke-dasharray':planned?'3 2':'none'}),svg('title',{},`${p.prototype} #${p.id} · ${p.stage}`));if(p.port){const [px,py]=point(p.port.connector);group.append(svg('circle',{cx:px+scale/2,cy:py+scale/2,r:scale*.35,fill:'#fff8cf',stroke:'#244c43','stroke-width':1}));}m1Hit(group,'placement',p.id,`${p.prototype} #${p.id} ${p.stage} (${p.x},${p.y})`);g.append(group);});
  m.map.caches.forEach(c=>{const [x,y]=point(c),group=svg('g');group.append(svg('path',{d:`M${x+scale/2},${y-2} L${x+scale+2},${y+scale/2} L${x+scale/2},${y+scale+2} L${x-2},${y+scale/2} Z`,fill:'#8b4161',stroke:'#fff4d1','stroke-width':1.2}),svg('title',{},`GroundCache ${c.owner} · ${c.reasons.join('/')}`));m1Hit(group,'cache',c.owner,`GroundCache ${c.owner} (${c.x},${c.y}) ${c.reasons.join('/')}`);g.append(group);});
  state.view.vehicles.forEach(car=>{const p=car.position;if(!p.from||!p.to)return;const a=point(p.from),b=point(p.to),fraction=p.type==='edge'?1-Number(p.remaining)/Math.max(1,Number(p.cost)):0,x=a[0]+(b[0]-a[0])*fraction+scale/2,y=a[1]+(b[1]-a[1])*fraction+scale/2,group=svg('g');group.append(svg('circle',{cx:x,cy:y,r:scale*.6,fill:car.cargo.length?'#fbe166':'#f6f0df',stroke:'#243e37','stroke-width':1.3}));m1Hit(group,'vehicle',car.id,`輸送車 #${car.id} ${car.pickup?'空車回送 request #'+car.pickup.request+' → '+ownerLabel(car.pickup.source):car.block||''}`);g.append(group);});
  if(pendingGhost){const [x,y]=point(pendingGhost);g.append(svg('rect',{id:'planGhost',x,y,width:Number(pendingGhost.width)*scale,height:Number(pendingGhost.height)*scale,fill:'#fcfff2','fill-opacity':'.35',stroke:'#164f7a','stroke-width':2.5,'stroke-dasharray':'5 3','pointer-events':'none'}),svg('text',{x,y:y-8,class:'small'},'未送信ghost'));
  }
}
function renderGhostConfirmation(box,p){
  box.append(el('h3','未送信ghost（Haskell preview）'),el('p',`${p.prototype} · (${p.x}, ${p.y}) / ${p.width} × ${p.height} tile / ${p.rotation}`),el('p','自然源: '+(p.source??'なし')+' / '+portText(p.port)),el('p','費用: '+amountList(p.costs)),el('p',`必要work ${fmt(p.required)} · crew ${fmt(p.crew)}人`));
  const sketch=svg('svg',{viewBox:'0 0 260 120',role:'img','aria-label':`未送信 ${p.prototype} ghost ${p.width} × ${p.height} tile`,class:'ghost-preview'}),scale=Math.min(160/Number(p.width),70/Number(p.height));sketch.append(svg('rect',{x:30,y:20,width:Number(p.width)*scale,height:Number(p.height)*scale,fill:'#dfe7c6',stroke:'#164f7a','stroke-width':3,'stroke-dasharray':'6 4'}),svg('text',{x:30,y:110},`(${p.x}, ${p.y}) · ${p.rotation} · 未送信`));box.append(sketch);
}

function renderSave(){
 const s=state.save.current,success=s.lastSuccess;
 const status={neverSaved:'○ 未保存',writing:'↻ チェックポイントを書込み・耐久性検証中',saved:'✓ チェックポイント保存成功',failed:'! 保存失敗'}[s.status]||s.status;
 const n=$('#saveState');n.textContent=`${status}${success?' · tick '+fmt(success.tick)+' · 保存revision '+success.sequence:''}${state.shell.session.dirty?' · 現在の進行には未保存の変更あり':''}${state.save.pending?' · 保存要求を処理中':''}`;
 n.className=s.status==='failed'?'error':'';
 if(s.error){n.append(document.createTextNode(' · '+s.error));n.append(button('保存を再試行',()=>sendSave()));}
}
function renderCritical(){const crisis=state.view.colonies.filter(c=>c.needs.some(n=>n.critical));const box=$('#critical');box.replaceChildren();if(crisis.length){box.append(el('strong',`△ ${crisis.map(c=>c.label).join('・')}の生活在庫が6時間未満`),el('span','在庫があるだけでは届きません。配送先は配給所を指定し、実際の到着を確かめてください'));}else box.append(el('strong','✓ 全拠点に基準需要6時間以上の生活在庫'),el('span','表示は現在人口に基づく目安。消費・輸送の確定値は各拠点へ'));}
function renderColonies(){const target=$('#colonies');target.replaceChildren();state.view.colonies.forEach(c=>{const card=el('article',undefined,'colony-card'+(c.needs.some(n=>n.critical)?' critical-card':''));const title=el('div',undefined,'card-title');title.append(el('h3',c.label),el('span',`${c.residents}人 · 健康${fmt(c.health)}/1000`));card.append(title);c.needs.forEach(n=>{const row=el('div',undefined,'stock-row');row.append(el('span',`${n.resource==='water'?'◈':'◒'} ${resource(n.resource)}`),el('span',`${fmt(n.available)} ${units(n.resource)} / ${n.remainingHours===null?'需要なし':n.remainingHours+'時間'}`,n.critical?'danger':''));card.append(row);});card.append(el('p','残時間 = 現人口の基準日需要で算出（実績平均は未実装）','meta'),button('なぜ？ 在庫・輸送・生産を確認',()=>select('colony',c.id),'why-button'));target.append(card);});}
function renderOperations(){
 const box=$('#operations');box.replaceChildren();
 if(tab==='production')state.view.sites.forEach(s=>{const d=el('div',undefined,'operation-card');d.append(el('h3',s.label),el('p',`作業員 ${s.workers}${state.view.m1?'（配属・稼働可否は詳細へ）':'（固定）'} · ${s.enabled?'稼働許可':'停止指示'}`),el('p',s.outputs.map(o=>`${resource(o.resource)} ${fmt(o.quantity)} ${units(o.resource)}`).join(' / ')),button('生産指示を確認',()=>preview({kind:'produce',site:s.id})),button('設備の原因をみる',()=>select('site',s.id)));box.append(d);});
 if(tab==='logistics'){
  box.append(el('p','利用可能な現物と、配送先の容量をHaskellで検証します','meta'));
  const form=el('form');form.id='deliveryForm';
  const ownerOptions=state.view.owners.map(o=>[o.id,o.label+(o.node===null?' · 未接続（配送不可）':'')]);
  makeField(form,'source','送り元',ownerOptions,formDraft.source||state.view.sites[0]?.output||state.view.owners[0]?.id);
  makeField(form,'destination','送り先',ownerOptions,formDraft.destination||state.view.sites[1]?.input||state.view.owners[0]?.id);
  makeField(form,'resource','資源',state.view.resources.map(r=>[r.id,r.label+' ('+r.unit+')']),formDraft.resource||'water');
  makeField(form,'quantity','数量（整数、単位は資源欄）',null,formDraft.quantity||'60000');
  makeField(form,'priority','優先度',[['0','0 高'],['1','1'],['2','2'],['3','3 低']],formDraft.priority||'1');
  form.addEventListener('input',()=>{formDraft=Object.fromEntries(new FormData(form));});
  const submit=button('配送の意図を確認',()=>{formDraft=Object.fromEntries(new FormData(form));preview({kind:'deliver',...formDraft});},'primary');form.append(submit);form.addEventListener('submit',e=>{e.preventDefault();submit.click();});box.append(form);
 }
 if(tab==='maintenance'){
  box.append(el('p',state.view.m1?'必要crew・勤務可否は配属欄と設備詳細に表示します。保全も実配属が必要です':'固定crew各1人。備蓄部品は明示的な初期付与。実消費と取消損失を検証します','meta'));
  state.view.sites.forEach(s=>{const d=el('div',undefined,'operation-card');d.append(el('h3',s.label));if(!s.facility||s.facility.period==='0'){d.append(el('p','保全不要（期間0の設備）'));}else{
   const input=state.view.owners.find(o=>o.id===s.input);const warehouse=state.view.owners.find(o=>o.id.startsWith('Warehouse:')&&o.colony===input?.colony);
   d.append(el('p',`${phases[s.facility.status]||s.facility.status} · 稼働age ${fmt(s.facility.age)} / ${fmt(s.facility.period)}`),button('保全要求を確認',()=>preview({kind:'maintenance',target:s.id,source:warehouse?.id||s.input,return:warehouse?.id||s.input})));}box.append(d);});
 }
 if(state.view.m1&&tab==='construction')renderConstructionForm(box);
 if(state.view.m1&&tab==='workers')renderWorkerForm(box);
}
function makeField(form,name,label,options,value){const wrap=el('div',undefined,'form-field'),l=el('label',label);l.htmlFor='field-'+name;let input;if(options){input=el('select');options.forEach(([val,text])=>{const o=el('option',text);o.value=val;input.append(o);});}else{input=el('input');input.type='text';input.inputMode='numeric';input.pattern='[0-9]+';}input.id='field-'+name;input.name=name;input.value=value;wrap.append(l,input);form.append(wrap);return input;}
function renderWork(){const box=$('#worklist');box.replaceChildren();let count=0;const add=(title,status,detail,action)=>{count++;const row=el('div',undefined,'work-row'),txt=el('div',undefined,'grow');txt.append(el('strong',title),el('span',detail,'meta'));row.append(txt,el('span',phases[status]||status,'status'),action);box.append(row);};
 state.view.jobs.forEach(j=>add(`#${j.id} ${state.view.sites.find(s=>s.id===j.site)?.label||j.recipe}`,j.phase,`${fmt(j.progress)} / ${fmt(j.required)} credit${j.blocked?' · '+j.blocked:''}`,button('詳細',()=>select('job',j.id))));
 state.view.deliveries.forEach(d=>add(`#${d.id} ${resource(d.resource)} ${fmt(d.quantity)}`,d.status,`${ownerLabel(d.source)} → ${ownerLabel(d.destination)}${d.blocked?' · '+d.blocked:''}`,button('詳細',()=>select('delivery',d.id))));
 state.view.maintenance.forEach(m=>add(`#${m.id} 保全 #${m.target}`,m.phase,`${fmt(m.progress)} / ${fmt(m.required)} credit${m.blocked?' · '+m.blocked:''}`,button('詳細',()=>select('maintenance',m.id))));
 state.view.m1?.plans.forEach(p=>add(`#${p.id} 建設 ${p.prototype}`,p.phase,`${fmt(p.progress)} / ${fmt(p.required)} credit${p.blocked?' · '+p.blocked:''}`,button('詳細',()=>select('plan',p.id))));
 $('#jobCount').textContent=`直近${count}件（各種最大128件）`;if(!count)box.append(el('p','まだ指示はありません。左の生産指示から始めます','empty'));
}
function renderInspector(){const box=$('#inspectorContent');box.replaceChildren();const v=state.view;const title=$('#inspectorTitle');
 if(selected.kind==='colony'){const c=v.colonies.find(c=>c.id===selected.id);if(!c)return;title.textContent=c.label+' · 不足の原因';box.append(el('p',`確認済み / tick ${fmt(v.tick)} · 更新遅延0tick`,'meta'));c.needs.forEach(n=>{box.append(el('h3',resource(n.resource)));const m=el('div',undefined,'metric-grid');m.append(metric('基準日需要',fmt(n.requiredPerDay)+' '+units(n.resource)),metric('利用可能',fmt(n.available)+' '+units(n.resource)),metric('現在時間枠の需要',fmt(n.hourDue)),metric('現在時間枠の実配給',fmt(n.hourServed)));box.append(m);n.causes.forEach(cause=>box.append(causeNode(cause,0)));});}
 else if(selected.kind==='site'){const s=v.sites.find(s=>s.id===selected.id);if(!s)return;title.textContent=s.label;box.append(el('p',`設備 #${s.id} · ${s.enabled?'稼働許可':'停止中'} · ${v.m1?'作業員':'固定作業員'} ${s.workers}`));const acts=el('div',undefined,'inline-actions');acts.append(button('生産',()=>preview({kind:'produce',site:s.id})),button(s.enabled?'設備を停止':'設備を有効化',()=>preview({kind:'siteEnabled',site:s.id,enabled:!s.enabled})));box.append(acts);if(v.m1)appendCrew(box,v.m1.targets.find(t=>t.target.kind==='facility'&&t.target.id===s.id));if(s.facility)box.append(el('p',`保全: ${phases[s.facility.status]||s.facility.status} / condition ${s.facility.condition} / 稼働age ${s.facility.age}`));if(!s.requirements.length)box.append(el('p','自然源の実予約・採取を行う設備です。完了まで清水は出力庫に増えません'));s.requirements.forEach(c=>box.append(causeNode(c,0)));[s.input,s.output].forEach(id=>{const o=v.owners.find(o=>o.id===id);if(o)box.append(stockPanel(o));});}
 else if(selected.kind==='vehicle'){const car=v.vehicles.find(x=>x.id===selected.id);if(!car)return;title.textContent='輸送車 #'+car.id;box.append(el('p',`${car.kind} · ${car.driver?(v.m1?'運転者あり':'固定運転手あり'):'NoDriver'} · ${car.block||'移動可能'}`),el('p',`位置: ${car.position.type==='edge'?'edge '+car.position.from.id+' → '+car.position.to.id+' / 残り'+car.position.remaining+'tick':'node '+car.position.from.id}`));if(car.pickup)box.append(el('p',`空車回送: 配送要求 #${car.pickup.request} / 取りに行く庫 ${ownerLabel(car.pickup.source)}`),el('p',`到着先node ${car.pickup.node?.id??(car.pickup.node?.x!==undefined?'('+car.pickup.node.x+', '+car.pickup.node.y+')':car.pickup.node??'未確定')}。道路上を実移動中で、到着・積載済みではありません`,'meta'));if(car.shipment)box.append(el('p',`現在の積荷 #${car.shipment.id}: ${car.shipment.status} / 目的地 ${car.shipment.destination?ownerLabel(car.shipment.destination):'返送先探索中'}`));box.append(el('h3','現物荷台'));if(!car.cargo.length)box.append(el('p','空荷'));car.cargo.forEach(s=>box.append(el('p',`${resource(s.resource)} 現物 ${fmt(s.physical)} / 予約 ${fmt(s.reserved)}`)));box.append(el('p','位置はHaskellのedge進捗から描画。見た目の補間や視点変更をkernelへ送りません','meta'));}
 else if(selected.kind==='job'){const j=v.jobs.find(x=>x.id===selected.id);if(!j)return;title.textContent='生産仕事 #'+j.id;box.append(el('p',phases[j.phase]||j.phase),el('p',`${fmt(j.progress)} / ${fmt(j.required)} credit`),el('p','原因: '+(j.blocked||'確定blockなし')));if(!j.cancelAllowed)box.append(el('p','取消不可: '+j.cancelFailure));else if(j.cancelLoss.length)box.append(el('p','この境界で取消した場合の工程損失: '+j.cancelLoss.map(x=>`${resource(x.resource)} ${fmt(x.quantity)}`).join(' / '),'danger'));else box.append(el('p','この境界の生産取消損失: 0'));if(!j.terminal)box.append(button('取消を確認',()=>preview({kind:'cancelProduction',job:j.id})));else box.append(el('p','terminal: 再取消では元に戻りません'));box.append(button('設備へ',()=>select('site',j.site)));}
 else if(selected.kind==='delivery'){const d=v.deliveries.find(x=>x.id===selected.id);if(!d)return;title.textContent='配送要求 #'+d.id;box.append(el('p',phases[d.status]||d.status),el('p',`${resource(d.resource)} ${fmt(d.quantity)} ${units(d.resource)}`),el('p',`${ownerLabel(d.source)} → ${ownerLabel(d.destination)}`),el('p','未割当数量 '+fmt(d.remaining)+' / 原因 '+(d.blocked||'なし')));d.children.forEach(s=>box.append(button(`#${s.id} ${s.status} · 車両${s.vehicle} · ${fmt(s.quantity)}`,()=>select('vehicle',s.vehicle))));(d.returns||[]).forEach(r=>box.append(button(`返送 #${r.id} / ${r.status} → ${r.destination?ownerLabel(r.destination):'返送先探索中'}`,()=>select('vehicle',r.vehicle))));if(d.status==='RequestOpen')box.append(button('配送取消を確認',()=>preview({kind:'cancelDelivery',request:d.id})));box.append(el('p','積込前は予約解除。積載後の現物は瞬間返還されず、返送先の確保と実輸送が必要です','meta'));}
 else if(selected.kind==='maintenance'){const m=v.maintenance.find(x=>x.id===selected.id);if(!m)return;title.textContent='保全仕事 #'+m.id;box.append(el('p',phases[m.phase]||m.phase),el('p',`部品 ${m.parts} · ${m.progress}/${m.required} credit`),el('p','原因: '+(m.blocked||'なし')),el('p',m.terminal?'terminal: 再取消はできません':m.cancelAllowed?`この境界の取消: 損失 ${fmt(m.cancelLoss)}個 / 現物返還 ${fmt(m.cancelReturn)}個 / 予約解除 ${fmt(m.cancelReservationRelease)}個（進捗比例）`:'取消不可: '+m.cancelFailure));if(!m.terminal)box.append(button('保全取消を確認',()=>preview({kind:'cancelMaintenance',job:m.id})));}
 else if(v.m1&&renderM1Inspector(box,title,v.m1)){}
 else{title.textContent='連邦の状態';v.consumed.forEach(n=>box.append(metric('累積実消費 '+resource(n.resource),fmt(n.quantity)+' '+units(n.resource))));box.append(el('p','world '+v.world+' / branch '+v.branch));}
}
function stockPanel(o){const box=el('div');if(o.node===null)box.append(el('p','未接続: 現在の実配送portがないため配送できません','danger'));box.append(el('h3',o.label),el('p',`容量g: 現物 ${fmt(o.heldWeight)} / 予約 ${fmt(o.reservedWeight)} / 空き ${fmt(o.freeWeight)} / 総量 ${fmt(o.capacity)}`,'meta'));o.stocks.filter(s=>s.physical!=='0'||s.reserved!=='0'||s.inTransit!=='0').forEach(s=>box.append(el('p',`${resource(s.resource)}: 現物${fmt(s.physical)} / 予約${fmt(s.reserved)} / 輸送中${fmt(s.inTransit)}`)));return box;}
function causeNode(c,depth){const n=el('div',undefined,'cause');if(cacheGone(c.owner)){n.append(el('p',ownerLabel(c.owner)));return n;}if(c.type!=='Need'){n.append(el('p',c.type));return n;}n.append(el('strong',c.nearestCause),el('span','確定 / '+c.updatedTick,'tag'));const s=c.stock;n.append(el('p',`必要 ${fmt(c.required)} / 現物 ${fmt(s.physical)} / 予約 ${fmt(s.reserved)} / 輸送中 ${fmt(s.inTransit)}`));c.requests.forEach(r=>n.append(button(`配送 #${r.id} · ${r.block||r.status}`,()=>select('delivery',r.id))));c.shipments.forEach(s=>n.append(button(`積荷 #${s.id} / 車両${s.vehicle}: ${s.status}`,()=>select('vehicle',s.vehicle))));if(c.reservations.length)n.append(el('p','予約元: '+c.reservations.map(r=>`仕事${r.job} / ${fmt(r.amount)}`).join('、')));const details=el('details');details.dataset.cause=c.owner+':'+c.resource+':'+depth;details.open=depth===0;details.append(el('summary','生産側と依存先 ('+c.producers.length+')'));c.producers.forEach(p=>{details.append(button(p.label+' #'+p.site,()=>select('site',p.site)),el('p',`生産出力庫: 現物 ${fmt(p.output.physical)} / 利用可能 ${fmt(p.output.available)}`));p.dependencies.forEach(d=>details.append(causeNode(d,depth+1)));});n.append(details);if(depth===0){const ul=el('ul');c.recoveryOptions.forEach(x=>ul.append(el('li',x)));n.append(ul);}return n;}
function renderJournal(){const box=$('#journal');if(!box)return;box.replaceChildren();localJournal.slice(0,5).forEach(r=>{const n=el('div',undefined,'journal-row');n.append(el('span',`local intent / tick ${r.tick}`),el('strong',r.text,r.status==='failed'?'danger':''));box.append(n);});state?.view.receipts.slice(0,20).forEach(r=>{const n=el('div',undefined,'journal-row');n.append(el('span',`sequence ${r.sequence} / boundary ${r.boundary}`),el('strong',`${r.status==='accepted'?'✓ 受理':r.status==='failed'?'! 世界内失敗':'↺ 処理済み'} ${r.outcome}`,r.status==='failed'?'danger':'good'),el('div',r.command),el('span','Tx: '+r.tx));box.append(n);});if(!box.children.length)box.append(el('p','送信前の意図はworldを変えません。受理と完了は別です','empty'));}
const NS='http://www.w3.org/2000/svg';function svg(tag,attrs={},text){const n=document.createElementNS(NS,tag);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,String(v)));if(text!==undefined)n.textContent=text;return n;}
function coord(node){return [100+Number(node.x)*26,185+Number(node.x)*3-Number(node.y)*12];}
function renderMap(){if(!state)return;const g=$('#map-content');g.replaceChildren();g.setAttribute('transform',`translate(${camera.x} ${camera.y}) translate(500 235) rotate(${camera.r}) scale(${camera.z}) translate(-500 -235)`);const v=state.view;if(v.m1){renderM1Map(g,v.m1);return;}
 v.roads.forEach(r=>{const[a,b]=[coord(r.a),coord(r.b)];g.append(svg('line',{x1:a[0],y1:a[1],x2:b[0],y2:b[1],stroke:r.open?'#735e46':'#923e33','stroke-width':9,'stroke-linecap':'round'}),svg('line',{x1:a[0],y1:a[1],x2:b[0],y2:b[1],stroke:'#d2bb92','stroke-width':2,'stroke-dasharray':'3 8'}));});
 const hit=(kind,id,group)=>{group.classList.add('map-hit');group.setAttribute('tabindex','0');group.setAttribute('role','button');group.addEventListener('click',()=>select(kind,id));group.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();select(kind,id);}});};
 v.colonies.forEach((c,i)=>{if(!c.node)return;const[x,y]=coord(c.node),group=svg('g',{'aria-label':c.label+'の在庫と不足原因'});group.append(svg('line',{x1:x,y1:y,x2:x,y2:y+55,stroke:'#897149','stroke-width':4}));const cy=y+72;group.append(svg('path',{d:`M${x-28},${cy} l28,-14 28,14 -28,15z`,fill:'#eedbaa',stroke:'#67553c','stroke-width':2}),svg('path',{d:`M${x-28},${cy} v24 l28,15 28,-15 v-24 l-28,15z`,fill:'#a0845b',stroke:'#67553c','stroke-width':2}),svg('path',{d:`M${x},${cy+15} v24`,stroke:'#67553c','stroke-width':2}),svg('text',{x,y:cy+65,'text-anchor':'middle'},c.label),svg('text',{x,y:cy+84,'text-anchor':'middle',class:'small'},`${c.residents}人 / ${c.needs.some(n=>n.critical)?'△ 補給不足':'生活在庫あり'}`));if(selected.kind==='colony'&&selected.id===c.id)group.insertBefore(svg('ellipse',{cx:x,cy:cy+16,rx:45,ry:39,fill:'none',stroke:'#fff2a8','stroke-width':4}),group.firstChild);hit('colony',c.id,group);g.append(group);});
 v.sites.forEach(s=>{if(!s.node)return;const[x,y]=coord(s.node),cy=y-68,group=svg('g',{'aria-label':s.label+'の設備詳細'});group.append(svg('line',{x1:x,y1:y,x2:x,y2:cy+18,stroke:'#897149','stroke-width':4}));if(s.recipe==='hand_water'){group.append(svg('path',{d:`M${x-23},${cy-25} v45 a23,9 0 0 0 46,0 v-45`,fill:'#477a8c',stroke:'#304f5a','stroke-width':2}),svg('ellipse',{cx:x,cy:cy-25,rx:23,ry:9,fill:'#b9d1c8',stroke:'#304f5a','stroke-width':2}),svg('path',{d:`M${x+24},${cy} h18 v20`,fill:'none',stroke:'#344c50','stroke-width':6}));}else if(s.recipe==='grow'){group.append(svg('path',{d:`M${x-50},${cy+3} l47,-28 57,28 -48,28z`,fill:'#566b3d',stroke:'#3f502e','stroke-width':2}));for(let i=0;i<6;i++)group.append(svg('path',{d:`M${x-36+i*8},${cy+3-i*4} l41,23`,stroke:'#b4ba70','stroke-width':4}));}else{group.append(svg('path',{d:`M${x-37},${cy-6} l36,-21 42,21 -39,22z`,fill:'#9a6854',stroke:'#624637','stroke-width':2}),svg('path',{d:`M${x-37},${cy-6} v32 l39,22 39,-24 v-30 l-39,22z`,fill:'#c2ac85',stroke:'#624637','stroke-width':2}),svg('path',{d:`M${x+17},${cy-21} v-26 h12 v32`,fill:'#66726b',stroke:'#414b47','stroke-width':2}));}group.append(svg('text',{x,y:cy-52,'text-anchor':'middle'},s.label),svg('text',{x,y:cy+57,'text-anchor':'middle',class:'small'},v.jobs.some(j=>j.site===s.id&&j.phase==='Running')?'▶ 稼働中':!s.enabled?'Ⅱ 停止':'◇ 指示・材料を待機'));hit('site',s.id,group);g.append(group);});
 v.vehicles.forEach((car,i)=>{const p=car.position,a=coord(p.from),b=coord(p.to),fraction=p.type==='edge'?1-Number(p.remaining)/Math.max(1,Number(p.cost)):0,x=a[0]+(b[0]-a[0])*fraction,y=a[1]+(b[1]-a[1])*fraction-7-i%2*12,group=svg('g',{'aria-label':'輸送車 '+car.id+' '+(car.cargo.length?'積載中':'空荷')});group.append(svg('rect',{x:x-11,y:y-8,width:22,height:13,rx:3,fill:car.cargo.length?'#e9cf6c':'#e8e4cb',stroke:'#30443e','stroke-width':2}),svg('circle',{cx:x-6,cy:y+7,r:3,fill:'#30443e'}),svg('circle',{cx:x+6,cy:y+7,r:3,fill:'#30443e'}),svg('text',{x,y:y-15,'text-anchor':'middle',class:'small'},'#'+car.id));hit('vehicle',car.id,group);g.append(group);});
}
async function preview(command){if(busy||!state||activeLoad()||loadUI.starting||loadUI.unresolvedStart)return;if(command.kind==='deliver'&&[command.source,command.destination].some(id=>cacheGone(id))){note('! 配送対象cacheは回収済み/撤去されました（gone）。対象を選び直してください','failed');return;}const generation=sessionGeneration,intent=++intentGeneration,operation=Symbol('intent');busy=operation;lastFocus=document.activeElement;note('◇ 未送信の意図: '+command.kind);try{const data=await api({op:'preview',command});if(generation!==sessionGeneration||intent!==intentGeneration)return;if(data.result.status!=='intentPreview'){note('! 拒否: '+(data.result.reason||data.result.status),'failed');return;}pending=data.result.envelope;pendingGeneration=generation;pendingCommand=command;pendingGhost=data.result.previewPlan||null;const box=$('#intentBody');box.replaceChildren();box.append(el('pre',humanCommand(command)),el('p',data.result.costNotice||'確認中は時間が停止します。取消は巻き戻しではなく、実物の損失や返送を伴うことがあります'));data.result.predictedReceipts.forEach(r=>box.append(el('p','この境界での予測: '+r.outcome,r.status==='failed'?'danger':'good')));if(command.kind==='cancelPlan'){const plan=state.view.m1?.plans.find(p=>p.id===command.site);if(plan)renderPlanCancellation(box,plan);}
if(pendingGhost)renderGhostConfirmation(box,pendingGhost);
if(command.kind==='assignWorkers')box.append(el('p','全名簿を置換する指示です。空リストはこの対象・shiftの配属解除。勤務shift自体は変わらず、別対象からの引き抜きはできません'));
if(command.kind==='cancelProduction'){const job=state.view.jobs.find(j=>j.id===command.job);box.append(el('p',job.cancelAllowed?'確定previewの取消工程損失: '+(job.cancelLoss.length?job.cancelLoss.map(l=>resource(l.resource)+' '+fmt(l.quantity)).join(' / '):'0'):'取消不可: '+job.cancelFailure,'danger'));if(job.cancelAllowed&&job.cancelReturn.length)box.append(el('p','現物返還: '+job.cancelReturn.map(l=>resource(l.resource)+' '+fmt(l.quantity)).join(' / ')));}if(command.kind==='cancelMaintenance'){const m=state.view.maintenance.find(x=>x.id===command.job);box.append(el('p',m.cancelAllowed?`この停止境界の保全取消: 損失 ${fmt(m.cancelLoss)}個 / 現物返還 ${fmt(m.cancelReturn)}個 / 予約解除 ${fmt(m.cancelReservationRelease)}個`:'取消不可: '+m.cancelFailure,'danger'));}box.append(el('p',`controller ${pending.controller} / sequence ${pending.sequence} / boundary ${pending.boundary}`,'meta'));$('#intentStatus').textContent='未送信。受理後も完成や到着までは時間がかかります';$('#confirmIntent').disabled=false;$('#intent').showModal();renderMap();}catch(e){if(generation===sessionGeneration&&!(e instanceof StaleResponse))note('応答未確認: '+e.message,'failed');}finally{if(busy===operation)busy=false;}}
function humanCommand(c){if(c.kind==='placePlan')return `建設計画: ${state.view.m1?.buildOptions.find(o=>o.prototype===c.prototype)?.label||c.prototype}\n拠点 ${c.colony} / tile (${c.x}, ${c.y}) / ${c.rotation} / 優先度 ${c.priority}\n自然源 ${c.source??'未指定（backendで選択・検証）'}`;if(c.kind==='cancelPlan')return `建設計画 #${c.site} を取消\n確認対象revision ${c.revision}`;if(c.kind==='assignWorkers')return `配属名簿を全置換: ${state.view.m1?.targets.find(t=>targetKey(t.target)===targetKey(c.target))?.label||targetText(c.target)}\nshift ${c.shift} / 住民 ${c.residents.join(', ')||'なし（この対象・shiftの配属解除）'}`;if(c.kind==='produce')return '生産: '+state.view.sites.find(s=>s.id===c.site)?.label;if(c.kind==='deliver')return `${resource(c.resource)} ${fmt(c.quantity)} ${units(c.resource)}\n${ownerLabel(c.source)} → ${ownerLabel(c.destination)}\n優先度 ${c.priority}`;return JSON.stringify(c,null,2);}
$('#confirmIntent').addEventListener('click',async()=>{
  if(!pending||busy||pendingGeneration!==sessionGeneration)return;
  const generation=sessionGeneration,operation=Symbol('confirm'),sent=pending;busy=operation;
  // Never automatically retry an uncertain mutation or a former session's envelope.
  pending=null;pendingGeneration=null;pendingCommand=null;pendingGhost=null;$('#confirmIntent').disabled=true;$('#intentStatus').textContent='送信中。結果待ち';renderMap();
  try{const data=await api(sent);if(generation!==sessionGeneration)return;const receipts=data.result.receipts||[];
    if(!receipts.length||['admissionRejected','decodeRejected','loadRejected'].includes(data.result.status)){note('! 拒否: '+refusal(data),'failed');$('#intentStatus').textContent='拒否: '+refusal(data);return;}
    note(receipts.some(r=>r.status==='failed')?'! 指示は世界内で失敗しました。receiptを確認':'✓ 指示の結果を受信。完了・保存とは別です',receipts.some(r=>r.status==='failed')?'failed':'accepted');$('#intent').close();
  }catch(e){if(generation===sessionGeneration){$('#intentStatus').textContent='応答未確認: '+e.message+'。journalと最新stateを確認してください。自動再送はしません';note('! 応答未確認。成功とは表示しません','failed');}}
  finally{if(busy===operation)busy=false;}
});
$('#intent').addEventListener('close',()=>{if(pending)note('○ 未送信の意図を破棄（world取消ではありません）');intentGeneration++;pending=null;pendingGeneration=null;pendingCommand=null;pendingGhost=null;renderMap();if(lastFocus?.isConnected)lastFocus.focus();});
$('#pause').addEventListener('click',async()=>{if(!state)return;try{const d=await api({op:state.view.mode==='Paused'?'resume':'pause'});if(d.result.reason)note('! '+refusal(d),'failed');}catch(e){reportError(e);}});
$$('[data-speed]').forEach(b=>b.addEventListener('click',()=>api({speed:b.dataset.speed},'/api/speed').catch(reportError)));
$$('[data-tab]').forEach(b=>b.addEventListener('click',()=>setTab(b.dataset.tab)));
function setTab(value){tab=!state?.view.m1&&['construction','workers'].includes(value)?'production':value;$$('[data-tab]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.tab===tab?'true':'false'));renderOpsKey='';if(state)render();}
async function sendSave(){const generation=sessionGeneration;try{const data=await api({op:'save'});if(generation!==sessionGeneration)return;if(data.result.reason||/rejected|busy/i.test(data.result.status)){note('! 保存要求: '+refusal(data),'failed');return;}note('◇ snapshot要求。durability成功を待ちます');}catch(e){if(generation===sessionGeneration)reportError(e);}}
$('#save').addEventListener('click',()=>sendSave());
$('#scope').addEventListener('click',()=>{const box=$('#infoBody');box.replaceChildren();[state.campaign.brief,'建設・配属・実物輸送・保全・政策と目標判定はHaskellが実行します。JavaScriptは表示と入力だけです。','保存はホスト上の完全なcampaignチェックポイントです。研究・交易・co-opは含みません。'].forEach(s=>box.append(el('p',s)));box.append(el('p','Space 一時停止 / 1・2・3 速度 / L 配送 / N 不足原因 / B 建設（S01） / WASD 視点移動 / Q E 回転 / F 全域 / Esc 未送信tool取消 → 選択解除 → このmenu。視点を戻す操作だけがlocal undoです。'),el('p','完全remap、gamepad、音、全端末accessibility認証は未実装。100/150/200%とkeyboard focusをこの検証UIで確認します。'));$('#information').showModal();});
function cameraChange(next){cameraHistory.push({...camera});cameraHistory=cameraHistory.slice(-40);camera={...camera,...next};renderMap();}
$('#zoomIn').onclick=()=>cameraChange({z:Math.min(2.5,camera.z+.2)});$('#zoomOut').onclick=()=>cameraChange({z:Math.max(.5,camera.z-.2)});$('#cameraReset').onclick=()=>cameraChange({x:0,y:0,z:1,r:0});$('#cameraUndo').onclick=()=>{if(cameraHistory.length){camera=cameraHistory.pop();renderMap();}};
$('#scale').onchange=e=>{document.documentElement.style.fontSize=14*Number(e.target.value)/100+'px';document.body.classList.remove('scale-100','scale-150','scale-200');document.body.classList.add('scale-'+e.target.value);};
$('#contrast').onchange=e=>document.body.classList.toggle('high-contrast',e.target.checked);
$('#reduceMotion').onchange=e=>document.body.classList.toggle('reduced-motion',e.target.checked);
$('#map').addEventListener('wheel',e=>{e.preventDefault();cameraChange({z:Math.max(.5,Math.min(2.5,camera.z+(e.deltaY<0?.1:-.1)))});},{passive:false});
document.addEventListener('keydown',e=>{if(!state||e.defaultPrevented||e.target.matches('input,select,textarea,button,summary')||$('dialog[open]'))return;if(e.key==='Escape'){if(selected.kind!=='world'){selected={kind:'world',id:null};renderInspector();}else $('#scope').click();return;}const key=e.key.toLowerCase();if(key===' '){e.preventDefault();$('#pause').click();}if(['1','2','3'].includes(key))$(`[data-speed="${{'1':'1','2':'2','3':'4'}[key]}"]`).click();if(key==='l')setTab('logistics');if(key==='b'&&state.view.m1)setTab('construction');if(key==='n')select('colony',state.view.colonies.at(-1).id);if(key==='f')$('#cameraReset').click();if(key==='q'||key==='e')cameraChange({r:camera.r+(key==='q'?-10:10)});if('wasd'.includes(key)&&key.length===1)cameraChange({x:camera.x+(key==='a'?25:key==='d'?-25:0),y:camera.y+(key==='w'?25:key==='s'?-25:0)});});
$('#map').addEventListener('contextmenu',e=>{e.preventDefault();if($('#intent').open)$('#intent').close();else if(selected.kind!=='world'){selected={kind:'world',id:null};renderInspector();}else $('#scope').click();});
// Native library and load lifecycle. All transformations, IDs, available actions,
// warning text and preservation claims come from Haskell, never from this adapter.
const loadStatusLabels={idle:'未要求',reading:'読込・検証中',preview:'切替確認待ち',activating:'新しい枝をnative保存・検証中',cancelling:'取消処理待ち（現在のWorldを維持）',cancelled:'読込は取り消されました',activated:'native保存検証後、新しいsessionへ切替済み',failed:'読込・切替に失敗'};
function identityText(identity){return `World ${identity.world} / 枝 ${identity.branch===null?'確認時に割当（previewでは未確定）':identity.branch} / tick ${fmt(identity.tick)} / schema ${identity.schema} / ${identity.ruleset}`;}
function renderLibrary(){
  const {session,catalog,load}=state.shell, locked=activeLoad()||loadUI.starting||loadUI.unresolvedStart||loadUI.confirming||loadUI.cancelling||loadUI.closeRequested;
  $('#libraryCurrent').textContent=`World ${session.world} / 枝 ${session.branch} / tick ${fmt(state.view.tick)} / ${session.ruleset} / epoch ${session.epochCounter}\nauthority ${session.authority}`;
  $('#librarySaveState').textContent=(session.dirty?'未保存の進行あり。':'未保存進行フラグなし。')+' '+$('#saveState').textContent;
  $('#librarySave').disabled=['activating','cancelling'].includes(load.status)||loadUI.confirming;
  $('#refreshLibrary').disabled=catalog.status==='loading'||locked;
  $('#includeCompatibility').disabled=true;
  $('#catalogStatus').textContent=`保存一覧: ${catalog.status}${catalog.error?' · '+catalog.error:''}${catalog.warnings?.length?' · '+catalog.warnings.join(' / '):''}`;
  const catalogKey=JSON.stringify([catalog.entries,loadUI.entry,locked]);
  if(catalogKey!==loadUI.catalogKey){
    loadUI.catalogKey=catalogKey;const entries=$('#catalogEntries');entries.replaceChildren();
    catalog.entries.forEach(entry=>{const b=button('',()=>chooseEntry(entry.id),'catalog-entry');b.id='catalog-entry-'+catalog.entries.indexOf(entry);b.disabled=locked;b.setAttribute('aria-pressed',String(loadUI.entry===entry.id));b.append(el('strong',entry.label),el('span',`${entry.kind==='compatibility'?'互換性検証fixture':entry.kind} · ${identityText(entry)} · 世代 ${entry.sequence}`,'meta'));(entry.warnings||[]).forEach(w=>b.append(el('span',w)));entries.append(b);});
    if(!catalog.entries.length)entries.append(el('p',catalog.status==='loading'?'native保存の世代を確認中…':'選択可能な保存世代はありません。現在の枝を保存し、一覧を更新してください','empty'));
  }
  const entry=catalog.entries.find(e=>e.id===loadUI.entry);
  if(!entry){loadUI.entry=null;loadUI.action=null;}
  const selectionKey=JSON.stringify([entry,loadUI.action]);
  if(selectionKey!==loadUI.selectionKey){loadUI.selectionKey=selectionKey;const box=$('#librarySelection'),actions=$('#loadAction');box.replaceChildren();actions.replaceChildren();
    if(entry){box.append(el('p',entry.label),el('p',identityText(entry),'meta'));entry.actions.forEach(action=>{const option=el('option',action.label);option.value=action.id;actions.append(option);});if(!entry.actions.some(a=>a.id===loadUI.action))loadUI.action=entry.actions[0]?.id||null;actions.value=loadUI.action||'';}
    else box.append(el('p','上の一覧から読込元を選択してください','meta'));
  }
  $('#loadAction').disabled=locked||!entry;
  $('#previewLoad').disabled=locked||!entry||!entry.actions.some(a=>a.id===loadUI.action);
  const preview=load.preview;
  const previewKey=JSON.stringify([load.ticket,load.status==='preview'?preview:null]);
  if(previewKey!==loadUI.previewKey){loadUI.previewKey=previewKey;$('#discardUnsaved').checked=false;}
  const renderKey=JSON.stringify([load.ticket,load.status==='activated',preview]);
  if(renderKey!==loadUI.renderKey){loadUI.renderKey=renderKey;const box=$('#loadPreview');box.replaceChildren();
    if(preview){const grid=el('div',undefined,'identity-grid');[['読込元（変更せず保持）',preview.source],[load.status==='activated'?'確認した切替先（実際の枝は上欄）':'切替先（現在の枝とは別）',preview.target]].forEach(([title,identity])=>{const card=el('section',undefined,'identity-card');card.append(el('h4',title),el('p',identityText(identity)));grid.append(card);});box.append(grid);
      [['変更内容',preview.changes],['保持される内容',preview.preserved]].forEach(([title,items])=>{if(!items?.length)return;box.append(el('h4',title));const list=el('ul');items.forEach(item=>list.append(el('li',item)));box.append(list);});if(preview.warning)box.append(el('p',preview.warning,'danger'));
    }
  }
  $('#discardRow').hidden=!(load.status==='preview'&&preview?.dirtyCurrent);
  $('#loadStatus').textContent=(loadUI.starting||loadUI.unresolvedStart?'読込要求の応答待ち… ':loadUI.closeRequested?'閉じる前にnative読込の取消を確認中… ':'')+(loadStatusLabels[load.status]||load.status)+(load.ticket?' · ticket '+load.ticket:'')+(load.message?' · '+load.message:'');
  $('#loadError').textContent=[load.error,loadUI.error].filter(Boolean).join('\n');
  $('#loadPanel').setAttribute('aria-busy',String(['reading','activating','cancelling'].includes(load.status)||loadUI.starting||loadUI.confirming||loadUI.cancelling));
  $('#cancelLoad').disabled=!activeLoad()||load.status==='cancelling'||loadUI.cancelling;
  $('#confirmLoad').disabled=load.status!=='preview'||!load.ticket||loadUI.confirming||loadUI.cancelling||loadUI.closeRequested||(preview?.dirtyCurrent&&!$('#discardUnsaved').checked);
  $('#closeLibrary').textContent=loadUI.closeRequested?'取消を確認して閉じる':activeLoad()||loadUI.starting||loadUI.unresolvedStart?'読込を取り消して閉じる':'閉じる';
}
function discardGameplayIntent(){intentGeneration++;pending=null;pendingGeneration=null;pendingCommand=null;pendingGhost=null;renderMap();if($('#intent').open)$('#intent').close();}
function chooseEntry(id){if(activeLoad()||loadUI.starting)return;loadUI.entry=id;loadUI.action=null;loadUI.error='';renderLibrary();}
async function refreshLibrary(){if(!state||activeLoad()||loadUI.starting)return;loadUI.error='';try{const d=await api({op:'library'});if(d.result.status!=='catalogRequested')loadUI.error=refusal(d);}catch(e){if(!(e instanceof StaleResponse))loadUI.error=e.message;}renderLibrary();}
async function startLoad(){
  if(!state||activeLoad()||loadUI.starting||loadUI.unresolvedStart||loadUI.closeRequested)return;
  const entry=state.shell.catalog.entries.find(e=>e.id===loadUI.entry);
  if(!entry?.actions.some(a=>a.id===loadUI.action))return;
  discardGameplayIntent();const generation=sessionGeneration;loadUI.starting=true;loadUI.unresolvedStart=true;loadUI.startTicket=state.shell.load.ticket;loadUI.error='';renderLibrary();
  try{const d=await api({op:'previewLoad',entry:entry.id,action:loadUI.action});if(generation!==sessionGeneration)return;loadUI.unresolvedStart=false;if(d.result.status!=='loadPreviewRequested')loadUI.error=refusal(d);}
  catch(e){if(e instanceof StaleResponse&&e.response&&generation===sessionGeneration)loadUI.unresolvedStart=false;if(generation===sessionGeneration&&!(e instanceof StaleResponse))loadUI.error='読込要求の応答未確認: '+e.message+'。取消または切替完了を確認するまで画面を保持します';}
  finally{if(generation===sessionGeneration){loadUI.starting=false;renderLibrary();reconcileLoad();}}
}
async function confirmLoad(){
  const load=state?.shell.load,dirty=load?.preview?.dirtyCurrent;
  if(load?.status!=='preview'||!load.ticket||loadUI.confirming||loadUI.closeRequested||dirty&&!$('#discardUnsaved').checked)return;
  const generation=sessionGeneration;loadUI.confirming=true;loadUI.error='';renderLibrary();
  try{const d=await api({op:'activateLoad',ticket:load.ticket,discardUnsaved:dirty?$('#discardUnsaved').checked:false});if(generation!==sessionGeneration)return;if(d.result.status!=='loadActivationRequested')loadUI.error=refusal(d);}
  catch(e){if(generation===sessionGeneration&&!(e instanceof StaleResponse))loadUI.error='切替の応答未確認: '+e.message+'。成功とは表示しません。最新状態を待つか、読込を取り消してください';}
  finally{if(generation===sessionGeneration){loadUI.confirming=false;renderLibrary();reconcileLoad();}}
}
async function cancelLoad(){
  const load=state?.shell.load;
  if(!activeLoad()||!load.ticket||loadUI.cancelling||load.status==='cancelling')return;
  const generation=sessionGeneration;loadUI.cancelling=true;loadUI.error='';renderLibrary();
  try{const d=await api({op:'cancelLoad',ticket:load.ticket});if(generation!==sessionGeneration)return;if(d.result.reason)loadUI.error=refusal(d);}
  catch(e){if(generation===sessionGeneration&&!(e instanceof StaleResponse))loadUI.error='取消の応答未確認: '+e.message+'。画面を閉じず、接続と取消を再確認してください';}
  finally{if(generation===sessionGeneration){loadUI.cancelling=false;renderLibrary();finishLibraryClose();}}
}
function finishLibraryClose(){
  if(!loadUI.closeRequested||activeLoad()||loadUI.starting||loadUI.unresolvedStart||loadUI.confirming||loadUI.cancelling||loadUI.error)return;
  if(state?.shell.load.status==='activated')note('枝の切替完了を確認しました。取消は成立していません');
  loadUI.closeRequested=false;$('#library').close();
}
function reconcileLoad(){
  if(loadUI.unresolvedStart&&state.shell.load.ticket&&state.shell.load.ticket!==loadUI.startTicket){loadUI.unresolvedStart=false;loadUI.error='';}
  if(!loadUI.closeRequested)return;
  if(activeLoad()&&state.shell.load.status!=='cancelling'&&!loadUI.cancelling&&!loadUI.error)void cancelLoad();
  finishLibraryClose();
}
function closeLibrary(){loadUI.closeRequested=true;loadUI.error='';renderLibrary();reconcileLoad();}
$('#openLibrary').addEventListener('click',()=>{if(!state)return;loadUI.lastFocus=document.activeElement;discardGameplayIntent();loadUI.closeRequested=false;loadUI.error='';$('#library').showModal();renderLibrary();if(!activeLoad())void refreshLibrary();});
$('#closeLibrary').addEventListener('click',closeLibrary);
$('#library').addEventListener('cancel',event=>{event.preventDefault();closeLibrary();});
$('#library').addEventListener('close',()=>{if(activeLoad()||loadUI.starting||loadUI.unresolvedStart||loadUI.confirming){$('#library').showModal();closeLibrary();return;}if(loadUI.lastFocus?.isConnected)loadUI.lastFocus.focus();});
$('#refreshLibrary').addEventListener('click',refreshLibrary);
$('#includeCompatibility').addEventListener('change',refreshLibrary);
$('#loadAction').addEventListener('change',event=>{loadUI.action=event.target.value;renderLibrary();});
$('#previewLoad').addEventListener('click',startLoad);
$('#confirmLoad').addEventListener('click',confirmLoad);
$('#cancelLoad').addEventListener('click',cancelLoad);
$('#discardUnsaved').addEventListener('change',renderLibrary);
$('#librarySave').addEventListener('click',()=>sendSave());

async function poll(){if(pollBusy)return;pollBusy=true;try{await api(null,'/api/state');}catch(e){if(!(e instanceof StaleResponse)){$('#connection').textContent='! 接続未確認: '+e.message+' · 成功・切替は未確認';devStatus('DEV: host確認待ち。反映中・コンパイル失敗・停止の詳細は開発ターミナルで確認してください');}}finally{pollBusy=false;}}
async function firstConnect(){await poll();if(state?.runtime.owner==='none')await claimControl();}
firstConnect();setInterval(()=>{if(!document.hidden)poll();},400);
setInterval(async()=>{if(document.hidden||heartbeatBusy||state?.runtime.owner!=='mine')return;heartbeatBusy=true;try{await ownership('/api/heartbeat');}catch(error){if(!(error instanceof StaleResponse)){$('#connection').textContent='接続未確認。4秒の操作権期限で自動停止します';}}finally{heartbeatBusy=false;}},1000);
function pauseOnHide(){if(state?.runtime.owner==='mine')navigator.sendBeacon('/api/release',new Blob([JSON.stringify({clientId})],{type:'application/json'}));}
document.addEventListener('visibilitychange',()=>{if(document.hidden)pauseOnHide();else poll();});window.addEventListener('pagehide',pauseOnHide);
function renderCampaign(){
  const c=state.campaign;if(!c)return;
  $('#campaignTitle').textContent=c.title;
  $('#campaignBrief').textContent=c.brief;
  $('#campaignTime').textContent=`${c.elapsedHours} / ${c.requiredHours} game hours · ${c.scenario}`;
  $('#objectives').replaceChildren(...c.objectives.map(o=>{const row=el('li',undefined,o.complete?'complete':'');row.append(el('strong',(o.complete?'✓ ':'○ ')+o.title),el('span',o.progress));return row;}));
  const ended=c.ending!=='Ongoing';$('#campaignEnding').hidden=!ended;$('#campaignEnding').textContent=ended?(c.ending==='SettlementSecured'?'SETTLEMENT SECURED · 住民と新しい補給網が安定しました。保存して別のシナリオへ進めます':c.ending):'';
  $('#enablePolicies').disabled=state.runtime.owner!=='mine'||ended;
  $('#disablePolicies').disabled=state.runtime.owner!=='mine'||ended;
  const pack=state.pack;$('#packIdentity').textContent=pack?`${pack.title} · revision ${pack.revision} · identity ${pack.identity}${pack.stagedRevision?' · 次回 '+pack.stagedTitle+' · revision '+pack.stagedRevision+' · identity '+pack.stagedIdentity:''}`:'';
  const policies=state.policies;
  const box=$('#policySummary');box.replaceChildren();
  if(policies){box.append(el('p',policies.enabled?'生活維持の政策: 実行中':'生活維持の政策: 停止'));
    policies.deliveries.forEach(p=>{const row=el('div',undefined,'policy-row');row.append(el('strong',p.id+' · '+resource(p.resource)),el('p',`${ownerLabel(p.destination)} · 在庫 ${fmt(p.available)} / 輸送中 ${fmt(p.incoming)} / 目標 ${fmt(p.target)} · ${p.reason||p.status||'Haskellが実行条件を評価'}`));const enabled=button(p.enabled?'停止':'有効にする',()=>campaignAction({op:'policy',id:p.id,enabled:!p.enabled,target:p.target,batch:p.batch}));enabled.id='policy-toggle-'+p.id;const edit=button('量を調整',()=>editPolicy(p));edit.id='policy-edit-'+p.id;row.append(enabled,edit);box.append(row);});
  }
  $('#expansionStatus').textContent=state.buildQueue?.length?`順番に施工中: ${state.buildQueue.length}段階待ち。材料輸送と配属が必要です`:state.notices?.join(' / ')||'西側の倉庫と接続道路を、実際の建設計画として順番に作ります';
  $('#expandWarehouse').disabled=!policies?.enabled||!!state.buildQueue?.length||ended||state.runtime.owner!=='mine';
}
async function campaignAction(action){const generation=sessionGeneration;try{const d=await api(action);if(generation===sessionGeneration)note(d.result.reason||d.result.message||d.result.status,d.result.reason?'failed':'accepted');}catch(error){if(generation===sessionGeneration)reportError(error);}}
$('#enablePolicies').addEventListener('click',()=>campaignAction({op:'configure',preset:'survival'}));
$('#expandWarehouse').addEventListener('click',()=>campaignAction({op:'expand',prototype:'warehouse'}));
$('#disablePolicies').addEventListener('click',()=>campaignAction({op:'configure',preset:'off'}));
$('#openRestart').addEventListener('click',()=>{restartGeneration=sessionGeneration;$('#restartDiscard').checked=false;$('#restartDialog').showModal();});
$('#confirmRestart').addEventListener('click',async()=>{if(restartGeneration!==sessionGeneration)return;if(state.shell.session.dirty&&!$('#restartDiscard').checked){$('#restartStatus').textContent='未保存の進行を破棄することを確認してください';return;}try{const d=await api({op:'restart',scenario:$('#scenarioChoice').value,discardUnsaved:$('#restartDiscard').checked});if(d.result.status==='restarted')$('#restartDialog').close();else $('#restartStatus').textContent=refusal(d);}catch(error){$('#restartStatus').textContent=error.message;}});
$('#stagePack').addEventListener('click',async()=>{const generation=sessionGeneration,expectedRevision=state.pack.stagedRevision||state.pack.revision;try{const file=$('#packFile').files[0];if(!file)throw new Error('pack JSONを選んでください');if(file.size>60000)throw new Error('ブラウザからのpackは60 KiB以内です。大きいpackはRED_DUNE_PACKで起動してください');const packText=await file.text();if(generation!==sessionGeneration)return;const d=await api({op:'stagePackText',expectedRevision,packText});if(generation===sessionGeneration)$('#packStatus').textContent=d.result.reason||d.result.message||d.result.status;}catch(error){if(generation===sessionGeneration)$('#packStatus').textContent=error.message;}});

function editPolicy(policy){policyEditGeneration=sessionGeneration;$('#policyId').value=policy.id;$('#policyEnabled').checked=policy.enabled;$('#policyTarget').value=policy.target;$('#policyBatch').value=policy.batch;$('#policyEditTitle').textContent='政策を調整: '+policy.id;$('#policyEditStatus').textContent='';$('#policyDialog').showModal();}
$('#confirmPolicy').addEventListener('click',async()=>{if(policyEditGeneration!==sessionGeneration)return;const generation=sessionGeneration;try{const d=await api({op:'policy',id:$('#policyId').value,enabled:$('#policyEnabled').checked,target:$('#policyTarget').value,batch:$('#policyBatch').value});if(generation!==sessionGeneration)return;if(d.result.status==='accepted')$('#policyDialog').close();else $('#policyEditStatus').textContent=refusal(d);}catch(error){if(generation===sessionGeneration)$('#policyEditStatus').textContent=error.message;}});
