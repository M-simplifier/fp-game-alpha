#!/usr/bin/env python3
"""Local edit-to-observation experiment. Activate GHC-Wasm first; no installs.
Both paths change budget 18 -> 19/20 with inletRotation 1, rotate tile 4,
and force the same Haskell SVG. Not a browser frame or cold-build benchmark.
"""
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

root = Path(__file__).resolve().parents[2]
os.chdir(root)
source = Path('src/Paper/Game.hs')
original = source.read_text()
assert 'defaultLevel = Level 18 1' in original
probe = 'test/iteration/probe.mjs'
data = Path('.build/benchmark-level.txt').resolve()
subprocess.run(['bash', 'build-web.sh'], check=True, stdout=subprocess.DEVNULL)
process = subprocess.Popen(['node', probe, 'data'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert process.stdout.readline().strip() == 'ready'
results = []
try:
    for i in range(5):
        budget = 19 + i % 2
        begun = time.perf_counter()
        data.write_text(f'revision {i+1} moveBudget {budget} inletRotation 1\n')
        process.stdin.write(str(data) + '\n'); process.stdin.flush()
        observed_data = json.loads(process.stdout.readline())
        data_ms = (time.perf_counter() - begun) * 1000
        begun = time.perf_counter()
        source.write_text(original.replace('defaultLevel = Level 18 1', f'defaultLevel = Level {budget} 1'))
        subprocess.run(['bash', 'build-web.sh'], check=True, stdout=subprocess.DEVNULL)
        observed_code = json.loads(subprocess.check_output(['node', probe], text=True))
        code_ms = (time.perf_counter() - begun) * 1000
        assert observed_code == observed_data and observed_code['moves'] == budget - 1
        results.append(dict(budget=budget, data_ms=data_ms, code_ms=code_ms, observation=observed_code))
finally:
    process.stdin.close(); process.wait()
    source.write_text(original)
    subprocess.run(['bash', 'build-web.sh'], check=True, stdout=subprocess.DEVNULL)
report = dict(scope='Warm initialized data runtime versus incremental source rebuild plus fresh Node/Wasm initialization; local file write through first rotated Haskell SVG hash, not a browser frame or file-watch latency', trials=results, median_data_ms=statistics.median(x['data_ms'] for x in results), median_code_ms=statistics.median(x['code_ms'] for x in results))
Path('test/iteration/measurements.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
