# Host verification and boundaries

## Run the current checks

Use the bounded commands in the [verification guide](../../../docs/verification.md)
and the game's [verification commands](../README.md#verification-commands).
`test_browser_protocol.cjs` covers decimal identities, retry ownership and session
changes; `test_http.cjs` exercises the actual local HTTP host and checkpoint IO.
The lifecycle suite uses controlled IO barriers to test cancellation and stale
completions. These do not exercise actual browser rendering or human input.

## Protocol ownership

One `MVar Host` serializes user transitions, ticks and adoption of IO completions.
A single 50 ms loop calls `advanceGame` for the selected 1/2/4 ticks. GET `/api/state`
only produces an observation and a response serial; it does not run the world or
adopt a pending load. Wall-clock debt is not accumulated after a pause.

A random per-tab client identity owns a four-second renewable lease. Another tab
cannot steal an active lease. Losing the lease pauses; reconnection does not
resume. All mutations carry runtime identity, session epoch, unique request ID
and canonical decimal request counter. The recent 1,024 exact route/body/result
receipts allow uncertain retries. A per-client high-water counter rejects older
IDs after receipt eviction, so eviction cannot turn a retry into a second action.
The client also serializes mutations and keeps the exact encoded body on failure.

The game command's separate world/controller/epoch/sequence/boundary identity is
never replaced by the transport ID. A restored checkpoint gets a new authority and
a store-wide durable branch allocation. Old-session transport envelopes fail
before entering the game; the game's own receipt/high-water rules also remain.

## Checkpoint lifecycle

Manual and autosave requests coalesce while one immutable snapshot is being
written. At most two workers are outstanding, including cancelled-but-finishing
reads or candidate writes. Workers never change the current game; completions
are tagged with request ticket, session epoch and captured revision.

Load is `reading → preview → activating → activated`, or a terminal cancelled/
failed result. The final adoption tests the active ticket, epoch and revision.
Cancel is a state transition, not a claim that disk IO has been undone. A candidate
that finished writing after cancellation remains an unused recoverable file.
Stale save success or failure cannot overwrite the active session's save status.

The file transaction is capture → encode → temp file → flush/fsync → byte-for-byte
readback → decode/validate → rename → directory fsync. Publishing a new startup,
restart or restored world follows this transaction. Failures retain the current
world and existing checkpoint files. There is no destructive checkpoint pruning.
The save directory lock prevents two host processes using the same branch counter.

## HTTP scope and limitations

The host is intentionally local. `network-3.1.4.0` supplies sockets; a narrow
HTTP/1.1 adapter accepts one GET or POST per connection. Limits: 32 connections,
5 seconds to read the request, 8 KiB headers, 40 unique headers, 64 KiB bodies,
32 MiB checkpoints, two IO workers, 1,024 recent receipts and 256 controller
high-water records per session. Chunked bodies, duplicate headers, proxy paths
and unknown routes are rejected. Only four known asset paths are served.

Exact loopback Host/Origin checks, Fetch Metadata checks, JSON content type,
no-store caching, CSP, frame denial and nosniff are applied. This is not a general
Internet HTTP server, TLS/authentication service or multi-user security boundary.
No promises are made about a malicious local OS user replacing the entire store.
Missing/corrupt branch counters fail closed in an existing store. Checkpoint reads
hold a no-follow file descriptor and enforce the byte bound on the actual read.
Unreadable checkpoint files remain untouched and appear as catalog warnings.

## Manual browser acceptance still required

- Start, claim ownership, configure policies, expansion, pause/resume/speeds
- Use map selection and keyboard-only construction/workforce forms
- Confirm and cancel a preview; repeated clicks must not duplicate mutation
- Interrupt a command response, recover the exact identity, and inspect its receipt
- Open two tabs; only one owns control; hide/close it and verify safe pause
- Save, reload page, preview/cancel, then restore to a fresh branch
- Stage an edited pack, reject a stale revision, restart and see the new identity
- Complete a successful campaign and experience a failed recovery attempt
- Check layout at narrow viewport, 150/200% text, high contrast and reduced motion
