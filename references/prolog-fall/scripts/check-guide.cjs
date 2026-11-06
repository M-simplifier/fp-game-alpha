/* Offline browser consumer checks. No Windows input injection, no game launch. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const playwright = require(process.env.PROLOG_GUIDE_PLAYWRIGHT ||
  'playwright');
const root = path.resolve(__dirname,'..');
const evidence = path.join(root,'.scratch/html-guide');
fs.mkdirSync(evidence,{recursive:true});

async function main(){
  const browser=await playwright.chromium.launch({
    ...(process.env.PROLOG_GUIDE_BROWSER ? {executablePath:process.env.PROLOG_GUIDE_BROWSER} : {channel:'chrome'}),
    headless:true
  });
  const report={file:process.env.PROLOG_GUIDE_FILE||'docs/prolog-tetris-explained.html',checks:[],requests:[],errors:[]};
  const context=await browser.newContext({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  await context.setOffline(true);
  const page=await context.newPage();
  page.on('pageerror',e=>report.errors.push(String(e)));
  page.on('console',m=>{if(m.type()==='error')report.errors.push(m.text());});
  page.on('request',r=>{if(!r.url().startsWith('file:')&&!r.url().startsWith('data:'))report.requests.push(r.url());});
  try{
    await page.goto(pathToFileURL(path.join(root,report.file)).href,{waitUntil:'load'});
    await page.waitForFunction(()=>window.guideEvidence?.landings===34);
    const check=(label,condition)=>{assert(condition,label);report.checks.push(label);};
    check('file:// loads with offline context',await page.title()==='Prologでテトリスを作ると、何が見えるか');
    check('all 34 candidate answers offered',await page.locator('#candidate-select option').count()===34);
    await page.screenshot({path:path.join(evidence,'desktop-top.png')});
    await page.locator('#q-lab').screenshot({path:path.join(evidence,'desktop-q.png')});
    await page.locator('#candidate-next').click();
    check('candidate next changes answer',await page.locator('#candidate-select').inputValue()==='1');
    await page.locator('#candidate-prev').click();
    await page.locator('#q-step').click();
    check('one-step playback advances recorded pose',await page.evaluate(()=>window.guideEvidence.qFrame)===1);
    await page.locator('#q-reset').click();
    check('reset returns to recorded start',await page.evaluate(()=>window.guideEvidence.qFrame)===0);
    await page.locator('#motion-example').click();
    check('rotation/sideways witness selected',await page.evaluate(()=>window.guideEvidence.qIndex)===7);
    check('motion path includes recorded rotation',await page.locator('#q-actions button.turn').count()>0);
    await page.locator('#q-play').click();await page.waitForTimeout(520);
    check('explicit play advances',await page.evaluate(()=>window.guideEvidence.qFrame)>0);
    await page.locator('#target-select').scrollIntoViewIfNeeded();await page.waitForTimeout(150);
    check('replay stops when its section leaves the viewport',await page.evaluate(()=>!window.guideEvidence.playing));
    await page.locator('#clear-filter').check();
    check('line-clear filter uses exported result',await page.locator('#candidate-select option').count()===1);
    await page.locator('#q-result').click();
    check('recorded lock/clear result is shown',(await page.locator('#q-status').innerText()).includes('1行が消えた'));
    await page.locator('#target-select').selectOption('i');
    check('I inverse first recorded solution',(await page.locator('#target-answer').innerText()).includes('pose(i,0,4,11)'));
    await page.locator('#answer-next').click();
    check('next alternative keeps second I representation',(await page.locator('#target-answer').innerText()).includes('pose(i,2,4,10)'));
    await page.locator('#answer-next').click();
    check('exhausted alternatives show false',(await page.locator('#target-answer').innerText()).includes('false'));
    await page.locator('#answer-reset').click();
    await page.locator('#target-select').selectOption('o');
    for(let i=0;i<3;i++)await page.locator('#answer-next').click();
    check('O preserves four rotation alternatives',(await page.locator('#target-answer').innerText()).includes('pose(o,3,2,7)'));
    await page.locator('#target-select').selectOption('impossible');
    check('disconnected target has no solution',(await page.locator('#target-answer').innerText()).includes('false'));
    await page.locator('#target-select').selectOption('t');
    await page.locator('.inverse-lab').screenshot({path:path.join(evidence,'desktop-inverse.png')});
    await page.locator('#constraint-stage').selectOption('2');
    check('domain summary retains nine values',await page.locator('#domain-values span:not(.removed)').count()===9);
    check('domain summary exposes collision caveat',await page.locator('#domain-values .collision-hint').count()===2);
    await page.locator('#collision-example').click();
    check('X=2 direct validation fails',(await page.locator('#known-query').innerText()).includes('false.'));
    await page.locator('.constraint-lab').screenshot({path:path.join(evidence,'desktop-constraints.png')});
    await page.locator('#constraint-stage').selectOption('3');
    check('labeling has seven satisfying answers',await page.locator('#domain-values span:not(.removed)').count()===7);
    check('roofed target has no reachable witness',(await page.locator('#cavity-verdict').innerText()).includes('いいえ'));
    await page.locator('#roof-toggle').click();
    check('roofless target has reachable witness',(await page.locator('#cavity-verdict').innerText()).includes('はい'));
    await page.locator('#cavity-step').click();
    check('roofless replay steps actual path',(await page.locator('#cavity-frame').innerText()).startsWith('1 /'));
    await page.locator('#cavity-timeline').focus();await page.locator('#cavity-timeline').press('End');
    check('roofless final projection clears two rows',(await page.locator('#cavity-status').innerText()).includes('下二行'));
    await page.locator('#roof-toggle').click();
    await page.locator('.cavity-lab').screenshot({path:path.join(evidence,'desktop-cavity.png')});
    await page.locator('#layer-all').click();
    check('closure reaches 614 with no new states',(await page.locator('#layer-explanation').innerText()).includes('新しく 0姿勢。ここまでで 614姿勢'));
    await page.locator('.layers-lab').screenshot({path:path.join(evidence,'desktop-layers.png')});
    await page.locator('#rotate-toggle').click();
    await page.locator('#representation-b').click();
    check('representation B selected',await page.locator('#representation-b').getAttribute('aria-pressed')==='true');
    check('I rotation successors remain distinct',(await page.locator('#representation-pose-a').innerText())==='pose(i,1,4,11)'&&
      (await page.locator('#representation-pose-b').innerText())==='pose(i,3,4,10)');
    await page.locator('.representation-lab').screenshot({path:path.join(evidence,'desktop-representations.png')});
    await page.locator('#projection-toggle').click();
    check('non-injective projection keeps different line counts',(await page.locator('#projection-lines-a').innerText())==='1行'&&
      (await page.locator('#projection-lines-b').innerText())==='2行');
    await page.locator('.projection-lab').screenshot({path:path.join(evidence,'desktop-projection.png')});
    const detail=page.locator('details').first();await detail.locator('summary').click();
    check('native disclosure opens by keyboard/click',await detail.getAttribute('open')!==null);
    await detail.locator('summary').press('Enter');
    check('disclosure closes with Enter',await detail.getAttribute('open')===null);
    for(const width of [1440,360]){
      await page.setViewportSize({width,height:1000});
      const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1);
      check(`no horizontal page overflow at ${width}px`,!overflow);
      if(width===360){
        await page.goto(pathToFileURL(path.join(root,report.file)).href,{waitUntil:'load'});
        await page.screenshot({path:path.join(evidence,'mobile-top.png')});
        await page.locator('#q-lab').screenshot({path:path.join(evidence,'mobile-q.png')});
        await page.locator('#candidate-select').scrollIntoViewIfNeeded();
        await page.screenshot({path:path.join(evidence,'mobile-controls.png')});
        await page.locator('#candidate-next').click();
        check('mobile candidate control works',await page.locator('#candidate-select').inputValue()==='1');
        await page.locator('#constraint-stage').selectOption('2');
        await page.locator('#collision-example').click();
        await page.locator('.constraint-lab').screenshot({path:path.join(evidence,'mobile-constraints.png')});
        await page.locator('#rotate-toggle').click();
        await page.locator('.representation-lab').screenshot({path:path.join(evidence,'mobile-representations.png')});
      }
    }
    await page.emulateMedia({reducedMotion:'reduce'});
    check('reduced motion supported',await page.evaluate(()=>matchMedia('(prefers-reduced-motion: reduce)').matches));
    await page.emulateMedia({media:'print'});
    check('print hides playback controls',await page.locator('#q-play').evaluate(e=>getComputedStyle(e).display)==='none');
    check('zero unexpected external requests',report.requests.length===0);
    check('zero browser errors',report.errors.length===0);
    fs.writeFileSync(path.join(evidence,'browser-check.json'),JSON.stringify(report,null,2));
    console.log(`PASS ${report.checks.length} offline browser checks. Screenshots: ${evidence}`);
  }finally{await browser.close();}
}
main().catch(e=>{console.error(e);process.exit(1);});
