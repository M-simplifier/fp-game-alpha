import assert from 'node:assert/strict';
import { controls } from './controls.mjs';

function check(name, exercise) {
  const sent = [];
  const input = controls(code => sent.push(code));
  try {
    exercise(input, sent);
  } catch (error) {
    error.message = `${name}: ${error.message}`;
    throw error;
  }
}

check('jump edges survive a sub-tick frame and do not repeat while held', (input, sent) => {
  input.press('right');
  input.press('jump');
  input.frame(1);
  assert.deepEqual(sent, []);
  input.frame(40);
  assert.deepEqual(sent, [5, 2]);
  input.press('jump');
  input.frame(17);
  assert.equal(sent.at(-1), 2);
  input.release('jump');
  input.press('jump');
  input.frame(17);
  assert.equal(sent.at(-1), 5);
});

check('opposing actions cancel independent of source identity', (input, sent) => {
  input.press('left', 'ArrowLeft');
  input.press('right', 'KeyD');
  input.frame(17);
  assert.deepEqual(sent, [0]);
  input.release('ArrowLeft');
  input.frame(17);
  assert.equal(sent.at(-1), 2);
});

check('a slow frame drops elapsed time above the host cap', (input, sent) => {
  input.frame(10000);
  assert.ok(sent.length > 0 && sent.length <= 6);
  const capped = [];
  controls(code => capped.push(code)).frame(100);
  assert.deepEqual(sent, capped);
});

check('key aliases and touch pointers retain independent ownership', (input, sent) => {
  input.press('right', 'ArrowRight');
  input.press('right', 'KeyD');
  input.release('ArrowRight');
  input.frame(17);
  assert.equal(sent.at(-1), 2);
  input.press('right', 'pointer:1');
  input.release('KeyD');
  input.frame(17);
  assert.equal(sent.at(-1), 2);
  input.press('right', 'pointer:2');
  input.release('pointer:1');
  input.frame(17);
  assert.equal(sent.at(-1), 2);
  input.release('pointer:2');
  input.frame(17);
  assert.equal(sent.at(-1), 0);
});

check('clear removes held state, jump edges and fractional time debt', (input, sent) => {
  input.press('right');
  input.press('jump');
  input.frame(10);
  input.clear();
  input.frame(10);
  assert.deepEqual(sent, []);
  input.frame(7);
  assert.deepEqual(sent, [0]);
});

check('queued jump edges are bounded and consumed once each', (input, sent) => {
  for (let edge = 0; edge < 12; edge++) {
    input.press('jump', `pointer:${edge}`);
    input.release(`pointer:${edge}`);
  }
  for (let frame = 0; frame < 10; frame++) input.frame(17);
  assert.deepEqual(sent, [...Array(8).fill(3), 0, 0]);
});
console.log('PASS host input: edge retention, cap, opposing actions, alias/key-touch/multi-pointer ownership and clear');
