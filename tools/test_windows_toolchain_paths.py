"""Accept the current Windows compiler and private UTF-8 bootstrap boundary."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GHC_VERSION = '9.14.1'
CABAL_VERSION = '3.18.2.0'

# Exercises the actual console-output path and a closed downstream pipe.
STREAM_PROBE = r"""import ctypes,msvcrt,subprocess,sys
from pathlib import Path
helper=Path(sys.argv[1])
with open('CONOUT$','wb',buffering=0) as screen:
 producer='import os,time\nfor b in "あ🙂".encode("utf-8"):\n os.write(1,bytes([b])); time.sleep(0.05)\n'
 p=subprocess.run([str(helper),sys.executable,'-c',producer],stdin=subprocess.DEVNULL,stdout=screen,stderr=subprocess.PIPE,timeout=10)
 assert p.returncode==0,(p.returncode,p.stderr)
 class Coord(ctypes.Structure):_fields_=[('x',ctypes.c_short),('y',ctypes.c_short)]
 k=ctypes.windll.kernel32; k.ReadConsoleOutputCharacterW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_uint32,Coord,ctypes.POINTER(ctypes.c_uint32)]
 text=ctypes.create_unicode_buffer(1024); count=ctypes.c_uint32()
 assert k.ReadConsoleOutputCharacterW(msvcrt.get_osfhandle(screen.fileno()),text,1023,Coord(0,0),ctypes.byref(count))
 actual=text.value.encode('utf-16-le','surrogatepass').decode('utf-16-le')
 # Compare with the console's own WriteConsoleW behavior. Legacy console
 # buffers can replace a non-BMP glyph even when its UTF-16 is correct.
 k.SetConsoleCursorPosition.argtypes=[ctypes.c_void_p,Coord]
 assert k.SetConsoleCursorPosition(msvcrt.get_osfhandle(screen.fileno()),Coord(0,1))
 k.WriteConsoleW.argtypes=[ctypes.c_void_p,ctypes.c_wchar_p,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.c_void_p]
 assert k.WriteConsoleW(msvcrt.get_osfhandle(screen.fileno()),'あ🙂',3,ctypes.byref(count),None)
 control=ctypes.create_unicode_buffer(1024)
 assert k.ReadConsoleOutputCharacterW(msvcrt.get_osfhandle(screen.fileno()),control,1023,Coord(0,1),ctypes.byref(count))
 expected=control.value.encode('utf-16-le','surrogatepass').decode('utf-16-le')
 assert actual[:4]==expected[:4] and actual.startswith('あ'),(repr(actual[:8]),repr(expected[:8]))
