# Source and downstream distribution notices

Original game code is covered by `LICENSE`. The patch
`web/patches/h-raylib-web.patch` includes context from h-raylib 5.6.0.0;
retain `licenses/h-raylib-LICENSE` with that patch. Its upstream source archive
and integrity hash are pinned in `web/build.sh`.

The Web host cites the h-raylib Web template as a protocol reference. Its
runtime npm dependencies are not vendored here: `package-lock.json` pins their
integrity and package managers retain their own license files. Retain those
notices when bundling the resulting application.

The Noto font is not committed; the explicit preparation script fetches both
fixed source font and its original license. Generated subsets must keep the
font's applicable notices and modification/renaming conditions.

Haskell, raylib, WebAssembly runtime, GMP, libc and toolchain components in a
compiled distribution have their own licenses. Build outputs are deliberately
excluded from this source import. A release must inventory its actual linked
components, retain notices, and provide required matching sources/relinking
materials. Earlier binary-distribution audit results do not automatically
apply after a dependency, linker or toolchain change.
