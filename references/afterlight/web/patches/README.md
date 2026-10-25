# Upstream patch

`h-raylib-web.patch` adapts h-raylib 6.1.0.0's structure layouts for wasm32.
The native branch preserves upstream values. `checks/abi.c` checks the matching
C sizes, alignments and field offsets with the actual Emscripten compiler.
The bundled raylib C source is unchanged.

The Haskell binding is by Anut and contributors, under Apache-2.0;
see [the retained license](LICENSE-h-raylib.txt) and the
[exact source package](https://hackage.haskell.org/package/h-raylib-6.1.0.0).
This patch is a local modification, not an upstream release.

The metadata hunk is the publisher's [Hackage revision 1](https://hackage.haskell.org/package/h-raylib-6.1.0.0/revision/1.cabal)
(SHA256 `341c48bea1990d790b58d9a7e3ba0532d9d6a2a98160ebaf156a8856d506edc4`), which supports Template Haskell 2.24.
It is applied alongside the ABI changes to the original source archive.
