# Afterlight

The current Afterlight source includes its pure world, ordered frame/session
boundary, 3D renderer, procedural audio and native/browser hosts. It derives
from the MIT game at `6367b56e3ff2042199667f2a5bfa50695f4aaf2f`; copyright and
third-party notices remain in LICENSE and [THIRD-PARTY.md](THIRD-PARTY.md).
The earlier whole-source comparison oracle is retired to Git history.

## Read and test

Start with `src/Garden/Types.hs`, `World.hs`, `Rules.hs`, `Arena.hs` and
`Session.hs`. The session consumes ordered frames while retaining clock debt,
pending edges, pilot state and interpolation. Hosts own IO and resource handles;
the simulation remains pure.

From the repository root, with the documented current GHC/Cabal on PATH:

```sh
python references/afterlight/scripts/check-core.py --download
```

The isolated checker runs current world laws and frame-boundary tests, then
compiles public clients. Valid session operations compile; forbidden private
world/pilot updates must fail for the intended reason. `--download` permits
only its pinned official Hackage sources; later checks can use the local cache.
This route does not establish native GPU, audio playback or browser acceptance.

## Native host

On Windows x64, use GHC 9.14.1, Cabal 3.18.2.0, Git, and Python 3. The app
requires a Vulkan 1.3 driver with KHR or EXT surface and swapchain maintenance1
support. Build a local runnable folder from the repository root.

```powershell
cabal update
references/afterlight/scripts/build-native.ps1
& '.build/afterlight-native/Afterlight.exe'
```

Keep `gameio-audio-worker.exe` and `assets` beside `Afterlight.exe`. The script
fetches the pinned Game IO commit, verifies the Noto CJK 2.004 font and license,
and generates the WAV bank. Pass `-OutputDirectory` to choose a fresh folder
for another build. See [third-party notices](THIRD-PARTY.md) for redistribution.

The Windows CI job builds `afterlight-native`, the WAV generator, and the
worker through `cabal.project.gameio-afterlight`. The host uses Win32, Vulkan,
and a separate WASAPI process. The dependency preparation preserves Yampa's
SplitMix algorithm and uses Windows for seed acquisition. [SplitMix adaptation](dependencies/splitmix-win64/README.md)

The older host is available through the original `-fnative -f-gameio-native`
configuration. It uses h-raylib and remains the comparison route for the Vulkan
port.

## Browser host

See [the Web build](web/README.md) and [rendering](docs/rendering.md). The Wasm
cross-compiler and Emscripten are separate toolchains. A native test does not
qualify a browser build or actual play on another device. A compiled Web
distribution must carry the notices, matching source and relinking material
required by its actual dependencies.

## Formatting

The repository formatter covers current Haskell source. Definitions split
by CPP use a branch-aware check with the same verified Ormolu:

```sh
python references/afterlight/scripts/check-cpp-format.py
```

`--write` formats the marked declarations and checks that preprocessing yields
equivalent modules for the Game IO, legacy native, and browser hosts. It uses
`cpp` and compares the current source with the proposed formatting.
