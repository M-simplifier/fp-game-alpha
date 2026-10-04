// Async transport ordering only. Record parsing and admission live in Haskell.
export function tuningLoader(create, fetchText) {
  let request = 0;
  let open = true;
  return {
    async reload() {
      const mine = ++request;
      try {
        const text = await fetchText();
        if (!open || mine !== request) return 'superseded';
        return create.stage(text) ? 'staged' : 'rejected';
      } catch (error) {
        if (!open || mine !== request) return 'superseded';
        throw error;
      }
    },
    close() { open = false; ++request; }
  };
}
