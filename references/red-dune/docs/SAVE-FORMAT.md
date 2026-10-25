# Live continuation format

Live saves use an explicit `RDLIVE1\n` frame, a 32-byte SHA256 checksum and canonical
CBOR for the whole GameState. The decoder bounds input size, verifies the version
and checksum, decodes strict tagged records and validates the full physical world,
pinned pack, policies, campaign counters and references. No browser number parses
an identity: world, branch, boundary, command, entity and quantity fields are
canonical decimal strings. Word64 decoding uses checked Integer conversion.

The checksum detects accidental damage; it is not an anti-cheat signature. A local
player who controls save bytes and the executable is not a hostile-security boundary.

Campaign evidence and automatic policies are saved with World. Restore never
recomputes achievements from opening grants and never adds elapsed/stable time.
Activation uses a fresh UUID authority, an explicitly reserved branch and a paused
world. Old command identities cannot become new commands after restore. Archived
receipt/high-water state remains available for retry safety within its documented
bounded receipt window.

Legacy schema 3 and 4 checkpoints remain readable through their original decoder. Historical rules profiles 0–7 are distinct from
checkpoint schema versions; schemas 1 and 2 are unsupported. The live
import scope is deliberately S01 profile 6: exact physical state is carried to a
paused legacy sandbox with explicit construction-snapshot profile conversion.
Campaign achievements and policies are not invented for that import. Other
historical profiles are previewable and continue in the archive executable.
Source checkpoint bytes are never rewritten by preview or import.

The IO host owns file locks, bounded requests, durable temporary-file write/fsync,
atomic rename, directory sync and readback. A successful pure `encodeGame` is not
itself a durable-save receipt. The host documents and tests its activation/cancel
barriers separately.
