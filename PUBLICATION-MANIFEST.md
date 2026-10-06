# Publication manifest

`PUBLICATION-MANIFEST.json` schema 2 lists every selected path and its LF-normalized
SHA-256 digest in sorted order. License and maturity resolve from the longest
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
size ceiling and text/credential/license checks. Unknown manifest schemas,
malformed or duplicate entries, noncanonical paths and symlinks fail closed.
The [live Red Dune provenance](references/red-dune-live/PROVENANCE.md) identifies
its archived source base. Runtime saves, build outputs, downloaded dependencies
and third-party art/audio/font bundles are not part of the live distribution.
