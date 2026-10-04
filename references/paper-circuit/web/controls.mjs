// Presentation/input routing only; eligibility and consequences stay in Haskell.
export function applyControl(target, game) {
  const tile = target.closest('[data-cell]');
  if (tile) {
    const index=Number(tile.dataset.cell);
    if (!Number.isInteger(index) || index<0 || index>=16) return null;
    game.rotate(index);
    return `[data-cell="${index}"]`;
  }
  for(const command of ['reset','undo']) {
    if (target.closest(`[data-command=${command}]`)) {
      if(command==='reset') game.restart(); else game.undo();
      return `[data-command=${command}]`;
    }
  }
  return null;
}
