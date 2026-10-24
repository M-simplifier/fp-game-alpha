# Verify a development change

Follow [the development loop](DEVELOPMENT.md). A successful reload must restart
a fresh paused world, terminate and reap the previous host, and preserve
explicit save/retry semantics. Run `tools/test_devloop_lifecycle.py` and
`tools/test_devloop.py` against the actual devloop binary.

Use [current verification](../../../CURRENT-VERIFICATION.md) for the toolchain
and consumer results. Data staging is a different path: invalid, stale or huge
integer input must preserve both the staged proposal and current world.
No fixed source-edit latency is promised.
