/* This is a recorded-answer viewer. Shapes, transitions, search, constraint
   solving and row clearing are exported from SWI-Prolog, never recomputed here. */
(() => {
  'use strict';
  const D = JSON.parse(document.getElementById('guide-data').textContent);
  const $ = id => document.getElementById(id);
  const setText = (id, value) => { $(id).textContent = value; };
  const colors = {i:'#58d8e8',o:'#f4ce60',t:'#b995f3',s:'#79d6a4',z:'#ef8391',j:'#749eef',l:'#f2ae70'};
  const actionNames = {left:'左へ',right:'右へ',down:'下へ',cw:'右回転',ccw:'左回転'};
  const actionSymbols = {left:'←',right:'→',down:'↓',cw:'↻',ccw:'↺'};
  const poseText = p => `pose(${p.kind},${p.rotation},${p.x},${p.y})`;
  const cellText = cells => `[${cells.map(([x,y])=>`${x}-${y}`).join(',')}]`;
  const svgNS = 'http://www.w3.org/2000/svg';
  function svgElement(name, attrs, text) {
    const el = document.createElementNS(svgNS, name);
    for (const [key,value] of Object.entries(attrs || {})) el.setAttribute(key,String(value));
    if (text !== undefined) el.textContent = text;
    return el;
  }

  // Generic geometry display only: every colored cell comes from exported data.
  function drawBoard(id, board, options={}) {
    const {x0=0,x1=9,y0=0,y1=19,active=null,target=[],origin=null,
           collision=[],label='Prologから記録した盤面'} = options;
    const cell=26,left=30,top=26,width=(x1-x0+1)*cell+left+10,height=(y1-y0+1)*cell+top+10;
    const svg=svgElement('svg',{viewBox:`0 0 ${width} ${height}`,width,height,role:'img','aria-label':label});
    svg.append(svgElement('title',{},label));
    svg.append(svgElement('rect',{x:0,y:0,width,height,rx:5,fill:'#101b2a'}));
    const sx=x=>left+(x-x0)*cell,sy=y=>top+(y-y0)*cell;
    const visible=(x,y)=>x>=x0&&x<=x1&&y>=y0&&y<=y1;
    for(let y=y0;y<=y1;y++) for(let x=x0;x<=x1;x++) {
      const inside=x>=0&&x<10&&y>=-4&&y<20;
      svg.append(svgElement('rect',{x:sx(x),y:sy(y),width:cell,height:cell,
        fill:y<0?'#15222d':'#111e2b',stroke:inside?'#29394a':'#563b40','stroke-width':.75,
        'stroke-dasharray':y<0?'3 3':'none'}));
    }
    for(let x=x0;x<=x1;x++) svg.append(svgElement('text',{x:sx(x)+cell/2,y:17,fill:'#b1c4cf','font-size':11.5,'text-anchor':'middle','font-family':'Consolas,monospace'},x));
    for(let y=y0;y<=y1;y++) svg.append(svgElement('text',{x:left-7,y:sy(y)+cell/2+4,fill:y<0?'#68818d':'#b1c4cf','font-size':11.5,'text-anchor':'end','font-family':'Consolas,monospace'},y));
    if(y0<0&&y1>=0) svg.append(svgElement('line',{x1:left,x2:left+(x1-x0+1)*cell,y1:sy(0),y2:sy(0),stroke:'#8aa9ac','stroke-width':1.6}));
    function solid(x,y,color) {
      if(!visible(x,y)) return;
      svg.append(svgElement('rect',{x:sx(x)+2,y:sy(y)+2,width:cell-4,height:cell-4,fill:color,rx:1}));
      svg.append(svgElement('rect',{x:sx(x)+2,y:sy(y)+2,width:cell-4,height:2,fill:'#ffffff',opacity:.23}));
    }
    board.forEach(([x,y,p])=>solid(x,y,colors[p]||'#8c9aab'));
    if(active) active.cells.forEach(([x,y])=>solid(x,y,colors[active.kind]||'#b995f3'));
    target.forEach(([x,y])=>{if(visible(x,y)) svg.append(svgElement('rect',{
      x:sx(x)+1.5,y:sy(y)+1.5,width:cell-3,height:cell-3,fill:'#cab8f2',
      'fill-opacity':.10,stroke:'#f0f5fa','stroke-width':1.9}));});
    collision.forEach(([x,y])=>{if(visible(x,y)) {
      svg.append(svgElement('rect',{x:sx(x)+1,y:sy(y)+1,width:cell-2,height:cell-2,fill:'#d65062','fill-opacity':.48,stroke:'#ff9eaa','stroke-width':2}));
      svg.append(svgElement('path',{d:`M ${sx(x)+6} ${sy(y)+6} l 14 14 M ${sx(x)+20} ${sy(y)+6} l -14 14`,stroke:'#ffe2e7','stroke-width':2,fill:'none'}));
    }});
    if(origin&&visible(origin.x,origin.y)) {
      svg.append(svgElement('circle',{cx:sx(origin.x)+cell/2,cy:sy(origin.y)+cell/2,r:5.5,fill:'#102831',stroke:'#c7f1cf','stroke-width':2}));
      svg.append(svgElement('circle',{cx:sx(origin.x)+cell/2,cy:sy(origin.y)+cell/2,r:1.4,fill:'#e7ffe9'}));
    }
    $(id).replaceChildren(svg);
  }

  for(const el of document.querySelectorAll('[data-excerpt]')) {
    const record=D.excerpts[el.dataset.excerpt];
    el.textContent=record.text;
    const source=document.createElement('span');source.className='code-source';
    source.textContent=`実ソース ${record.file}:${record.line}`;
    el.parentElement.after(source);
  }

  let qIndex=0,qFrame=0,qTimer=null;
  const visibleCandidates=()=>D.demo.candidates.map((c,i)=>({c,i})).filter(({c})=>!$('clear-filter').checked||c.lines>0);
  function stopQ(){if(qTimer!==null)clearInterval(qTimer);qTimer=null;$('q-play').textContent='再生';$('q-play').setAttribute('aria-pressed','false');}
  function candidateOptions(){
    const list=visibleCandidates();
    if(!list.some(({i})=>i===qIndex))qIndex=list[0].i;
    $('candidate-select').replaceChildren(...list.map(({c,i})=>{
      const op=document.createElement('option');op.value=i;
      op.textContent=`候補 ${String(i+1).padStart(2,'0')} / ${c.lines}行消去 · ${c.path.length}手 · 回転${c.pose.rotation}`;
      return op;
    }));
    $('candidate-select').value=String(qIndex);
  }
  function drawQ(){
    const focusedStep=document.activeElement?.dataset?.actionStep;
    const c=D.demo.candidates[qIndex],last=c.frames.length,done=qFrame===last;
    drawBoard('q-board',done?c.after:D.demo.board,{y0:-4,active:done?null:c.frames[qFrame],
      target:done?[]:c.cells,label:`候補${qIndex+1}。${done?'固定と消去後':qFrame+'手目の姿勢'}。${c.lines}行消去。`});
    setText('candidate-summary',`${c.lines}行消去 / ${c.path.length}手の操作列`);
    setText('candidate-pose',poseText(c.pose));
    $('q-timeline').max=last;$('q-timeline').value=qFrame;
    setText('q-frame-label',done?'固定・消去後':`${qFrame} / ${c.path.length}手`);
    setText('q-status',done?`固定後、${c.lines}行が消えた。残る盤面もPrologからの記録。`:
      qFrame===0?'開始姿勢。白い着地点まで、一手ずつ確かめられる。':
      `${qFrame}手目：${actionNames[c.path[qFrame-1]]} → ${poseText(c.frames[qFrame])}`);
    $('q-back').disabled=qFrame===0;$('q-step').disabled=done;
    const actions=c.path.map((action,i)=>{
      const b=document.createElement('button');b.type='button';b.textContent=`${i+1} ${actionSymbols[action]}`;
      b.dataset.actionStep=String(i+1);
      b.className=[i<qFrame?'done':'',i+1===qFrame?'current':'',(action==='cw'||action==='ccw')?'turn':''].join(' ');
      b.title=`${i+1}手目：${actionNames[action]}`;b.setAttribute('aria-label',b.title);
      b.addEventListener('click',()=>{stopQ();qFrame=i+1;drawQ();});return b;
    });
    const lock=document.createElement('button');lock.type='button';lock.textContent='固定・消去';lock.className=`lock ${done?'current':''}`;
    lock.dataset.actionStep=String(last);
    lock.addEventListener('click',()=>{stopQ();qFrame=last;drawQ();});
    $('q-actions').replaceChildren(...actions,lock);
    if(focusedStep)$('q-actions').querySelector(`[data-action-step="${focusedStep}"]`)?.focus({preventScroll:true});
  }
  function chooseCandidate(i){stopQ();qIndex=i;qFrame=0;candidateOptions();drawQ();}
  $('candidate-select').addEventListener('change',e=>chooseCandidate(Number(e.target.value)));
  for(const [id,delta] of [['candidate-prev',-1],['candidate-next',1]]) $(id).addEventListener('click',()=>{
    const list=visibleCandidates(),at=list.findIndex(({i})=>i===qIndex);
    chooseCandidate(list[(at+delta+list.length)%list.length].i);
  });
  $('clear-filter').addEventListener('change',()=>{stopQ();qFrame=0;candidateOptions();drawQ();});
  $('motion-example').addEventListener('click',()=>{$('clear-filter').checked=false;chooseCandidate(D.demo.motion_example_index);});
  $('q-reset').addEventListener('click',()=>{stopQ();qFrame=0;drawQ();});
  $('q-back').addEventListener('click',()=>{stopQ();qFrame=Math.max(0,qFrame-1);drawQ();});
  $('q-step').addEventListener('click',()=>{stopQ();qFrame=Math.min(D.demo.candidates[qIndex].frames.length,qFrame+1);drawQ();});
  $('q-result').addEventListener('click',()=>{stopQ();qFrame=D.demo.candidates[qIndex].frames.length;drawQ();});
  $('q-timeline').addEventListener('input',e=>{stopQ();qFrame=Number(e.target.value);drawQ();});
  $('q-play').addEventListener('click',()=>{
    if(qTimer!==null){stopQ();return;}
    const last=D.demo.candidates[qIndex].frames.length;if(qFrame===last)qFrame=0;
    $('q-play').textContent='停止';$('q-play').setAttribute('aria-pressed','true');drawQ();
    qTimer=setInterval(()=>{qFrame++;drawQ();if(qFrame>=last)stopQ();},220);
  });
  setText('query-observation',`${D.demo.info.poses}姿勢 → ${D.demo.info.landings}候補 / 書出時 ${(D.demo.info.seconds*1000).toFixed(1)} ms`);
  candidateOptions();drawQ();

  let answerIndex=0;
  function drawInverse(){
    const ex=D.inverse.find(x=>x.id===$('target-select').value),p=ex.solutions[answerIndex]||null;
    const xs=ex.cells.map(x=>x[0]),ys=ex.cells.map(x=>x[1]);
    drawBoard('target-board',[],{x0:Math.max(0,Math.min(...xs)-2),x1:Math.min(9,Math.max(...xs)+2),
      y0:Math.max(0,Math.min(...ys)-2),y1:Math.min(19,Math.max(...ys)+2),
      target:ex.cells,active:p,origin:p,label:`四つの目標セル。${p?poseText(p):'表示中の解なし'}`});
    setText('target-query',`?- cover_cells(\n     ${cellText(ex.cells)},\n     Pose).`);
    setText('target-answer',p?`Pose = ${poseText(p)}${answerIndex<ex.solutions.length-1?' ;':' .'}`:'false.（これ以上の解なし）');
    setText('answer-caption',ex.solutions.length===0?'七種類・四つの向き・許した原点の範囲で、この四マスを覆う解はない。':
      p?`記録された解 ${answerIndex+1} / ${ex.solutions.length}。丸印は原点のマス。種類・向き・原点を未定にして得た。`:
      `全${ex.solutions.length}解を見終えた。ここで変えたのは、答えの表示順。ゲームの時計ではない。`);
    $('answer-next').disabled=answerIndex>=ex.solutions.length;
    $('answer-reset').disabled=ex.solutions.length===0;
  }
  $('target-select').addEventListener('change',()=>{answerIndex=0;drawInverse();});
  $('answer-next').addEventListener('click',()=>{answerIndex++;drawInverse();});
  $('answer-reset').addEventListener('click',()=>{answerIndex=0;drawInverse();});
  drawInverse();
  setText('ordinary-equality',`A = ${D.unification.ordinary_equal}`);
  setText('integer-equality',`A = ${D.unification.integer_equal}`);

  let collisionExample=false;
  function drawConstraintBoard(){
    const p=collisionExample?D.constraints.rejected_pose:D.constraints.known_pose;
    drawBoard('constraint-board',D.constraints.board,{x0:0,x1:9,y0:16,y1:19,
      active:p,origin:p,collision:collisionExample?[D.constraints.board[0].slice(0,2)]:[],
      label:`原点X=${p.x}のO。${collisionExample?'既存セル(4,19)と衝突する':'盤面内に置ける'}`});
    $('collision-example').setAttribute('aria-pressed',String(collisionExample));
    $('collision-example').textContent=collisionExample?'収まるX=4の表示に戻す':'範囲表示に残るX=2を見てみる';
    setText('known-verdict',collisionExample?'X=2：境界内だが、赤い(4,19)で衝突する。制約全体には反する。':'X=4：実際に置ける。');
    setText('known-query',collisionExample?`?- legal_pose([cell(4,19,j)],\n              pose(o,0,2,18), Cells).\nfalse.`:
      `?- legal_pose([cell(4,19,j)],\n              pose(o,0,4,18), Cells).\nCells = ${cellText(D.constraints.known_cells)}.`);
  }
  $('collision-example').addEventListener('click',()=>{collisionExample=!collisionExample;drawConstraintBoard();});
  function drawConstraintStage(){
    const stage=Number($('constraint-stage').value),values=stage===3?D.constraints.answers:D.constraints.stages[stage];
    $('domain-values').replaceChildren(...D.constraints.stages[0].map(x=>{
      const el=document.createElement('span');el.textContent=x;
      if(!values.includes(x))el.className='removed';
      else if(stage===2&&(x===2||x===3))el.className='collision-hint';
      el.title=values.includes(x)?`X=${x} ${stage===3?'は実際の解':'はXの範囲表示に残る値'}`:`X=${x} はこの表示から外れる`;
      return el;
    }));
    const messages=[
      'まず13個の整数に限る。まだ盤面の境界条件を課していない。',
      '境界条件が伝わり、Xの範囲表示に残る値は9個。−3,−2,8,9は外れる。',
      'Xの範囲表示はまだ9個。点線の2,3は、残った制約全体には反する。範囲表示だけを解の集合と読まない。',
      'labelingが具体的な値を列挙すると、制約全体を満たす7個が答えになる。2,3では失敗する。'
    ];
    const queries=[
      '?- X in -3..9.\nX in -3..9.',
      '?- legal_pose([], pose(o,0,X,18), _),\n   fd_dom(X, Domain).\nDomain = -1..7.',
      `?- legal_pose([cell(4,19,j)],\n              pose(o,0,X,18), _),\n   fd_dom(X, Domain).\nDomain = ${D.constraints.domain}.\n% これ以外に、残った制約がある。`,
      `?- findall(X,\n     (legal_pose([cell(4,19,j)],\n                 pose(o,0,X,18), _),\n      labeling([], [X])), Xs).\nXs = [${D.constraints.answers.join(',')}].`
    ];
    setText('constraint-explanation',messages[stage]);setText('constraint-query',queries[stage]);
  }
  $('constraint-stage').addEventListener('change',drawConstraintStage);
  setText('residual-constraints',D.constraints.residual);drawConstraintBoard();drawConstraintStage();

  let roofOn=true,cavityFrame=0,cavityTimer=null;
  const cavityData=()=>roofOn?D.cavity.roof:D.cavity.open;
  function stopCavity(){if(cavityTimer!==null)clearInterval(cavityTimer);cavityTimer=null;$('cavity-play').textContent='通れる手順を再生';$('cavity-play').setAttribute('aria-pressed','false');}
  function drawCavity(){
    const c=cavityData(),last=c.reachable?c.frames.length:0,done=c.reachable&&cavityFrame===last;
    const board=done?c.after:c.board,active=done?null:c.frames[cavityFrame];
    const target=done?[]:c.target.cells;
    drawBoard('cavity-overview',board,{active,target,label:`${roofOn?'屋根あり':'屋根なし'}の盤面。目標への到達は${c.reachable?'可能':'不可能'}`});
    drawBoard('cavity-detail',board,{y0:15,y1:19,active,target,label:'空洞と屋根、下五行の拡大'});
    $('roof-toggle').textContent=roofOn?'屋根あり → 外して比べる':'屋根なし → 戻して比べる';
    $('roof-toggle').setAttribute('aria-pressed',String(roofOn));
    setText('cavity-verdict',`${c.reachable?'はい':'いいえ'}（${c.count}姿勢）`);
    setText('cavity-explanation',roofOn?'目標には置ける。でも上から入る道がない。白枠は静的な目標で、到達経路がある印ではない。':'屋根を外しても、目標の形と床は同じ。今度は下移動19回で入れる。');
    $('cavity-play').disabled=!c.reachable;$('cavity-step').disabled=!c.reachable||done;
    $('cavity-timeline').disabled=!c.reachable;$('cavity-timeline').max=last;$('cavity-timeline').value=cavityFrame;
    setText('cavity-frame',done?'固定・二行消去後':`${cavityFrame} / ${c.path.length}手`);
    setText('cavity-status',done?'Oを固定すると下二行が消え、空の盤面が残る。これもPrologの出力。':
      !c.reachable?'手順は見つからない。屋根を外すと、記録された手順を再生できる。':
      `${cavityFrame===0?'開始姿勢':poseText(active)}。重力や固定待ちを含まない操作列。`);
  }
  $('roof-toggle').addEventListener('click',()=>{stopCavity();roofOn=!roofOn;cavityFrame=0;drawCavity();});
  $('cavity-reset').addEventListener('click',()=>{stopCavity();cavityFrame=0;drawCavity();});
  $('cavity-step').addEventListener('click',()=>{stopCavity();cavityFrame=Math.min(cavityData().frames.length,cavityFrame+1);drawCavity();});
  $('cavity-timeline').addEventListener('input',e=>{stopCavity();cavityFrame=Number(e.target.value);drawCavity();});
  $('cavity-play').addEventListener('click',()=>{
    if(cavityTimer!==null){stopCavity();return;}
    const last=cavityData().frames.length;if(cavityFrame===last)cavityFrame=0;
    $('cavity-play').textContent='停止';$('cavity-play').setAttribute('aria-pressed','true');
    cavityTimer=setInterval(()=>{cavityFrame++;drawCavity();if(cavityFrame>=last)stopCavity();},220);
  });drawCavity();

  const layerLast=D.demo.layers[D.demo.layers.length-1].depth+1;
  $('layer-range').max=layerLast;
  function drawLayers(){
    const depth=Number($('layer-range').value),layers=[...D.demo.layers,{depth:layerLast,count:0}];
    const count=layers.filter(l=>l.depth<=depth).reduce((n,l)=>n+l.count,0),fresh=layers[depth].count;
    setText('layer-value',depth===layerLast?`${depth}手以内（増加なし）`:`${depth}手以内`);
    setText('layer-explanation',`この層で新しく ${fresh}姿勢。ここまでで ${count}姿勢。${depth===layerLast?'新しい姿勢が増えず、到達集合が閉じた。':''}`);
    const width=760,height=180,base=145,max=Math.max(...layers.map(l=>l.count)),bar=(width-44)/layers.length;
    const svg=svgElement('svg',{viewBox:`0 0 ${width} ${height}`,role:'img','aria-label':`各手数で新しく見つかった姿勢数。${depth}手以内で${count}姿勢。`});
    svg.append(svgElement('line',{x1:20,x2:width-15,y1:base,y2:base,stroke:'#9db6a7'}));
    layers.forEach((l,i)=>{
      const h=l.count/max*120,x=24+i*bar;
      const rect=svgElement('rect',{x,y:base-h,width:Math.max(2,bar-4),height:Math.max(2,h),rx:2,
        fill:i===depth?'#8264a4':i<depth?'#72a58b':'#dbe4da'});
      rect.append(svgElement('title',{},`${i}手：新しく${l.count}姿勢`));svg.append(rect);
      if(i%5===0||i===layerLast)svg.append(svgElement('text',{x:x+bar/2-2,y:169,'font-size':17,'text-anchor':'middle',fill:'#435c52','font-family':'Consolas,monospace'},i));
    });$('layer-chart').replaceChildren(svg);$('layer-next').disabled=depth===layerLast;
  }
  $('layer-range').addEventListener('input',drawLayers);
  $('layer-next').addEventListener('click',()=>{$('layer-range').value=Math.min(layerLast,Number($('layer-range').value)+1);drawLayers();});
  $('layer-all').addEventListener('click',()=>{$('layer-range').value=layerLast;drawLayers();});
  $('layer-reset').addEventListener('click',()=>{$('layer-range').value=0;drawLayers();});drawLayers();

  let rep=0,rotated=false;
  function drawRepresentations(){
    for(let i=0;i<2;i++){
      const p=D.representations[i][rotated?'after':'before'];
      const id=i===0?'a':'b';
      drawBoard(`representation-board-${id}`,[],{x0:3,x1:8,y0:9,y1:15,active:p,origin:p,
        label:`表現${id.toUpperCase()}。${rotated?'右回転後':'回転前'}。${poseText(p)}`});
      setText(`representation-pose-${id}`,poseText(p));
      $(`representation-${id}`).setAttribute('aria-pressed',String(i===rep));
      $(`representation-board-${id}`).parentElement.classList.toggle('focused',i===rep);
    }
    $('rotate-toggle').setAttribute('aria-pressed',String(rotated));
    $('rotate-toggle').textContent=rotated?'回転前の表示に戻す':'両方を右回転させる';
    setText('representation-explanation',rotated?
      `右回転後は、AがX=6の列、BがX=5の列へ。違う四マスになる。いま注目しているのは${rep===0?'A':'B'}。`:
      `いま占めている四マスは同じ。AとBで原点と回転番号が違う。${rep===0?'Aの原点(4,11)':'Bの原点(4,10)'}に注目して、両方を回転させてみよう。`);
  }
  $('representation-a').addEventListener('click',()=>{rep=0;drawRepresentations();});
  $('representation-b').addEventListener('click',()=>{rep=1;drawRepresentations();});
  $('rotate-toggle').addEventListener('click',()=>{rotated=!rotated;drawRepresentations();});drawRepresentations();

  let projectionAfter=false;
  function drawProjection(){
    for(const id of ['a','b']){
      const p=D.projection[id];drawBoard(`projection-${id}`,p[projectionAfter?'after':'before'],{y0:16,y1:19,label:`盤面${id.toUpperCase()}の${projectionAfter?'行消去後':'行消去前'}`});
      setText(`projection-lines-${id}`,projectionAfter?`${p.lines}行`:'まだ消していない');
    }
    $('projection-toggle').setAttribute('aria-pressed',String(projectionAfter));
    $('projection-toggle').textContent=projectionAfter?'消す前の表示へ戻す':'両方の完成行を消す';
    setText('projection-explanation',projectionAfter?'盤面だけを見ると、どちらも空。でも消えた行数は1行と2行で違う。':'入力の盤面は違う。行を消した後に、どの区別が残るだろう。');
  }
  $('projection-toggle').addEventListener('click',()=>{projectionAfter=!projectionAfter;drawProjection();});drawProjection();

  const generated=new Date(D.generated_at).toLocaleString('ja-JP',{timeZone:'Asia/Tokyo',hour12:false});
  setText('provenance-summary',`データ生成：${generated}（日本時間） / SWI-Prolog ${D.swi_version}。この版はゲームの中核ソースのSHA-256と、参照したGitコミットを以下に記録している。`);
  setText('source-fingerprints',`参照コミット: ${D.source_commit}\n\n`+D.sources.map(s=>`${s.path}\nSHA-256 ${s.sha256}`).join('\n\n'));

  const observer=new IntersectionObserver(entries=>entries.forEach(e=>{
    if(!e.isIntersecting){if(e.target.id==='q-lab')stopQ();else stopCavity();}
  }),{threshold:0});
  observer.observe($('q-lab'));observer.observe(document.querySelector('.cavity-lab'));
  document.addEventListener('visibilitychange',()=>{if(document.hidden){stopQ();stopCavity();}});
  let closedDetails=[];
  window.addEventListener('beforeprint',()=>{stopQ();stopCavity();closedDetails=[...document.querySelectorAll('details:not([open])')];closedDetails.forEach(el=>el.open=true);});
  window.addEventListener('afterprint',()=>closedDetails.forEach(el=>el.open=false));
  // Read-only hooks for offline QA, not a game API or solver.
  Object.defineProperty(window,'guideEvidence',{value:Object.freeze({
    version:D.swi_version,landings:D.demo.candidates.length,
    get qFrame(){return qFrame;},get qIndex(){return qIndex;},
    get playing(){return qTimer!==null;},get roofOn(){return roofOn;}
  })});
})();
