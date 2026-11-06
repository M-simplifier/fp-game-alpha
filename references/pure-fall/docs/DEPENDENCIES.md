# Reproducible source identity

This local Windows x64 build uses GHC 9.14.1, base 4.22.0.0 and Cabal 3.18.2.0.
The complete resolved package set is frozen by `cabal.project.freeze`.

`game-transition` 0.1.0.0 and `game-arena` 0.1.0.0 are copied byte-for-byte from
fp-game-alpha commit `da3ff4de888be9ec62407d57836b075d763a7c89`. All 9 copied
files match the original checkout; `vendor-hashes.json` stores their SHA-256.
No sibling source directory occurs in `cabal.project`.

h-raylib is pinned to **6.1.0.0**. Its Hackage source archive SHA-256 is:

`081199e097ebd510f0d4134122e72a623901d0903473e96e23c24bdfd104c3a5`

Archive URL: https://hackage.haskell.org/package/h-raylib-6.1.0.0/h-raylib-6.1.0.0.tar.gz

The actual bundled `raylib/src/raylib.h` declares `RAYLIB_VERSION "6.1-dev"`,
major6/minor1/patch0. This is the native source compiled by this binding; the
binding's package version must not be presented as a stable upstream raylib
release. h-raylib's cabal manifest declares Apache-2.0; raylib's header carries
the zlib/libpng notice. Both texts are carried in `licenses` in this source export.

The older h-raylib5.6.0.0 binding was rejected by the real solver because its
template-haskell bound excludes the 2.24 bundled with GHC9.14. The build uses
the newer package rather than relaxing those bounds or changing alpha's base
contract. `+disable-lens +detect-platform` are the package flags.

QuickCheck2.19.0.0 is a development-only test dependency. The original development
copy also used Ormolu0.9.0.0 through a project-local verified helper. That optional
formatter, helper and configuration are outside this selected game-source export.
Neither QuickCheck nor the formatter is required by players.

Game graphics and PCM WAV audio are original procedural output. Windows font
files are read from Windows at runtime, not copied into the source or ZIP;
raylib's embedded default font is the fallback. Dependency licensing is listed
in `THIRD_PARTY_NOTICES.md` and the bundled license files.
