# Publication manifest

`PUBLICATION-MANIFEST.json` schema 3 lists every selected path in sorted order.
Text uses its LF-normalized SHA-256 (`sha256_lf`). The one explicitly selected
documentary PNG uses the SHA-256 of its original bytes (`sha256_raw`).
License and maturity resolve from the longest
matching prefix in [the selection policy](publication/policy.json). Origins resolve
by exact path in [the provenance inventory](publication/provenance.json); only
paths absent from that inventory use the manifest's authored-for-public-alpha
default. The selected export decision and review declaration apply to all rows.
Both canonical metadata files are selected and hash-bound before the gate uses
their rules or defaults. Historical provenance and license notices stay intact.

After reviewing a source or metadata change:

1. Run `python tools/publication.py snapshot`
2. Review the manifest diff
3. Run `python tools/publication.py check`

Snapshot creates a review candidate; it does not approve new source, origins or
licenses. The gate requires an exact match with Git's tracked and nonignored
untracked source inventory, checks the canonical metadata and every source hash,
and writes per-file inspection results to `.build/export-report.json`.

The [README](README.md) links the source families and their current guides;
[the roadmap](docs/roadmap.md) lists remaining work.

The public history begins at its existing initial commit. Selected source is
derived from an author-supplied technical snapshot identified by commit digest
`5335bb14f9ca644fbdc62a00be892f33ad590ba6`; its private repository address and
Git objects are not exported. New alpha documentation and tooling are authored
under the repository MIT license. Original selected MIT notices are retained.

No unreviewed third-party artwork, fonts, binaries, toolchain, private notes,
internal agent instructions or personal settings are included. A successful
pattern scan is bounded evidence, alongside the explicit file-selection and
license review, not a proof that arbitrary content is safe to publish.

All selected files, including the compact root inventory, have the same 512 KiB
size ceiling and license checks. Text also receives the credential/path scan;
the exact documentary figure follows the narrow binary rule below. Unknown manifest schemas,
malformed or duplicate entries, noncanonical paths and symlinks fail closed.
The [live Red Dune provenance](references/red-dune/PROVENANCE.md) identifies
its archived source base. Runtime saves, build outputs, downloaded dependencies
and third-party art/audio/font bundles are not part of the live distribution.

## Selected research imports and documentary figures

New research imports record their original LF hash, published LF hash, retained
license and concrete adaptation in the provenance inventory. Refreshing the
manifest alone cannot silently approve changed imported bytes: the gate also
compares their published provenance hash. New authored explanations identify
the source set and date without exporting private notes or their locations.

The sole binary exception is the owner-authored native prototype screenshot at
`references/prolog-fall/docs/guide/native-demo.png`, needed by the original guide
generator. The policy binds its exact path, raw SHA-256 and 1120×800 dimensions;
the provenance binds its source identity and MIT notice. The gate verifies the
PNG structure and CRCs, permits no metadata chunks, and preserves the 512 KiB
limit. A different filename, altered bytes or missing provenance is rejected.
This does not admit runtime game assets or a general image directory.
