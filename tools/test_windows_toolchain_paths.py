"""Boot-library-only Unicode-path preflight; keep failures ahead of CLI dependencies."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = r'''module Main (main) where
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import qualified Data.ByteString as B
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.IO (hPutStrLn, stderr, stdout)
import System.Process
main :: IO ()
main = do
  args <- getArgs
  hPutStrLn stderr ("launcher argv: " ++ show args)
  case args of
    directory : executable : arguments -> do
      (_, Just out, Just err, child) <- createProcess (proc executable arguments)
        { cwd = Just directory, std_in = NoStream, std_out = CreatePipe,
          std_err = CreatePipe, create_group = True, use_process_jobs = True }
      output <- newEmptyMVar
      errors <- newEmptyMVar
      _ <- forkIO (B.hGetContents out >>= putMVar output)
      _ <- forkIO (B.hGetContents err >>= putMVar errors)
      code <- waitForProcess child
      takeMVar output >>= B.hPut stdout
      takeMVar errors >>= B.hPut stderr
      exitWith code
    _ -> fail "Expected cwd, executable and arguments"
'''


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    records = []

    def report(**record):
        records.append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
        return record

    def run(label, argv, cwd, *, required=True, env=None):
        try:
            result = subprocess.run(list(map(str, argv)), cwd=cwd, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
            return report(label=label, required=required, argv=list(map(str, argv)),
                          cwd=str(cwd), exit_code=result.returncode,
                          stdout=result.stdout.decode('utf-8', errors='replace'),
                          stderr=result.stderr.decode('utf-8', errors='replace'))
        except (OSError, subprocess.TimeoutExpired) as error:
            return report(label=label, required=required, exit_code=1, error=str(error))

    report(platform=platform.platform(), python=sys.version,
           encoding_environment={key: os.environ.get(key) for key in ('GHC_CHARENC', 'LANG', 'LC_ALL')})
    ghc, cabal = shutil.which('ghc'), shutil.which('cabal')
    versioned_ghc_pkg = shutil.which('ghc-pkg-9.6.7')
    ghc_pkg = versioned_ghc_pkg or shutil.which('ghc-pkg')
    report(tools={'ghc': ghc, 'cabal': cabal, 'ghc-pkg': ghc_pkg},
           ghc_pkg_lookup='versioned PATH entry' if versioned_ghc_pkg else 'unversioned PATH fallback; exact version required')
    if not all((ghc, cabal, ghc_pkg)):
        report(status='fail', error='Missing pinned tools')
        return 1
    for tool, version in ((ghc, '9.6.7'), (cabal, '3.12.1.0'), (ghc_pkg, '9.6.7')):
        result = run('version', [tool, '--version' if tool == ghc_pkg else '--numeric-version'], ROOT)
        actual = result.get('stdout', '').strip().split()
        report(label='pinned-version', required=True, tool=tool, expected=version,
               exit_code=0 if actual and actual[-1] == version else 1)
        run('actual-rts', [tool, '+RTS', '--info'], ROOT, required=False)
    if any(item.get('required') and item['exit_code'] for item in records):
        report(status='fail', error='Pinned tool version check failed')
        return 1

    # Contrast the installed PATH shim with GHCup's declared compiler location.
    # These observations cannot turn any original required failure into a pass.
    real_ghc_pkg = real_ghc = alias_ghc_pkg = None
    if os.name == 'nt':
        shim = Path(ghc_pkg).with_suffix('.shim')
        shim_bytes = shim.read_bytes() if shim.is_file() else None
        report(label='selected-ghc-pkg-shim', path=str(shim), exists=shim.is_file(),
               contents=shim_bytes.decode('utf-8-sig', errors='replace') if shim_bytes else None,
               bytes_hex=shim_bytes.hex() if shim_bytes else None)
        ghcup = shutil.which('ghcup')
        if ghcup:
            location = run('ghcup-whereis', [ghcup, 'whereis', 'ghc', '9.6.7'], ROOT, required=False)
            if location['exit_code'] == 0:
                compiler = Path(location['stdout'].strip())
                candidates = [compiler.parent / name for name in ('ghc-pkg-9.6.7.exe', 'ghc-pkg.exe')]
                report(label='real-compiler-files', compiler=str(compiler), exists=compiler.is_file(),
                       package_managers={str(path): path.is_file() for path in candidates})
                if compiler.is_file():
                    version = run('real-compiler-version', [compiler, '--numeric-version'], ROOT, required=False)
                    versioned_compiler = compiler.parent / 'ghc-9.6.7.exe'
                    if versioned_compiler.is_file():
                        selected = run('versioned-compiler-version', [versioned_compiler, '--numeric-version'], ROOT, required=False)
                        if selected['exit_code'] == 0 and selected.get('stdout', '').strip() == '9.6.7':
                            real_ghc = versioned_compiler
                    if candidates[-1].is_file():
                        alias = run('unversioned-ghc-pkg-version', [candidates[-1], '--version'], ROOT, required=False)
                        if alias['exit_code'] == 0 and alias.get('stdout', '').strip().endswith(' 9.6.7'):
                            alias_ghc_pkg = candidates[-1]
                    candidate = next((path for path in candidates if path.is_file()), None)
                    if candidate and version.get('stdout', '').strip() == '9.6.7':
                        version = run('real-ghc-pkg-version', [candidate, '--version'], ROOT, required=False)
                        if version['exit_code'] == 0 and version.get('stdout', '').strip().endswith(' 9.6.7'):
                            real_ghc_pkg = candidate
                            run('real-ghc-pkg-rts', [candidate, '+RTS', '--info'], ROOT, required=False)
        else:
            report(label='ghcup-whereis', error='GHCup is not on PATH')

    # Keep only the helper build outside the required Japanese game destination.
    with tempfile.TemporaryDirectory(prefix='fp-path-launcher-') as helper_name:
        helper = Path(helper_name).resolve()
        for origin, executable in (('PATH', ghc_pkg), ('real', real_ghc_pkg), ('unversioned', alias_ghc_pkg)):
            if executable is None:
                continue
            for shape in ('ascii-only', 'ascii with spaces'):
                database = helper / (origin + '-' + shape)
                if not str(database).isascii() or (shape == 'ascii-only' and ' ' in str(database)):
                    report(label='control-unavailable', path=str(database),
                           reason='Temporary ancestor does not meet the ASCII control shape')
                    continue
                run(origin + '-control-' + shape, [executable, 'init', database], helper, required=False)
                report(label='control-package-db-files', path=str(database),
                       exists=database.is_dir(), cache_exists=(database / 'package.cache').is_file())
        source = helper / 'Main.hs'
        source.write_text(LAUNCHER, encoding='utf-8')
        launcher = helper / ('launcher.exe' if os.name == 'nt' else 'launcher')
        compiled = run('compile-boot-launcher',
                       [ghc, '-threaded', '-Wall', '-Werror', '-package', 'process',
                        '-package', 'bytestring', '-outputdir', helper, '-o', launcher, source], helper)
        run('boot-process-version', [ghc_pkg, 'field', 'process', 'version'], helper)
        original_routes = ('direct-cabal', 'retained-python', 'haskell-process')
        contrasts = ('direct-cabal-real-compiler', 'direct-cabal-real-tools',
                     'project-selected-real-tools') if real_ghc and real_ghc_pkg else ()
        for route in (*original_routes, *contrasts):
            required = route in original_routes
            with tempfile.TemporaryDirectory(prefix='FP native acceptance 日本語 ') as temporary:
                project = Path(temporary).resolve() / 'first independent game 日本語'
                project.mkdir()
                (project / 'app').mkdir()
                (project / 'src').mkdir()
                (project / 'src/PathMessage.hs').write_text(
                    'module PathMessage (message) where\nmessage :: String\nmessage = "path build ready"\n', encoding='utf-8')
                (project / 'app/Main.hs').write_text(
                    'import PathMessage (message)\nmain :: IO ()\nmain = putStrLn message\n', encoding='utf-8')
                (project / 'path-probe.cabal').write_text(
                    'cabal-version: 3.0\nname: path-probe\nversion: 0.1.0.0\nbuild-type: Simple\n'
                    'library\n  exposed-modules: PathMessage\n  hs-source-dirs: src\n'
                    '  build-depends: base\n  default-language: Haskell2010\n'
                    'executable path-probe\n  main-is: Main.hs\n  hs-source-dirs: app\n'
                    '  build-depends: base, path-probe\n'
                    '  default-language: Haskell2010\n', encoding='utf-8')
                (project / 'cabal.project').write_text(
                    'packages: .\nactive-repositories: :none\nif os(windows)\n'
                    '  package *\n    ar-options: --rsp-quoting=posix\n', encoding='utf-8')
                state = project / '.build'
                state.mkdir()
                config = state / 'cabal.config'
                contents = ('active-repositories: :none\nstore-dir: ' + (state / 'store').as_posix()
                            + '\nremote-repo-cache: ' + (state / 'package-cache').as_posix() + '\n')
                config.write_text(contents, encoding='utf-8', newline='\n')
                command = [cabal, f'--config-file={config}', 'build', 'all',
                           '--offline', f'--builddir={state / "dist"}']
                report(route=route, config=str(config), config_utf8=contents,
                       config_bytes_hex=config.read_bytes().hex())
                if route == 'retained-python':
                    command = [sys.executable, ROOT / 'tools/fp_game.py', 'build', '--project', project, '--json']
                elif route == 'haskell-process':
                    if compiled['exit_code']:
                        report(label=route, required=True, exit_code=1, error='Launcher compilation failed')
                        continue
                    command = [launcher, project, *command]
                elif route == 'direct-cabal-real-compiler':
                    command += [f'--with-compiler={real_ghc}']
                elif route == 'direct-cabal-real-tools':
                    command += [f'--with-compiler={real_ghc}', f'--with-hc-pkg={real_ghc_pkg}']
                elif route == 'project-selected-real-tools':
                    local = ('with-compiler: ' + real_ghc.as_posix() + '\n'
                             'with-hc-pkg: ' + real_ghc_pkg.as_posix() + '\n')
                    (project / 'cabal.project.local').write_text(local, encoding='utf-8', newline='\n')
                    report(route=route, project_local_utf8=local)
                result = run(route, command, project, required=required)
                binaries = list((state / 'dist').rglob('path-probe.exe' if os.name == 'nt' else 'path-probe'))
                binaries = [path for path in binaries if path.is_file()]
                package_db_exists = (state / 'dist/packagedb/ghc-9.6.7/package.cache').is_file()
                report(label=route + '-files', required=required,
                       exit_code=0 if binaries and package_db_exists and config.read_bytes() == contents.encode('utf-8') else 1,
                       executable_paths=list(map(str, binaries)),
                       package_db_exists=package_db_exists)
                if binaries:
                    run(route + '-executable', [binaries[0]], project, required=required)
                # Output encoding is a diagnostic comparison, never a passing fallback.
                if result['exit_code']:
                    run(route + '-utf8-diagnostic', command, project, required=False,
                        env={**os.environ, 'GHC_CHARENC': 'UTF-8'})
                if route == 'direct-cabal':
                    for spelling in ('native', 'forward'):
                        for encoding in ('inherited', 'UTF-8'):
                            database = project / f'package db 日本語 {spelling} {encoding}'
                            argument = str(database) if spelling == 'native' else database.as_posix()
                            run('ghc-pkg-init-' + spelling + '-' + encoding,
                                [ghc_pkg, 'init', argument], project,
                                env=None if encoding == 'inherited' else {**os.environ, 'GHC_CHARENC': encoding})
                            report(label='package-db-files', required=True,
                                   exit_code=0 if (database / 'package.cache').is_file() else 1,
                                   path=str(database), exists=database.is_dir())
                    for origin, executable in (('real', real_ghc_pkg), ('unversioned', alias_ghc_pkg)):
                        if executable is None:
                            continue
                        for encoding in ('inherited', 'UTF-8'):
                            database = project / f'{origin} compiler package db 日本語 {encoding}'
                            run(origin + '-ghc-pkg-init-' + encoding, [executable, 'init', database],
                                project, required=False,
                                env=None if encoding == 'inherited' else {**os.environ, 'GHC_CHARENC': encoding})
                            report(label=origin + '-package-db-files', path=str(database),
                                   exists=database.is_dir(), cache_exists=(database / 'package.cache').is_file())
    failures = [item['label'] for item in records if item.get('required') and item['exit_code'] != 0]
    report(status='fail' if failures else 'pass', failed_checks=failures)
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
