# Publication manifest

`PUBLICATION-MANIFEST.json` records every selected path, source digest, license,
maturity, export decision and inspection result. The readable source inventory
is in [the milestone document](docs/roadmap.md).

The public history begins at its existing initial commit. Selected source is
derived from an author-supplied technical snapshot identified by commit digest
`5335bb14f9ca644fbdc62a00be892f33ad590ba6`; its private repository address and
Git objects are not exported. New alpha documentation and tooling are authored
under the repository MIT license. Original selected MIT notices are retained.

No unreviewed third-party artwork, fonts, binaries, toolchain, private notes,
internal agent instructions or personal settings are included. A successful
pattern scan is bounded evidence, alongside the explicit file-selection and
license review, not a proof that arbitrary content is safe to publish.

The generated root inventory alone has a 1 MiB size ceiling; ordinary source
files retain the 512 KiB ceiling. The exception is exact-path, does not exempt
text/credential/license checks, and does not include nested or renamed manifests.
The [live Red Dune provenance](references/red-dune-live/PROVENANCE.md) identifies
its archived source base. Runtime saves, build outputs, downloaded dependencies
and third-party art/audio/font bundles are not part of the live distribution.
