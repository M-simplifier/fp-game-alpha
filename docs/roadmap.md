# Next milestones

This page lists remaining work. Current commands, evidence and limits belong
with the relevant feature guide; completed work is not a second status ledger.
The [README](../README.md) routes to those guides and the
[publication manifest](../PUBLICATION-MANIFEST.md) records selected source.

- Station Dispatch: JSON save and asynchronous UI/storage integration, followed
  by actual browser-host acceptance
- Reference hosts: graphical/input/audio checks for the selected pure-core
  games and the preserved Afterlight native/Web hosts, with device performance
  assessed separately from core tests
- Red Dune: continue through the [live campaign guide](red-dune-live.md)'s
  remaining gameplay, browser and distribution gates; preserve the optional
  [archived source route](red-dune.md) independently
- Research: use the [experiment guides](research-reproduction.md) for current
  scoped results. Broader protocol models, cross-backend parity and independent
  proof-certificate checking remain separate experiments. LiquidHaskell's
  [false-division acceptance](../research/liquidhaskell/README.md) still blocks
  a soundness claim even though the pinned diagnostic was reproduced
- Bend: select an isolated public runner for the historical comparison before
  claiming a public rerun. Native CPU, GPU and BendTT kernel checking each need
  their own prerequisites and executed result

Prioritize a concrete game requirement over expanding the catalog. Toolchains,
large binaries and repeated raw logs belong in reproducible downloads or
appropriate release artifacts, not in the source repository.
