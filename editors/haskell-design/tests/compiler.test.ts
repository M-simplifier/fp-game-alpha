import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { verifyBatch } from '../src/compiler';

// Exercise helper publication with real GHC/processes. These small helpers
// return protocol fixtures; semantic inference has its own real-source tests.
const tool = path.resolve(__dirname, '../..');
async function fixture() {
  await fs.mkdir(path.join(tool, '.test-output'), { recursive: true });
  const root = await fs.mkdtemp(path.join(tool, '.test-output/compiler-'));
  const file = path.join(root, 'Api.hs'), helper = path.join(root, 'Main.hs');
  const source = 'module Api where\nvalue :: Int\nvalue = 1\n';
  await fs.writeFile(file, source);
  const sources = new Map([[file, source]]);
  const options = { root, ghcPath: process.env.HASKELL_DESIGN_TEST_GHC ?? 'ghc', cacheDir: path.join(root, 'cache') };
  return { helper, check: async () => (await verifyBatch([file], sources, helper, options)).get(file)! };
}
const helperSource = (status: 'pure' | 'io') =>
  'module Main where\nmain :: IO ()\nmain = putStrLn ' + JSON.stringify(JSON.stringify([{ status, signatures: [], evidence: [], dependencies: [] }])) + '\n';

test('a failed helper build can recover in the same editor process', async () => {
  const { helper, check } = await fixture();
  await fs.writeFile(helper, 'module Main where\nmain = missingBinding\n');
  await assert.rejects(check(), /missingBinding/);
  await fs.writeFile(helper, helperSource('pure'));
  const repaired = await check();
  assert.equal(repaired.error, undefined);
  assert.equal(repaired.status, 'pure');
});

test('changed helper source is reselected before the next batch', async () => {
  const { helper, check } = await fixture();
  await fs.writeFile(helper, helperSource('pure'));
  assert.equal((await check()).status, 'pure');
  await fs.writeFile(helper, helperSource('io'));
  const updated = await check();
  assert.equal(updated.error, undefined);
  assert.equal(updated.status, 'io');
});
