# Native APL / raylib platform

GNU APL runs the application loop. For each frame, APL forms an `N×9` numeric
array describing geometric primitives and sends that batch to a small Windows
program. That program draws the array with raylib and returns the clock,
window dimensions and keyboard state. There is no board, piece, collision,
rotation, drop, score or solver code in the C host.

The checked example is `examples/array-smoke.apl`: APL constructs 192 colored
rectangles using array expressions and animates their colors. The same host
can run other APL programs without changing its C source.

## Run and reproduce

Prepared local runtime:

```powershell
.\Play.cmd
.\Demo.cmd
.\Test.cmd
```

Run the standalone array example from PowerShell:

```powershell
.\tools\run.ps1 -Script @('examples\array-smoke.apl')
.\tools\run.ps1 -Script @('examples\array-smoke.apl') -Frames 120 -Screenshot '.scratch\array-smoke.png'
```

Prepare a clean checkout from official pinned distributions:

```powershell
.\tools\setup.ps1
.\tools\test-platform.ps1
```

Setup extracts archives inside `.runtime`; it does not execute an installer,
install a font, change the registry or change the machine PATH. It needs
network access only when a pinned download is missing. The prepared runtime
runs offline. `tools/build.ps1` rebuilds the host using installed Visual Studio
C++ x64 tools and the Windows SDK. Those tools are needed for rebuilding,
not for playing. The host uses a static C runtime.

`tools/package.ps1` runs the combined tests, creates
`dist/apl-tetris-windows-local.zip` with source, minimal runtime, notices and
pinned upstream archives, then verifies every packaged file against
`MANIFEST.sha256` after extraction. It runs the extracted array example and
game launcher using only Windows system directories on PATH. It also writes
a separate SHA-256 file beside the ZIP. Game oracle tests need Python 3 on
PATH; playing the prepared game does not need Python or a compiler.

`tools/run.ps1 -Script` takes an ordered string array of APL files. Relative
paths are resolved from the project directory. It automatically loads
`host/api.apl` first. For the game, the default files are `apl/core.apl`,
`apl/inspect.apl`, then `apl/game.apl`; demo adds `apl/demo.apl` before game.
The final file executes the program and can end with `)OFF`. Other files only
define functions and values.

The raw host executable is `.runtime/bin/array-host.exe`. It accepts absolute
APL file paths after these optional arguments:

| Option | Meaning |
| --- | --- |
| `--width N --height N` | Window size, default 1080×800 |
| `--title TEXT` | Native window title |
| `--fps N` | Frame target, default 60 with vsync requested |
| `--frames N` | Return close=1 on frame N for a bounded run |
| `--screenshot PATH` | Save a PNG at the bounded run's final frame |
| `--snapshot-frame N` | Choose a different screenshot frame |
| `--fixed-dt SECONDS` | Deterministic clock for an automated fixture |
| `--input PATH` | Ordered `frame key-index down` fixture rows |
| `--native-input PATH` | The same rows posted as native messages to this host's own window |

`--fixed-dt` and `--input` are generic test controls. They contain no gameplay
decisions. Input fixture frames start at 1; `down` is 0 or 1. A held injected
key remains held until a release row. Its pressed bit is 1 only on a transition
from released to held. Physical keys and injected keys are combined by OR.

The separate `--native-input` regression posts Win32 key messages to the
host's own HWND before raylib's event poll. It does not target any other
window or inject into the global keyboard. `examples/native-key-input.txt`
puts R down+up in frame 2 and Left down+up in frame 4. The APL assertions
require held=0 and pressed=1 on those frames, followed by pressed=0. This
exercises the Win32 → GLFW callback → raylib queue → host → APL route. It is
separate from an operator pressing keys through the actual native desktop.

## APL calling contract

