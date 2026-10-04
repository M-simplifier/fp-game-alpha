import { spawnSync } from 'node:child_process';

// Deterministic actual-Lua tests; separate from real Neovim/OS integration.
const candidates = process.env.LUA_EXECUTABLE ? [process.env.LUA_EXECUTABLE] : ['lua', 'texlua', 'luajit'];
for (const executable of candidates) {
  const result = spawnSync(executable, ['tests/manual-watch-failure.lua'], { stdio: 'inherit', timeout: 30000 });
  if (result.error?.code === 'ENOENT') continue;
  if (result.error) console.error(result.error);
  process.exit(result.status === 0 ? 0 : 1);
}
console.error('Lua runtime missing. Install Lua or set LUA_EXECUTABLE; the fault-injection tests have not run.');
process.exit(1);
