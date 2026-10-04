import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { loadGame } from './engine.mjs';
import { tuningLoader } from './tuning.mjs';
const create = await loadGame(await readFile(new URL('./game.wasm', import.meta.url)));
const a = create();
const initial = a.svg();
a.rotate(0); const moved = a.svg();
assert.equal(create.stage('revision 2 moveBudget 7 inletRotation 3'), true);
assert.equal(a.svg(), moved);
a.restart(); assert.equal(a.svg(), initial);
const b = create(); assert.equal(b.moves(), 7);
assert.notEqual(b.svg(), initial);
b.rotate(4); assert.equal(b.undo(), true); assert.equal(b.moves(), 7);
b.rotate(4); assert.equal(b.undo(), false); b.restart();
for (const cell of [0,0,0,2,2,11,11]) b.rotate(cell);
assert.equal(b.phase(), 'won'); assert.equal(b.moves(), 0);
b.restart(); assert.equal(b.moves(), 7);
for (const text of ['', 'revision 1 moveBudget 18 inletRotation 1', 'revision 2 moveBudget 18 inletRotation 1', 'revision 3 moveBudget 2 inletRotation 3', 'revision 3 moveBudget 18446744073709551634 inletRotation 1', 'revision 3 moveBudget 18 inletRotation 4294967297', 'revision 1000000001 moveBudget 18 inletRotation 1', 'revision 3 moveBudget 18.5 inletRotation 1', 'revision 3 moveBudget 18 inletRotation 1\0', 'x'.repeat(129), '🪴'.repeat(40)]) {
  assert.equal(create.stage(text), false, text);
  const c = create(); assert.equal(c.moves(), 7); c.close();
  assert.equal(b.moves(), 7);
}
// Requests finish out of order: stale success cannot replace newer data.
const pending = [];
const loader = tuningLoader(create, () => new Promise((resolve, reject) => pending.push({resolve, reject})));
const first = loader.reload(), second = loader.reload();
pending[1].resolve('revision 4 moveBudget 9 inletRotation 2');
assert.equal(await second, 'staged');
pending[0].resolve('revision 5 moveBudget 20 inletRotation 1');
assert.equal(await first, 'superseded');
let c = create(); assert.equal(c.moves(), 9); c.close();
// Even an invalid latest response supersedes a slower valid response.
const third = loader.reload(), fourth = loader.reload();
pending[3].resolve('invalid'); assert.equal(await fourth, 'rejected');
pending[2].resolve('revision 6 moveBudget 20 inletRotation 1'); assert.equal(await third, 'superseded');
c = create(); assert.equal(c.moves(), 9); c.close();
const failed = loader.reload(); pending[4].reject(new Error('download failed'));
await assert.rejects(failed, /download failed/);
c = create(); assert.equal(c.moves(), 9); c.close();
const fifth = loader.reload(); loader.close(); create.close(); create.close();
pending[5].resolve('revision 7 moveBudget 18 inletRotation 1'); assert.equal(await fifth, 'superseded');
assert.throws(() => create(), /closed/); assert.throws(() => create.stage(''), /closed/);
// Existing sessions own values, not catalog pointers.
b.restart(); assert.equal(b.moves(), 7); a.restart(); assert.equal(a.moves(), 18);
a.close(); b.close();
console.log('PASS: real Wasm level staging, overflow rejection, pinned sessions/reset/undo, stale async responses and lifecycle; no browser UI claim');
