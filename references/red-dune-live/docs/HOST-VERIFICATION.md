# Host verification and boundaries

## Evidence as of 2026-10-04

- Native GHC 9.6.7 build with `-Wall -Werror` passed; the full Cabal pure
  library and native host component also built successfully
- `node tools/test_browser_protocol.cjs` passed: decimal identities above 2^53,
  noncanonical identity rejection, reordered/retired runtime responses, exact
  uncertain retry bodies, concurrent-mutation exclusion, session reset, and a late old-session rejection
  that must not erase a new in-flight action
- `node tools/test_http.cjs <built-host>` passed: observation leaves paused world
  unchanged; only an owner mutates; hostile Origin/Host and duplicate/oversized
  HTTP headers/bodies are rejected; exact duplicate commands retain their result;
  changed bodies cannot reuse IDs; policies and a physical expansion queue run;
  host ticks stop on pause; durable save, preview/cancel, activation, stale old
  session rejection, lease expiry, recovery restart and static assets work
- Deterministic `live-host-lifecycle` native checks passed with controlled IO
  barriers: read cancellation, invisible not-yet-durable candidate, cancellation
  during activation write, restart while that candidate is blocked, ignored late
  completion, safely retained orphan checkpoint, old save failure isolation, and
  rejection of a request whose detailed receipt has been evicted
- Expanded HTTP checks passed for save-folder failure preserving prior files,
  read-phase cancellation, route-bound request identity, Word64 overflow rejection,
  raw pack revision 9007199254740993, stale pack rejection, and durable restart
  into the staged pack; second-process store locking, all supported construction
  menu options, corrupt-checkpoint warnings and outside-store path rejection
- Actual browser rendering, keyboard/pointer, browser reload and responsive layout
  acceptance have **not** been run. A restricted localhost browser route must not
  be bypassed by publishing or tunneling. Native HTTP tests are not a substitute
- Long campaign progression, construction coverage and core boundary tests are
  owned by the separate executable suites; their output is the relevant evidence
  for authored endings, not the shorter HTTP flow

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

## Review-driven prevention

- New/restart activation originally preceded durable write. It now writes and
  verifies before publication; restart/save assertions exercise that boundary
- Ordinary JSON parsing in a browser rounds large pack integers. Upload now sends
  raw pack text for the strict Haskell parser; no Number conversion occurs
- Saving world-only would lose campaign evidence. Every checkpoint encodes the
  entire `GameState`; world-only archive input is a separate explicit migration
- A paused ownerless loop must not issue repeated Pause commands. `pauseGame`
  checks the authoritative mode; observation/lease tests catch revision churn
- Evicted transport receipts cannot safely mean unseen. Canonical monotonic
  high-water counters reject old IDs even after the exact result cache expires
