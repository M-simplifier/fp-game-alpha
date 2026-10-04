import { WASI, File, OpenFile, ConsoleStdout } from './vendor-shim/dist/index.js';

// This module transports input and displays Haskell SVG. It contains no rules.
export async function loadGame(bytes) {
  const wasi = new WASI(['paper-circuit'], [], [new OpenFile(new File([])),
    ConsoleStdout.lineBuffered(console.log), ConsoleStdout.lineBuffered(console.error)]);
  const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi.wasiImport });
  wasi.initialize(instance);
  const api = instance.exports;
  api.hs_init(0, 0);
  const catalog = api.newCatalog();
  let open = true;
  const checkCatalog = () => { if (!open) throw new Error("Catalog already closed"); };
  const create = () => {
    checkCatalog();
    const handle = api.newSessionFrom(catalog);
    let live = true;
    function checked() { if (!live) throw new Error('Session already closed'); }
    return {
      rotate(index) { checked(); if (!Number.isInteger(index) || index < 0 || index >= 16) return false; return api.action(handle,index) === 1; },
      undo() { checked(); return api.action(handle,-2) === 1; },
      restart() { checked(); return api.action(handle,-1) === 1; },
      moves() { checked(); return api.readMoves(handle); },
      phase() { checked(); return ['playing','won','out-of-moves'][api.readPhase(handle)]; },
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
  create.stage = text => {
    checkCatalog();
    if (typeof text !== 'string') return false;
    const bytes = new TextEncoder().encode(text);
    if (bytes.length > 128) return false; // Transport bound; Haskell validates content.
    const pointer = api.allocateText(bytes.length);
    try {
      new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
      return api.stageCatalog(catalog, pointer, bytes.length) === 1;
    } finally { api.freeText(pointer); }
  };
  create.close = () => { if (open) { open = false; api.freeCatalog(catalog); } };
  return create;
}
