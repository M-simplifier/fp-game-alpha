# Third-party software

The prototype uses unmodified upstream Windows runtime distributions and a new project-specific foreign interface. Keep their notices with any local package. No third-party images, music or fonts were imported; drawing uses raylib's built-in font and geometric primitives.

## SWI-Prolog 10.0.2

SWI-Prolog is distributed under the Simplified BSD license, with additional requirements possible for linked libraries. The complete upstream notice is retained at `.runtime/swipl/LICENSE`, and upstream documentation is retained under `.runtime/swipl/doc`.

Its Windows archive also contains dependencies such as GMP, libffi and other libraries with their own licenses. The local runtime is retained as distributed; this document does not relabel all bundled dependencies as BSD. Before a public redistribution, inspect the actual loaded components with SWI-Prolog's `license/0` and complete a dependency notice review. This task prepares a private local prototype, not a public release.

Source and license information: [SWI-Prolog](https://www.swi-prolog.org/license.html).

## raylib 6.2

Copyright (c) 2013-2026 Ramon Santamaria (@raysan5).

This software is provided "as-is", without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

The complete upstream license also remains at `.runtime/raylib/raylib-6.2_win64_msvc16/LICENSE`. Source: [raylib](https://github.com/raysan5/raylib).

## 7-Zip 26.05

Igor Pavlov's 7-Zip is used to unpack local archives during setup. The bootstrap `7zr.exe` identifies itself as public domain. The full extractor carries LGPL/BSD/unRAR-related notices retained in `.runtime/7zip/License.txt`. Setup tools are not required to run the game. Source and notices: [7-Zip](https://www.7-zip.org/license.txt).
