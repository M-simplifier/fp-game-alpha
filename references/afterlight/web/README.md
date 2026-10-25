# Browser build

This builds the existing Haskell game and raylib renderer into one directory
of static browser files. The supported build host is **x86-64 Linux or WSL2**.
The runtime assets are supplied separately, as with the native public source.

## Build

With [Nix](https://nixos.org/download/) and its `nix-command` / `flakes`
features enabled, run from `references/afterlight/`:

```sh
nix develop path:./web --command bash web/build.sh --assets /path/to/native/assets
python3 web/serve.py --directory .build/afterlight-web
```

Open `http://127.0.0.1:8000`. Serving over HTTP is required; opening `index.html`
with `file://` does not provide the fetch behavior used by the host.
Copy the **whole output directory** to a static host when distributing it.
The files work without a game server or cross-origin isolation headers.

The first build downloads the pinned compiler dependencies, Emscripten SDK,
h-raylib source, npm dependencies and a 1.15 MB fontTools wheel. Later builds
reuse their external cache.
Generated files and runtime assets are not added to the source repository.

```sh
bash web/build.sh --assets /path/to/native/assets \
  --output /path/to/site --cache /path/to/build-cache --jobs 4
```

The same script also works from an existing toolchain environment. Put
`wasm32-wasi-ghc`, `wasm32-wasi-ghc-pkg`, `wasm32-wasi-clang`, Python 3.10+, curl,
tar, patch, Node and npm on `PATH`; set `CABAL` when choosing a Cabal executable.
An activated Emscripten 3.1.45 is reused. Otherwise the script installs it in
the build cache. It checks the GHC, Cabal and Emscripten versions before building.

The default cache is `$XDG_CACHE_HOME/afterlight-web`, or
`$HOME/.cache/afterlight-web`. `AFTERLIGHT_WEB_CACHE` also overrides it.
Builds using one cache should run sequentially. For simultaneous builds, use
separate cache and output directories.

## Fixed inputs

This cross SDK uses its supplied Cabal 3.14.2 driver. Native projects use
Cabal 3.18.2; that driver's wired-unit constraints conflict with the SDK's
host/target unit identities. Use the locked pair rather than changing package
IDs or rebuilding compiler boot libraries.

| Input | Verified version / source |
| --- | --- |
| GHC-Wasm | `9.14.1.20260731`, official `ghc-wasm-meta` revision `8079eb96bbc63823d99ad8acaff0765532625474` |
| GHC bindist | Release `20260731T193144`; its archive hash is fixed by the meta-flake |
| Cabal | `3.14.2.0`, the matching driver and archive hash from the locked official meta-flake |
| Emscripten | `3.1.45`; SDK manager revision and archive SHA256 in `build.sh` |
| h-raylib | `6.1.0.0`, Hackage archive SHA256 in `build.sh` |
| Haskell packages | Compiler boot packages plus version constraints and index date in `cabal.project.template` |
| Browser packages | `host/package-lock.json` |
| Font subsetter | [fontTools 4.61.1](https://pypi.org/project/fonttools/4.61.1/), pure-Python wheel with SHA256 in `build.sh` (MIT) |

`patches/h-raylib-web.patch` is applied to the verified archive in the cache.
It adapts the wasm32 layouts of the Haskell binding while preserving native
values. The bundled raylib C source is unchanged. `checks/abi.c` asks the actual
Emscripten compiler to verify 21 structures and 94 field offsets.

The compiler supports Template Haskell. Selecting its installed `time`, `unix`
and `directory` avoids linking additional boot-library versions into the TH
interpreter. `wasm-link` removes GHC's `--stack-first`, preserving the separate
Haskell and raylib memory arenas selected by this host.

C objects are cached by C source/header content, Emscripten identity and build
script content. Cabal tracks Haskell dependencies in a compiler-specific build
directory. The browser reactor path comes from Cabal's `plan.json`: using
`cabal list-bin` with an accidentally native `ghc-pkg` can misidentify this
cross build. `build-info.json` in the output records the selected tool versions
and h-raylib archive/patch hashes.

The build scopes `tool-bin/ghc-pkg` to the selected Wasm package manager.
This prevents a replan from rediscovering a native package tool on `PATH`.
It changes neither the global toolchain nor another project's cache.

## Assets and HTTP delivery

`prepare-assets.py` subsets the supplied Noto Sans CJK JP OpenType font while
retaining its glyph outlines, hints, layout features and name/license metadata.
ASCII and the supplied `fonts/glyphs.txt` are required; missing glyphs fail the
build. Printable characters from `src/**/*.hs` are conservative candidates,
including `uiCorpus`, notices, place names, menus and photo labels. Candidates
are intersected with the original font's character map, so an unsupported emoji
in a comment does not break the build. The generated `glyphs.txt` lists the
resulting set for raylib. Put text from outside those literal sources (including
Unicode escape sequences) into the supplied `glyphs.txt`. Check actual UI text
for missing glyphs as well: subset generation cannot certify all displayed text.
The [fontTools subsetter](https://fonttools.readthedocs.io/en/latest/subset/index.html)
runs directly from the verified cached wheel; no pip install or native extension
is required. The original assets stay intact and the font's OFL license is copied
to the output. Audio stays as the original WAV bytes.

The build also generates deterministic `.gz` sidecars. `serve.py` actually sends
them when the browser accepts gzip, with the original content type (including
`application/wasm`), `Content-Encoding: gzip` and `Vary: Accept-Encoding`.
It respects `q=0`, uses an ETag per representation, and returns `304` when the
cached representation is current. `Cache-Control: no-cache` allows storage but
requires revalidation: these stable filenames must not be served as immutable.
Asset manifest `bytes` always means **decoded** bytes, matching fetch results;
HTTP `Content-Length` can be smaller under compression.

For another static host, enable its gzip/Brotli delivery or configure it to serve
the `.gz` files with the same encoding and MIME headers. Merely uploading sidecars
does not enable compression. Plain `python3 -m http.server` still works, but serves
the original files without this transfer reduction.

The 2026-09-20 asset check reduced the font from 16,467,736 to 202,212 bytes for
374 characters. All requested outlines, horizontal/vertical metrics and name
records matched the source, and repeated subsets were byte-identical. The bundled
raylib `stb_truetype` also produced identical pixels and offsets at font size 48. This
reduces the 21 runtime assets from 36.4 MB to 20.1 MB before HTTP compression.
The final measured site payload falls from the old 44.2 MB to 28.7 MB
uncompressed, or 18.0 MB using gzip. These are byte counts, not a
startup-time guarantee; world construction and graphics initialization still
need separate timing in the browser.
The [experience report](EXPERIENCE.md) records the source-backed decisions,
startup stages, cold/warm observations and remaining validation boundaries.

```sh
python3 web/checks/assets.py --site /path/to/site --assets /path/to/native/assets \
  --fonttools-wheel /path/to/build-cache/fonttools-4.61.1-py3-none-any.whl
```

The checks compare the actual font and generated manifest/sidecars, then exercise
HTTP GET/HEAD, gzip refusal, variant ETags, 304 revalidation and rebuild handling
against a local server.

## Verify a changed build

```sh
bash web/build.sh --assets /path/to/native/assets --output /path/to/site
# Activate the cached Emscripten SDK in this shell for the independent ABI check.
source "${AFTERLIGHT_WEB_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/afterlight-web}/emsdk-c59d6e841da55c2c21af32004c4c173cbd1c0f10/emsdk_env.sh"
python3 web/checks/build.py --archive /path/to/h-raylib-6.1.0.0.tar.gz
npm ci --prefix web/host --ignore-scripts --no-audit --no-fund
node --test web/host/test/*.test.mjs
```

The second command checks linker arguments, patch application to the exact
archive and the C ABI. The host tests check protocol and loading behavior.
See the [current verification guide](../../../docs/verification.md)
for observed platform coverage. A successful build is not browser play acceptance.

For actual browser acceptance, verify preview, resize/quality changes, pointer
capture and refusal/retry, movement/mining/building, save/reload, pause/focus,
audio and the downloaded photo. Each browser/device needs its own observations.
No human play or enjoyment claim follows from automated checks.

For a different game, change the package/executable names, `BrowserMain.hs`,
asset list, save paths and input settings. Keep the ABI patch, linker, memory
guard and FFI bridge together; [host/README.md](host/README.md) explains them.

## Rendering preferences and pointer-free verification

The quality menu selects a complete render preset. The optional details panel
independently overrides resolution, shadows, clouds, contact occlusion and bloom.
Choices persist locally; choosing “match quality” removes an override. These
settings never enter a checkpoint or modify semantic ticks.

Preview and resize callbacks render the same Haskell scene without consuming
input. Quality can be checked before clicking Play, with no pointer lock.
`?diagnostics=1` exposes diagnostic DOM data, including HDR capability; optional
`?render-check=1` samples the paused preview. CPU submission/present and animation
frame intervals are not GPU timer-query measurements or gameplay benchmarks.

Shaders are read from this repository's `assets/shaders/`, then translated to
GLSL ES 300. `--assets` supplies fonts and audio. Half-float color rendering is
enabled after the WebGL context exists, and the backend checks framebuffer
completeness before publishing allocations. See [rendering notes](../docs/rendering.md).
