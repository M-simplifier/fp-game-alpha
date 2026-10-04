import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { createInterface } from 'node:readline';
import { loadGame } from '../../web/engine.mjs';
// Keep protocol output separate from the WASI shim's startup log.
console.log = (...args) => console.error(...args);
const create = await loadGame(await readFile(new URL('../../web/game.wasm', import.meta.url)));
function observe() {
  const session = create();
  session.rotate(4);
  const result = { moves: session.moves(), svg: createHash('sha256').update(session.svg()).digest('hex') };
  session.close(); return result;
}
if (process.argv[2] === 'data') {
  process.stdout.write('ready\n');
  for await (const line of createInterface({input: process.stdin})) {
    if (!create.stage(await readFile(line, 'utf8'))) throw new Error('staging rejected');
    process.stdout.write(JSON.stringify(observe()) + '\n');
  }
} else process.stdout.write(JSON.stringify(observe()) + '\n');
create.close();