Sources are UTF-8 without BOM. The project uses actual GNU APL 2.0, zero-based
indexing, traditional `∇` functions and `→` branches. It does not translate the
program into another language. Dyalog namespaces and structured control syntax
are not assumed by this code. Array shape/indexing, reduction `∧/` and prefix
scan `∧\` were executed against the bundled interpreter before selecting it.

```apl
⍝ One opaque rectangle: op x y width height r g b alpha
rects←1 9⍴0 40 80 160 30 80 170 240 255
unused←40 30 20 235 240 255 255 RLText 'Hello from APL'
input←RLFrame rects
unused←RLClose 0
```

`input←RLFrame rectangles` presents one complete frame and returns a length-38
numeric vector. Use `RLFrame 0 9⍴0` for an initial input snapshot. Each frame
clears to RGB 10 14 23, draws primitive rows in order, then queued text.

| Indices with `⎕IO←0` | Returned values |
| --- | --- |
| 0 | Close requested: 0 or 1 |
| 1 | Elapsed seconds since the previous presented frame |
| 2 | Seconds since window initialization |
| 3, 4 | Window width, height |
| 5 | Presented frame number, starting at 1 |
| 6…21 | 16 held-key bits; exported as `RLHeld` |
| 22…37 | 16 pressed-key bits; exported as `RLPressed` |

Keyboard order is Left, Right, Down, Up, Z, X, Space, P, R, Escape, C, Tab,
Enter, A, D, S. Named zero-based constants such as `RLLeft`, `RLSpace` and
`RLTab` select entries. For example, `input[RLPressed[RLSpace]]` tests the
space press edge. Escape is returned to APL; it does not automatically close
the host. Game code decides what that key means.

Primitive rows have columns `op x y w h r g b a`:

| op | Drawing |
| --- | --- |
| 0 | Filled rectangle at x,y with width w and height h |
| 1 | Rectangle outline, 1 pixel thick |
| 2 | Line from x,y to w,h, 1 pixel thick |
| 3 | Filled circle centered at x,y with radius w; h is ignored |

Coordinates can be fractional or negative; each RGBA channel is clamped to
0…255. At most 8192 primitives fit one accepted frame, also subject to the
2 MiB line bound. Numeric fields must be finite. GNU APL's overbar negative
sign is converted to the C numeric spelling only in numeric fields.

`x y size r g b a RLText 'single line'` queues a label for the next frame.
At most 512 labels are queued; each label allows 4095 UTF-8 bytes. Raylib's
built-in font is used, so the current UI text uses ASCII. The transport carries
UTF-8, but this font does not provide Japanese or APL symbol coverage.

The host's stdout pipe is reserved for the protocol. Use `unused←RLLog text`
for diagnostics. `RLClose 0` requests normal shutdown. Unknown APL output,
including an interpreter error, makes the host report the original line,
terminate the run and return nonzero.

## Process and input behavior

The C host launches the workspace-local APL executable with anonymous pipes,
`-s --noSV --rawCIN --OFF`, and an explicit `APL_LIB_ROOT`. It passes each
source as a separate `-f` argument. It never starts a network server. APL
reads input with `⎕FIO[8]` and writes complete frame batches with `⎕FIO[23]`,
flushing once per frame. There is no operating-system call per rectangle.

While waiting for APL output, the host checks available pipe bytes and pumps
native events at up to 120 Hz. Press edges observed during that wait remain
latched until the next returned input vector. Held bits reflect the latest
key state. The host drains raylib's `GetKeyPressed` queue after each event
poll, so a down+up pair inside one poll still returns a press bit even when
the final held bit is 0. Multiple taps of the same key before one APL frame
are coalesced into that frame's Boolean press bit. `IsKeyPressed` alone uses
previous/current held state and can miss that short-tap case; see the
[raylib input implementation](https://github.com/raysan5/raylib/blob/6.2/src/rcore.c)
and [GLFW key callback](https://github.com/raysan5/raylib/blob/6.2/src/platforms/rcore_desktop_glfw.c).
`examples/input-diagnostic.apl` retains visible and logged press counts for
native-key testing, with an optional APL delay toggled by Space.
Native window close is passed to APL, with a 350 ms grace period;
if APL remains stuck, the host cancels that child and closes the window.
An owner close is a normal exit; a protocol failure is an error exit.

GNU APL writes `.apl.history` even in script mode. Its working directory is
therefore `.scratch/runtime`, so that generated file stays local. Relative
file I/O from APL also resolves there; use an explicit path for other files.
The distributed Windows interpreter does not accept the live manual's newer
`--noPrefs` flag. Startup flags disable workspace continuation and colored
output, and the API explicitly sets `⎕IO`, `⎕PP` and `⎕PW`; an independently
configured user preferences file could still affect other interpreter settings.

## Observed verification and limits

`tools/test-platform.ps1` runs a six-frame APL fixture, checking exact input
length, dimensions, fixed dt/time, key held/press transitions and bounded close.
It independently checks screenshot pixels for negative-coordinate clipping,
rectangle fill/outline, circle and out-of-range color clamping. It then runs
the same-poll native-key regression described above. A scratch build with
only the old `IsKeyPressed` edge detector restored failed that fixture at
frame 2; the queued-key implementation passed. This distinguishes the fixed
native callback path from the separate synthetic input flags.
The suite also runs
an APL infinite loop and sends a synthetic native window-close message. The
window and child both exited in about 0.6 seconds on this host. A separate
APL `VALUE ERROR` fixture returned nonzero and released the native host.
The same suite passed in Windows PowerShell 5.1, which the CMD launchers use.

The real-time 192-rectangle example rendered and was visually inspected.
Screenshot capture flushes the raylib draw batch before reading pixels, so
the saved image is the selected frame rather than an earlier back buffer.
These automated platform checks do not establish human keyboard feel,
gameplay correctness or performance on another PC; those require their own
game and owner tests. Separate native desktop key acceptance by the parent
is recorded in `docs/VALIDATION.md`, with its actor and scope. The host
currently has geometric primitives and text,
without audio, textures or game-specific animation.

Observed DLL imports require only the supplied `raylib.dll` and
`libwinpthread-1.dll` in addition to Windows system DLLs. No Visual C++ runtime
DLL or Prolog installation appears in those import lists. A package smoke run
also uses a restricted PATH to check this at the executable consumer.

## Dependency provenance

All files are pinned by SHA-256 in `tools/setup.ps1`. The first preparation
reused the matching raylib/7-Zip archive bytes from a sibling prototype only
as a download cache. This project owns independent copies; no launcher,
binary, source include or runtime path refers to that sibling.

| Artifact | Official origin | SHA-256 |
| --- | --- | --- |
| GNU_APL_2_0_r3518_Setup.exe | [GNU APL download](https://ftp.gnu.org/gnu/apl/GNU_APL_2_0_r3518_Setup.exe) | `7f4ccf0ba6261b26fd6f1734a0ccc84f6da47e3713040d212effec5b313fb1dd` |
| apl-2.0.tar.gz | [GNU stable source](https://ftp.gnu.org/gnu/apl/apl-2.0.tar.gz) | `24bbb744fce47e62837234a053bdeecee51b9ea61c82c79f7cc191bc6a54c0a1` |
| raylib-6.2_win64_msvc16.zip | [raylib 6.2 release](https://github.com/raysan5/raylib/releases/tag/6.2) | `8467b5dd6db4d7ab942f3148a3d30d93be6ed9b2fab88069d177e59604268ebd` |
| 7zr.exe, version 26.05 | [7-Zip 26.05 release](https://github.com/ip7z/7zip/releases/tag/26.05) | `9bf582b894dfa665f852d7e9112b02290a1c303c2d95a21fcdc41ffcb03143b7` |
| 7z2605-x64.exe | Same release | `fd99e86f57d8f429ef5ed045bf98315af962e2309b0f1ba87a147a44c71647d0` |
| winpthreads COPYING | [Official v7.0.0 notice](https://raw.githubusercontent.com/mingw-w64/mingw-w64/v7.0.0/mingw-w64-libraries/winpthreads/COPYING) | `63263614cdd29f2f93cba85e992f041b31f9fc7b4033692f31269489a8a1b177` |

The installer filename says r3518, but its extracted binary reports:

```text
GNU APL 2.0 / SVN 3506M
Build Date 2026-07-29 16:47:31 CEST
Archive SVN 3497
```

The extracted `apl-2.0.exe` SHA-256 is
`1513dc2e9fd7755e18daf75639acc23e69958b082fc056f3b6879a19d3833811`;
the bundled `libwinpthread-1.dll` is
`d637c25fc28eca950cf8223d6d9f346361ae42a6dd92ba0f16120eb9161f924a`.
The used raylib DLL is
`d0d6830501bcd49a02912c15b24be105245e062ed3fad3ad8e568072027cfa3e`.

GNU APL's binary identifies GPL version 3 or later. Its full `COPYING` is
retained in `vendor/licenses/GNU-APL-COPYING`; the official stable source
archive is kept in the local bundle. That stable archive is **not verified
as exact corresponding source for the Windows binary reporting 3506M**.
The local portable bundle is for the owner's local prototype. It is not
presented as a public release or a completed public redistribution review.

Raylib uses the zlib license; its original notice is retained in
`vendor/licenses/raylib-LICENSE`. The GNU installer also bundles
`libwinpthread-1.dll`. The MinGW-w64 winpthreads notice is retained in
`vendor/licenses/winpthreads-COPYING`, retrieved from the official v7.0.0
source tree; the DLL's exact upstream revision is not identified by the
installer. 7-Zip is a setup-only extractor, with its original notice retained
in `vendor/licenses/7zip-License.txt`. See [7-Zip licensing](https://www.7-zip.org/license.txt)
and [winpthreads source notice](https://github.com/mingw-w64/mingw-w64/blob/v7.0.0/mingw-w64-libraries/winpthreads/COPYING).
No imported music, image asset or third-party font is used by the game host.

## Existing APL binding considered

[raylibAPL](https://github.com/Brian-ED/raylibAPL) is a real, MIT-licensed
Dyalog APL binding with Windows support and many more raylib functions than
this small host. It was examined before choosing the runtime. It imports
through Dyalog facilities such as `⎕FIX`, namespaces and its generated native
interface; it is not a drop-in GNU APL library. No Dyalog executable was
available in this task, and no account, purchase or license assent was made.
The implementation here uses no raylibAPL source and does not claim to port
its API. The [GNU APL manual](https://www.gnu.org/software/apl/apl.html) is
the reference for scripting and `⎕FIO`, with the binary-specific flag limit
above verified directly.
