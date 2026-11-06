"""File/data integrity checks. No browser, game window or second solver."""
from pathlib import Path
from html.parser import HTMLParser
from collections import Counter
from datetime import datetime, timezone, timedelta
import base64
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent.parent
FILE = ROOT/'docs/prolog-tetris-explained.html'
html = FILE.read_text(encoding='utf-8')
checks = []

def require(condition, label):
    if not condition:
        raise AssertionError(label)
    checks.append(label)

class Reader(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids=[]; self.anchors=[]; self.resources=[]; self.data=[]; self.in_data=False
    def handle_starttag(self, tag, attrs):
        attr=dict(attrs)
        if 'id' in attr: self.ids.append(attr['id'])
        if tag=='a': self.anchors.append(attr.get('href',''))
        if tag in ('script','img','iframe','link','audio','video','source'):
            src=attr.get('src',attr.get('href',''))
            if src: self.resources.append(src)
        if tag=='script' and attr.get('id')=='guide-data': self.in_data=True
    def handle_endtag(self, tag):
        if tag=='script': self.in_data=False
    def handle_data(self, value):
        if self.in_data: self.data.append(value)

reader=Reader();reader.feed(html)
require(len(reader.ids)==len(set(reader.ids)), 'unique HTML ids')
require(all(a[1:] in reader.ids for a in reader.anchors if a.startswith('#')), 'all section anchors exist')
require(all(r.startswith('data:') for r in reader.resources), 'all loaded resources are embedded data')
for resource in reader.resources:
    if resource.startswith('data:image/png;base64,'):
        require(base64.b64decode(resource.split(',',1)[1],validate=True).startswith(b'\x89PNG\r\n\x1a\n'), 'embedded native PNG is valid base64/PNG')
require('__GUIDE_DATA__' not in html and '/*__SCRIPT__*/' not in html, 'no build placeholders remain')
require('@import' not in html and 'url(' not in (ROOT/'docs/guide/guide.css').read_text(), 'no external CSS or fonts')
js=(ROOT/'docs/guide/guide.js').read_text(encoding='utf-8')
require(not re.search(r'\b(fetch|XMLHttpRequest|WebSocket|eval)\s*\(',js), 'viewer has no network/eval entry point')
for literal_id in re.findall(r"\$\('([\w-]+)'\)",js):
    require(literal_id in reader.ids, f'viewer target exists: {literal_id}')
D=json.loads(''.join(reader.data))
generated=datetime.fromisoformat(D['generated_at'].replace('Z','+00:00'))
require(generated<=datetime.now(timezone.utc)+timedelta(minutes=5), 'recorded UTC timestamp is not in the future')
require(D['swi_version']=='10.0.2', 'actual expected SWI version recorded')
for source in D['sources']:
    require(hashlib.sha256((ROOT/source['path']).read_bytes()).hexdigest()==source['sha256'], 'source hash matches: '+source['path'])
for key,excerpt in D['excerpts'].items():
    lines=(ROOT/excerpt['file']).read_text(encoding='utf-8').splitlines()
    n=len(excerpt['text'].splitlines())
    require('\n'.join(lines[excerpt['line']-1:excerpt['line']-1+n])==excerpt['text'], 'live source excerpt matches: '+key)
require(len(D['demo']['candidates'])==34 and D['demo']['info']['poses']==614, 'recorded demo counts')
for i,c in enumerate(D['demo']['candidates']):
    require(len(c['frames'])==len(c['path'])+1 and c['frames'][0]==D['demo']['start'] and c['frames'][-1]==c['pose'], f'complete recorded frames for witness {i+1}')
    require(sorted(c['cells'])==sorted(c['pose']['cells']), f'landing footprint consistent {i+1}')
depths=Counter(n['depth'] for n in D['demo']['nodes'])
require(depths==Counter({n['depth']:n['count'] for n in D['demo']['layers']}), 'BFS layers agree with actual recorded nodes')
require(sum(depths.values())==614, 'all recorded discovery layers total 614')
require([len(e['solutions']) for e in D['inverse']]==[1,2,4,0], 'inverse examples have actual expected alternative counts')
require([len(s) for s in D['constraints']['stages']]==[13,9,9] and len(D['constraints']['answers'])==7, 'domain summary and solution count remain distinct')
require([4,19] in D['constraints']['rejected_pose']['cells'], 'X=2 collision footprint is recorded')
require(D['cavity']['roof']['reachable'] is False and D['cavity']['open']['reachable'] is True, 'cavity actual reachability differs')
require(D['cavity']['roof']['count']==628 and D['cavity']['open']['count']==656, 'cavity recorded closure sizes')
require(len(D['cavity']['open']['path'])==19, 'roofless actual witness length')
A,B=D['representations']
require(sorted(A['before']['cells'])==sorted(B['before']['cells']), 'I representations have identical initial pixels')
require(A['after']['cells']==[[6,11],[6,12],[6,13],[6,14]] and B['after']['cells']==[[5,10],[5,11],[5,12],[5,13]], 'I recorded cw successors differ as expected')
require(D['projection']['a']['after']==D['projection']['b']['after']==[] and D['projection']['a']['lines']==1 and D['projection']['b']['lines']==2, 'board projection loses information while row counts differ')
report={'file':str(FILE.relative_to(ROOT)),'bytes':FILE.stat().st_size,'checks':checks,'source_commit':D['source_commit'],'generated_at':D['generated_at']}
(ROOT/'.scratch/html-guide/file-check.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(f'PASS {len(checks)} file/data checks. No browser or native game opened.')
