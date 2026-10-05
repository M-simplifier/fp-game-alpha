# fp-game native tooling

A maintained, opt-in Haskell executable for developer-facing planning,
terminal workspace creation, doctor, build, test, saved-source check and run.
See the [native tool guide](../../docs/native-tooling.md) for the complete
bootstrap, command, compatibility and continuation contract.

This package is separate from the root Cabal project and from each game's
GHC-bundled-only dependency boundary. Build it once using the wrappers:

```sh
# Linux/macOS: explicit first dependency acquisition
sh tools/bootstrap-fp-game.sh --download
# Later, from an existing dependency cache
sh tools/bootstrap-fp-game.sh
```

```powershell
# Windows: explicit first dependency acquisition
./tools/bootstrap-fp-game.ps1 -Download
# Later, from an existing dependency cache
./tools/bootstrap-fp-game.ps1
```

Run these examples from the foundation or a generated game's root. The wrappers
resolve their own source location, so they can also be invoked by absolute path
from an unrelated working directory. `--check` / `-Check` detects missing GHC
or Cabal before compilation without downloads or Python. Bootstrap copies the
result to `.build/tools/fp-game` (`fp-game.exe` on Windows). Run it directly;
normal commands never rebuild or replace the running executable.

For package development:

```sh
cd tools/haskell
cabal build exe:fp-game --offline --builddir=../../.build/native-tool
cabal test all --offline --builddir=../../.build/native-tool --test-show-details=direct
```

The freeze file pins external dependencies and the project pins the package
index. GHC's bundled packages are selected by the tested compiler, rather than
forcing Linux-specific package versions onto Windows. Source compilation needs
GHC 9.6 or newer APIs; only the GHC 9.6.7 baseline is verified. Other compilers
and their dependency resolutions remain unverified. The built tool uses the
game compiler selected on PATH, independently of the compiler that built it. Source acquisition on an
empty cache costs more than a warm build; do not confuse the two measurements.
No prebuilt release, compiler-free source bootstrap or zero-install claim is made.

`create-plan` builds a typed plan, and `create` interprets it with exclusive
creation. `plan`/`scaffold` are aliases. The source foundation is `--project`,
the output destination is a separate positional argument, and neither is the
installed tool directory. Without `--project`, commands use caller cwd.

Generated games carry explicitly selected source files, the package/freeze,
bootstrap scripts and this guide. They exclude local outputs, caches, editor
settings and binaries. They can rebuild the tool and continue without the
original foundation. The optional starter is not a universal game generator;
AI-led development must still implement the actual brief and host.

Python is retained only in separate compatibility/inspection/play/formatting,
maintenance and independent test paths. The migrated native core does not
spawn it. Editor live buffers and headless journal durability are separate work.

Interactive POSIX execution replaces the CLI with Cabal, so the shell retains
ordinary job control without a private foreground proxy or C adapter. Captured
commands own their child lifetime and deadline. Use `run --smoke` when requesting
`--timeout`; interactive runs inherit the terminal instead. The Windows path
retains inherited console behavior and Job Objects.

## Read the implementation by boundary

1. [Main](app/Main.hs) sets UTF-8 streams, parses the request and renders its result
2. [CLI](src/FpGame/CLI.hs) defines commands/options and validates their syntax
3. [Command](src/FpGame/Command.hs) dispatches the chosen command and observed tools
4. [Config](src/FpGame/Config.hs) and [Path](src/FpGame/Path.hs) validate the selected
   project's configuration, source boundary and mutable output locations
5. [Create](src/FpGame/Create.hs) validates creation options, snapshots the explicit
   source selection, renders planned bytes and exclusively applies that snapshot
6. [Process](src/FpGame/Process.hs) owns captured child lifetime and stream capture;
   interactive POSIX execution hands off to Cabal and normal shell job control
7. [Result](src/FpGame/Result.hs) keeps JSON/plain rendering and exit status consistent

[CLI tests](test/Main.hs), [creation tests](test/CreateSpec.hs) and
[process tests](test/ProcessSpec.hs) exercise those boundaries. The foundation's
`tools/test_native_cli.py` independently runs the real generated game and its
relocated continuation, including intentional gameplay changes. It uses Python
as an external oracle; generated core commands use the native executable.
