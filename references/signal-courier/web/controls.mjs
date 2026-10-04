// Host owns time sampling and input edges, never game physics.
export function controls(send) {
  const held = new Map();
  let jumps = 0, accumulator = 0;
  return {
    press(key, source = key) { if (!held.has(source) && key === 'jump') jumps = Math.min(8,jumps+1); held.set(source,key); },
    release(source) { held.delete(source); },
    clear() { held.clear(); jumps=0; accumulator=0; },
    frame(milliseconds) {
      // Explicit slow-frame policy: drop elapsed time above 100 ms, at most six ticks.
      accumulator += Math.max(0,Math.min(100,milliseconds));
      while (accumulator >= 1000/60) {
        accumulator -= 1000/60;
        const actions = new Set(held.values());
        const direction = actions.has('left') === actions.has('right') ? 0 : actions.has('left') ? 1 : 2;
        send(direction + (jumps>0 ? 3 : 0));
        if (jumps>0) jumps--;
      }
    }
  };
}
