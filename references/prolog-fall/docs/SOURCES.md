# Pinned upstreams and research sources

Retrieved and verified on 2026-10-26. Downloads remain in the ignored `.runtime/downloads`; no global installation was performed.

| Component | Official download | SHA-256 |
| --- | --- | --- |
| SWI-Prolog 10.0.2-1, Windows x64 | [Installer archive](https://www.swi-prolog.org/download/stable/bin/swipl-10.0.2-1.x64.exe) | `2ec1f25be0eafb92e559004782b130774c12573fb4b7e8a917e534754a641ad6` |
| raylib 6.2, Windows x64 MSVC | [Release archive](https://github.com/raysan5/raylib/releases/download/6.2/raylib-6.2_win64_msvc16.zip) | `8467b5dd6db4d7ab942f3148a3d30d93be6ed9b2fab88069d177e59604268ebd` |
| 7-Zip 26.05 bootstrap | [7zr.exe](https://github.com/ip7z/7zip/releases/download/26.05/7zr.exe) | `9bf582b894dfa665f852d7e9112b02290a1c303c2d95a21fcdc41ffcb03143b7` |
| 7-Zip 26.05 x64 archive | [Installer archive](https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe) | `fd99e86f57d8f429ef5ed045bf98315af962e2309b0f1ba87a147a44c71647d0` |

The SWI-Prolog hash was published on its [stable download page](https://www.swi-prolog.org/download/stable). The raylib hash was published with its [6.2 release assets](https://github.com/raysan5/raylib/releases/expanded_assets/6.2). The 7-Zip hashes were computed from the fetched official release files and pinned here; they are not claimed to be an independent upstream signature. The bootstrap executable extracts the 7-Zip installer as a 7z archive, and the resulting `7z.exe` extracts the SWI-Prolog NSIS archive. Neither installer is run as an installer.

## Interfaces consulted

- [SWI-Prolog Foreign Language Interface](https://www.swi-prolog.org/pldoc/man?section=foreign): the native DLL registers generic predicates called by Prolog. The Prolog executable owns the loop.
- [SWI-Prolog CLPFD](https://www.swi-prolog.org/pldoc/man?section=clpfd): finite integer domains, integer constraints and explicit labeling. The project documents supported modes instead of assuming all Prolog code is reversible.
- [raylib 6.2 release](https://github.com/raysan5/raylib/releases/tag/6.2) and the versioned `raylib.h` shipped in the archive: window, input, drawing and screenshot functions.
- [Official 7-Zip downloads](https://www.7-zip.org/download.html): local unpacking only.

## Binding investigation

[ai-robert/raylib-prolog-poc](https://github.com/ai-robert/raylib-prolog-poc) demonstrates a SWI-Prolog foreign interface to raylib 5.5 on Windows, including two small raylib examples. Its README requires machine-specific build-script edits. The current official raylib bindings inventory did not identify a maintained Prolog binding during this investigation. This is bounded search evidence, not a claim that no other binding exists.

This project does not copy the PoC's source or use its precompiled DLL. It builds its own small generic bridge against official pinned upstreams. Expanding the bridge into a full raylib binding is outside this prototype's needs.
