import { WASI, File, OpenFile, ConsoleStdout } from './vendor-shim/dist/index.js';

// This module transports input and displays Haskell SVG. It contains no rules.
export async function loadGame(bytes) {
  const wasi = new WASI(['signal-courier'], [], [new OpenFile(new File([])),
    ConsoleStdout.lineBuffered(console.log), ConsoleStdout.lineBuffered(console.error)]);
  const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi.wasiImport });
  wasi.initialize(instance);
  const api = instance.exports;
  api.hs_init(0, 0);
  const create = () => {
    const handle = api.newSession();
    let live = true;
    function checked() { if (!live) throw new Error('Session already closed'); }
    return {
      input(code) { checked(); if (!Number.isInteger(code) || code < 0 || code > 7) return false; return api.action(handle,code) === 1; },
      restart() { checked(); return api.action(handle,7) === 1; },
      ticks() { checked(); return api.readTicks(handle); },
      phase() { checked(); return ['delivering','complete','exhausted'][api.readPhase(handle)]; },
      svg() {
        checked();
        const pointer = api.renderSession(handle);
        try {
          const memory = new Uint8Array(api.memory.buffer);
          const end = memory.indexOf(0,pointer);
          if (end < pointer || end-pointer > 65536) throw new Error('Invalid SVG response');
          return new TextDecoder().decode(memory.subarray(pointer,end));
        } finally { api.freeText(pointer); }
      },
      close() { if (live) { live = false; api.freeSession(handle); } }
    };
  };
  return create;
}
