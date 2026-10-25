# Local HTTP API

The pure API is in [API.md](API.md). HTTP adds serialized clock/ownership,
transport replay protection and native checkpoint IO. JSON identity and quantity
fields are canonical decimal **strings**, including values larger than 2^53.
Never convert them to a JavaScript Number.

The server accepts only its printed loopback Host and same-origin requests. Use
`Content-Type: application/json` for POST and `X-Red-Dune-Client: <random UUID>`
for the tab/controller. The client ID can also appear as `clientId` in the body
for an unload beacon. All replies have the current `{view,campaign,policies,pack,
revision,buildQueue,notices,shell,save,runtime,result}` envelope.

## Read and own

- `GET /api/state`: observe without ticking or adopting a pending IO completion
- `POST /api/claim`, body `{}`: claim only an unowned/expired lease, and pause
- `POST /api/heartbeat`, body `{}`: renew an existing, unexpired four-second lease
- `POST /api/release`, body `{}`: pause and relinquish the current lease

A claim does not resume play. Closing/hidden tabs stop renewing. Another tab may
observe while an owner exists, but cannot mutate. A restarted process has a new
runtime identity and requires a new claim.

## Mutations

POST a pure game action to `/api/command` with these additional fields:

```json
{
  "op": "resume",
  "requestId": "unique-client-id-1",
  "requestCounter": "1",
  "runtimeId": "copied from shell.runtimeId",
  "sessionEpoch": "copied from shell.session.epochCounter"
}
```

The request counter increases monotonically per client. After a timeout, resend
**the identical encoded body to the identical route**, preserving both transport
and game command identities. Do not create a new ID to resolve an uncertain
result. A received rejection is a known result; a revised/new attempt gets a new
ID. Recent exact results are retained for 1,024 requests. An evicted older counter
is rejected rather than executed again.

The browser serializes mutations. It ignores late response serials, retires old
runtime identities, and discards draft/async continuations when the session
changes. Polling and heartbeats can run alongside the single mutation.

Supported pure actions include pause/resume, configure, expand, individual policy
edits, preview and the returned command envelope. A preview pauses before returning
its authoritative world/controller/epoch/sequence/boundary envelope. Only the host
ticker calls `advanceGame`; an HTTP `frame` request is rejected.

Additional host actions:

- `{op:"save"}` queues/coalesces a complete immutable checkpoint. Enqueue is not
  durable success; wait for `save.current.status === "saved"` and inspect its entry
- `{op:"library"}` asynchronously scans live `.rdg` checkpoints. Corrupt files are
  retained and reported as warnings. The browser does not scan old archive formats
- `{op:"previewLoad",entry:<catalog id>,action:"restore"}` pauses and validates the
  entire checkpoint without switching. Wait for `shell.load.status === "preview"`
- `{op:"activateLoad",ticket:<preview ticket>,discardUnsaved:<boolean>}` requests a
  fresh branch. Dirty current progress requires true. Success appears only after
  the candidate is durable and its ticket/epoch/revision are still current
- `{op:"cancelLoad",ticket:<ticket>}` cancels adoption of a reading/preview/activating
  candidate. Completed candidate files may remain; current game is preserved
- `{op:"restart",scenario:"settlement"|"recovery",discardUnsaved:<boolean>}` starts
  the selected scenario using the staged pack, if any. It is saved before visible
- `{op:"stagePackText",expectedRevision:<pack revision>,packText:<raw JSON string>}`
  lets Haskell parse the raw authored text with exact integers. A normal browser
  JSON.parse/stringify roundtrip is not safe for large numeric pack fields

`POST /api/speed` accepts `{speed:"1"|"2"|"4", ...transportFields}`. It changes the
host rate; it does not itself advance a tick.

Load activation is asynchronously adopted by the same 50 ms host loop that owns
ticks. Even while paused it drains completions. Read-only GET requests never take
over that responsibility. An interrupted page can claim control, open the library,
and continue or cancel the existing ticket.

## Failures and retention

Malformed HTTP returns an HTTP error. Accepted protocol envelopes can return
`ownershipRejected`, `sessionRejected`, `identityRejected`, `admissionRejected`,
`loadRejected`, `restartRejected`, `shellBusy`, or `runtimeFault`. Always inspect
`result`, not just HTTP 200. Kernel receipts distinguish acceptance, in-world
failure and already-processed command identities.

A fault stops time. Old checkpoints remain. There is no automatic destructive
pruning, public hosting, arbitrary path access, or automatic world-only migration.
See [host verification](HOST-VERIFICATION.md) for exact bounds and tested races.
