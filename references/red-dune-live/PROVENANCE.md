# Red Dune live continuation

This active MIT source package began from the separately preserved public
`references/red-dune` tree at foundation commit
`e2b57188b7f092eb9f840f451ac48586f47617d9`. Its archived source, transfer manifests,
fixtures and historical evidence remain unchanged. The original copyright notice
is retained in [LICENSE](LICENSE); archive licensing context remains available in
[the preserved provenance](../red-dune/PROVENANCE.md).

This is an editable continuation, not a byte-identical archive. All live Haskell
source is included in the foundation's current pinned formatting policy.

## Derived and new source

- `core/Colony/`: copied from the archived MIT implementation, formatted and extended
  in the live tree. Live construction, inventories, reservations, incoming stock,
  natural sources and world validation are extended here. `Colony.Space` also has
  a reviewed valid-coordinate tile-order fast path, retaining the exact original
  comparison fallback for invalid coordinates; no history is rewritten
- `ui/index.html`, `ui/app.js`, `ui/style.css`: continue the archived authored,
  procedural command-room presentation with live campaign, construction, staffing,
  policies and transport/lifecycle interfaces
- `src/RedDune/`: new pure campaign, policy, complete game/save, validated content
  pack and protocol modules
- `app/`, `ui/protocol.js`, `test/`, `tools/`, campaign data and current documentation:
  authored live implementation and tests. Tests construct their own bounded
  states; generated checkpoints are private runtime/evidence outputs

The root [publication provenance](../../publication/provenance.json) records each
inherited path, the source commit and its original LF-normalized SHA-256. The
[publication manifest](../../PUBLICATION-MANIFEST.md) separately records the
current selected live file digests, license and experimental maturity. A changed
current digest is expected; it does not change the original source attribution.

No raw archive save fixtures, downloaded toolchains, dependency source bundles,
compiled game, personal saves or third-party artwork are included in the live
selection. See [the asset inventory](ASSETS.md). Build and verification results
are separate from source ownership and do not establish real-browser acceptance.
