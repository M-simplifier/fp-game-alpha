# Red Dune 0.6: optional source reference

This is a selected, in-progress colony simulation reference, not a complete game or campaign release. It is optional and must not be added to the foundation root project's packages. Intended repository location: references/red-dune.

## Requirements and bounded check

Linux, Python 3 (standard library only), GHC 9.6.x (base 4.18), and Cabal 3.x. The unix dependency makes this Linux-oriented; other platforms are not claimed. Dependencies are GHC-bundled packages and the two explicitly selected public foundation libraries. No download or installation is performed.

From this directory, replace the three paths with your local foundation checkout, Cabal executable, and GHC bin directory:

    python3 tools/test_restore.py
    python3 tools/check.py verify
    python3 tools/check.py check --foundation /path/to/fp-game-alpha --cabal /path/to/cabal --ghc-bin /path/to/ghc-9.6/bin

The check verifies the manifests, decodes the fixture text byte-for-byte, verifies every hash and size, and exclusively creates a fresh .build/check-* directory. It copies only approved inputs plus the pinned foundation library files into that directory. Foundation hash mismatch means the supplied checkout differs; inspect the mismatch rather than editing the digest blindly. FOUNDATION-MANIFEST.json pins the current formatted public core. FOUNDATION-TESTED2487-MANIFEST.json preserves the earlier bytes used by the recorded full game tests; it is historical evidence, not a fallback accepted by the helper. CHECK-SUMMARY.md separates full game results on those earlier bytes from bounded build/core-law checks on the current formatted core.

Cabal runs offline with an isolated configuration and active-repositories: :none. The commands are build exe:red-dune, run exe:red-dune -- test-m1, and run exe:red-dune -- test. These are executable entrypoints; this package has no Cabal test-suite stanza. Tests generate evidence and may overwrite restored fixtures only inside the newly created isolated directory. Inputs in this reference and in the foundation checkout are never rewritten.

Use the prepare action with --foundation to restore without running Cabal. Each invocation allocates a new directory; it does not reuse, clean, or overwrite an existing work directory. Check logs and CHECK-RESULT.json stay inside that directory. Do not publish .build, raw generated evidence, logs, caches, or executables.

The checked-in cabal.project describes the eventual references/red-dune layout. Use the wrapper for a reproducible fixture-restored check; directly running this project in place does not restore its binary fixtures and lets tests write into the reference.

## What is included

107 unmodified selected text originals and canonical base64 representations of 71 original CBOR files (178 selected originals total), plus explicit public packaging, provenance, and restoration tools. RESTORE-MANIFEST.json maps original relative path, stored path, raw SHA-256, raw byte count, and encoding. SOURCE-SELECTION.json and FIXTURE-SELECTION.json preserve the prior selection metadata verbatim; their historical “local preparation” labels are provenance, not a current publication claim.

The ui/ files are source-only. The HTTP bridge is omitted. The executable's ui-shell command uses stdin/stdout JSON; neither a working browser demo nor browser/HTTP verification is claimed.

See PROVENANCE.md and evidence/migration-scope.md for boundaries. Historical full fault injection, mutation, campaign, performance, and platform acceptance are not implied by passing the two executable entrypoints.
