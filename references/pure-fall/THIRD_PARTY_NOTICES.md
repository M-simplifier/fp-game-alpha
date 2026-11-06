# Third-party notices

The exact fp-game-alpha `game-transition` and `game-arena` libraries are vendored
from commit `da3ff4de888be9ec62407d57836b075d763a7c89`. Their MIT notices and
licenses remain in `vendor/game-transition/LICENSE` and `vendor/game-arena/LICENSE`.
This selected source also carries exact notice copies in `licenses/`.
See `docs/vendor-hashes.json` for every copied file's SHA-256.

Native binding: h-raylib 6.1.0.0 (Apache-2.0), by Anut and contributors,
https://github.com/Anut-py/h-raylib. Full binding license is in
`licenses/h-raylib-LICENSE.txt`. Its bundled native raylib 6.1-dev license is the
zlib/libpng license, by Ramon Santamaria and contributors,
https://github.com/raysan5/raylib. The distribution copies their full license
texts from `licenses` when staging; exact native version and source hash
are recorded in `docs/DEPENDENCIES.md`.

No third-party font or music file is redistributed. Native typography loads a
Windows system font and falls back to raylib's built-in font. Procedural audio
and game visuals are original to this project. Windows fonts remain owned by
their respective licensors and are supplied by Windows.

The original development copy also used an optional project-local formatter
from fp-game-alpha. Its helper, configuration and executable are outside this
selected game-source export. No formatter is required to build or test the game.
