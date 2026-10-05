# Live engine/host contract v1

The Haskell game owns all simulation, objective evidence and policy execution. Hosts
serialize calls and never mutate `World`. Decimal strings carry every identity,
quantity, tick, revision and sequence. GET/observe does not advance time.

- `RedDune.Game.startGame scenario pack :: Either String GameState`
- `observeGame :: GameState -> Colony.JSON.JSON`: `{view,campaign,policies,pack,revision}`
- `gameWorld :: GameState -> World`, `gameRevision :: GameState -> Word64`
- `applyAction :: JSON -> GameState -> Either String (GameState, JSON)`
- `advanceGame :: Int -> GameState -> Either String GameState`: 0..1200 ordinary ticks
- `previewGame :: JSON -> GameState -> Either String JSON`: validates a command and
  returns its complete existing identity/boundary envelope
- `reidentifyGame :: String -> GameState -> Either String GameState`: fresh UUIDv4
  authority, new branch, paused; preserves evidence and archived receipt identities
- `RedDune.ContentPack.defaultPack`, `decodePack :: String -> Either String ContentPack`,
  `packIdentity :: ContentPack -> String`
- `RedDune.GameSave.encodeGame/decodeGame`: validated SHA256-framed canonical CBOR;
  `previewLegacy :: ByteString -> Either String JSON` never activates or grants progress
- `Colony.Presentation.encodeJSON` renders the strict shared JSON type

Action objects:

- `{op:"pause"}` / `{op:"resume"}`
- `{op:"configure",preset:"survival"}` establishes visible, persisted production,
  replenishment, maintenance and roster policies; `preset:"off"` stops automation
- `{op:"preview",command:{kind:...}}` uses the existing Colony command vocabulary
- `{op:"command",world,controller,epoch:{authority,generation},sequence,boundary,command}`
  retains authoritative command IDs, stale boundary checks and exact retry receipts
- `{op:"policy",id,enabled,target,batch}` edits an existing replenishment policy;
  target and batch are decimal strings, enabled is boolean
- `{op:"stagePack",expectedRevision,pack:{...}}` validates a full pack then stages it
  atomically. Current run remains pinned. Invalid/stale proposals leave all state intact

A host saves the entire GameState, including pinned/staged pack, campaign witnesses,
policy settings and policy command sequence. Saving only World loses continuation.
Do not label a successful enqueue as a durable save. New/restore activation must use
fresh authority and become visible only after writing, fsync, readback and directory
sync. Terminal games observe/save/restore but do not keep advancing objectives.