producer='import os,sys\ntry:\n for n in range(8192):os.write(1,b"x"*8192)\nexcept OSError:sys.exit(23)\n'
p=subprocess.Popen([str(helper),sys.executable,'-c',producer],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
p.stdout.close(); code=p.wait(timeout=10); diagnostic=p.stderr.read().decode("utf-8",errors="replace")
assert code==23 or (code==1 and "hidden UTF-8 console" in diagnostic),(code,diagnostic)
print('Split UTF-8 prefix reaches real console; closed downstream output exits without hanging: PASS')
"""


def run(label, command, cwd):
    result = subprocess.run(list(map(str, command)), cwd=cwd, capture_output=True,
                            encoding='utf-8', errors='replace', timeout=120)
    print(json.dumps({'check': label, 'exit_code': result.returncode}), flush=True)
    if result.returncode:
        raise RuntimeError(label + ':\n' + result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--select-compiler-output', type=Path)
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('This acceptance checks the Windows compiler profile.')
    if args.select_compiler_output and (args.select_compiler_output.exists() or args.select_compiler_output.is_symlink()):
        parser.error('Compiler selection output must be a new file.')
    ghc, cabal = shutil.which('ghc'), shutil.which('cabal')
    if not ghc or not cabal:
        raise RuntimeError('GHC and Cabal are required on PATH.')
    if run('ambient-ghc-version', [ghc, '--numeric-version'], ROOT) != GHC_VERSION:
        raise RuntimeError('Select the declared GHC before this preflight.')
    if run('cabal-version', [cabal, '--numeric-version'], ROOT) != CABAL_VERSION:
        raise RuntimeError('Select the declared Cabal before this preflight.')
    # This is an explicitly selected CI profile, not a game compiler override.
    # Ordinary CLI commands leave their own project/wrapper selection to Cabal.
    ghcup = shutil.which('ghcup')
    if ghcup:
        installed = Path(run('installed-compiler', [ghcup, 'whereis', 'ghc', GHC_VERSION], ROOT))
        compiler = installed.with_name('ghc-' + GHC_VERSION + '.exe')
    else:
        libdir = Path(run('compiler-libdir', [ghc, '--print-libdir'], ROOT))
        compiler = libdir.parent / 'bin' / ('ghc-' + GHC_VERSION + '.exe')
    if not compiler.is_file() or any(ord(c) < 32 for c in str(compiler)):
        raise RuntimeError('The declared installed compiler executable is unavailable.')
    if run('selected-ghc-version', [compiler, '--numeric-version'], ROOT) != GHC_VERSION:
        raise RuntimeError('Selected compiler version does not match the profile.')
    kernel = ctypes.windll.kernel32
    before = (kernel.GetConsoleCP(), kernel.GetConsoleOutputCP())
    with tempfile.TemporaryDirectory(prefix='fp-compiler-profile-') as temporary:
        state = Path(temporary).resolve()
        build = state / 'helper'
        run('bootstrap-private-console', [cabal, 'build', 'exe:fp-game-console', '--offline',
            '--project-dir=' + str(ROOT / 'tools/windows-console'),
            '--builddir=' + str(build), '--with-compiler=' + str(compiler)], ROOT)
        plan = json.loads((build / 'cache/plan.json').read_text(encoding='utf-8'))
        helper = next(unit['bin-file'] for unit in plan['install-plan']
                      if unit.get('component-name') == 'exe:fp-game-console')
        game = state / 'fresh game 日本語'
        (game / 'src').mkdir(parents=True)
        (game / 'app').mkdir()
        (game / 'src/PathMessage.hs').write_text('module PathMessage (message) where\nmessage :: String\nmessage = "path build ready"\n', encoding='utf-8')
        (game / 'app/Main.hs').write_text('module Main (main) where\nimport PathMessage (message)\nmain :: IO ()\nmain = putStrLn message\n', encoding='utf-8')
        (game / 'path-probe.cabal').write_text('cabal-version: 3.0\nname: path-probe\nversion: 0.1.0.0\nbuild-type: Simple\nlibrary\n  exposed-modules: PathMessage\n  hs-source-dirs: src\n  build-depends: base >=4.22 && <4.23\n  default-language: GHC2021\n  ghc-options: -Wall -Werror\nexecutable path-probe\n  main-is: Main.hs\n  hs-source-dirs: app\n  build-depends: base, path-probe\n  default-language: GHC2021\n  ghc-options: -Wall -Werror\n', encoding='utf-8')
        (game / 'cabal.project').write_text('packages: .\nactive-repositories: :none\nwith-compiler: ' + compiler.as_posix() + '\npackage *\n  ar-options: --rsp-quoting=posix\n', encoding='utf-8')
        output = game / '.build'
        run('unicode-library-and-executable', [helper, cabal, 'build', 'all', '--offline', '--builddir=' + str(output)], game)
        plan = json.loads((output / 'cache/plan.json').read_text(encoding='utf-8'))
        binary = next(unit['bin-file'] for unit in plan['install-plan'] if unit.get('component-name') == 'exe:path-probe')
        if run('execute-built-game', [binary], game) != 'path build ready':
            raise RuntimeError('The built executable did not produce its expected observation.')
        probe = state / 'streams.py'
        probe.write_text(STREAM_PROBE, encoding='utf-8')
        run('split-utf8-and-closed-output', [helper, sys.executable, probe, helper], state)
    if before != (kernel.GetConsoleCP(), kernel.GetConsoleOutputCP()):
        raise RuntimeError('The private helper changed its caller console code pages.')
    if args.select_compiler_output:
        args.select_compiler_output.parent.mkdir(parents=True, exist_ok=True)
        with args.select_compiler_output.open('x', encoding='utf-8', newline='\n') as destination:
            destination.write(str(compiler) + '\n')
    print(json.dumps({'status': 'pass', 'compiler': str(compiler), 'parent_console_unchanged': True}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
