#!/usr/bin/env python3
"""Reproduce the recovered SBV experiment, with isolated tools and fail-closed receipts."""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
EXPECTED = {
    'integer_bounds_general': 'unsat',
    'integer_conservation_general': 'unsat',
    'eight_slot_partition_general': 'unsat',
    'integer_monotonicity_general': 'unsat',
    'integer_bounds_bounded': 'unsat',
    'integer_monotonicity_bounded': 'unsat',
    'legacy_eight_lots_counterexample': 'sat',
    'negative_missing_progress_upper_bound': 'sat',
    'word64_overflow_separate_counterexample': 'sat',
}
PINS = {'ghc': '9.6.7', 'cabal': '3.12.1.0', 'z3': '4.15.1'}
PROFILES = {'public': PINS,
            'historical': {'ghc': '9.6.6', 'cabal': '3.16.1.0', 'z3': '4.15.1'}}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_results(actual):
    ensure(type(actual) is dict and actual == EXPECTED,
           'Named solver result map differs: UNKNOWN/error/missing/additional or wrong verdict is not proof: ' + repr(actual))


def check_replay(text):
    required = ['ARITHMETIC_PASS positive-required inputs=36400 assertions=109200; zero-required inputs=2145 assertions=2145',
                'TRANSACTION_PASS 128 Parts8 positive ordered compositions x11 progress points=1408 aggregate transactions; plus4 baseline transactions=1412',
                'ASSERTIONS_TOTAL 127011', 'COUNTEREXAMPLE_PASS', 'REPLAY_PASS']
    ensure(all(marker in text for marker in required), 'Missing direct-source replay markers')
    ensure(len(re.findall(r'^CASE ', text, re.M)) == 1412, 'Wrong transaction count')


def verify_inputs():
    provenance = json.loads((ROOT / 'provenance.json').read_text())
    for name, entry in provenance['files'].items():
        ensure(sha(ROOT / name) == entry['sha256'], 'Changed historical input: ' + name)
    names = set(provenance['files']) | {'run.py', 'provenance.json', 'cabal.project', 'metadata/toolchains.json'}
    return {name: sha(ROOT / name) for name in sorted(names)}


def executable(name):
    value = os.environ.get(name.upper(), name)
    result = shutil.which(value)
    ensure(result is not None, 'Missing prerequisite ' + name.upper() + ': ' + value)
    return str(Path(result).absolute())


class Run:
    def __init__(self, path, mode, profile):
        self.path = path.resolve()
        self.tool_paths = {}
        ensure(not self.path.exists() or not any(self.path.iterdir()), 'RUN_DIR must be empty; use a new directory: ' + str(self.path))
        self.path.mkdir(parents=True, exist_ok=True)
        (self.path / 'logs').mkdir()
        self.receipt = {'schema': 'sbv-public-reproduction-v1', 'mode': mode, 'profile': profile,
                        'status': 'in-progress', 'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        'input_sha256': verify_inputs(), 'commands': [], 'limits': [
                            'Arithmetic theorem concerns SInteger, not machine integer overflow.',
                            'Finite imported-source bridge is not universal refinement of the Haskell program.',
                            'Fixtures set progress directly and provide ample return capacity; no scheduler, FEFO, UI or save guarantee.',
                            'A SAT negative control is an expected counterexample, not a safe-program verdict.',
                            'SMT replay uses the same solver, not an independent proof certificate.']}
        for folder in ('home', 'tmp'):
            (self.path / folder).mkdir()
        self.env = dict(os.environ, GHC_ENVIRONMENT='-', LC_ALL='C', TZ='UTC',
                        HOME=str(self.path / 'home'), TMPDIR=str(self.path / 'tmp'),
                        TEMP=str(self.path / 'tmp'), TMP=str(self.path / 'tmp'))
        for key in ('GHC_PACKAGE_PATH', 'SBV_Z3_OPTIONS'):
            self.env.pop(key, None)
        self.save()

    def redact(self, value):
        if isinstance(value, str):
            for path, label in [(str(self.path), '<RUN_DIR>'), (str(ROOT), '<SOURCE_DIR>'), (str(Path.home()), '<HOME>')]:
                value = value.replace(path, label)
            # Command executable absolute paths are represented by their versioned role.
            for path, name in sorted(self.tool_paths.items(), key=lambda item: len(item[0]), reverse=True):
                value = value.replace(path, '<' + name + '>')
            for name in ('GHC', 'CABAL', 'Z3', 'GHC_PKG'):
                candidate = os.environ.get(name)
                if candidate:
                    value = value.replace(candidate, '<' + name + '>')
            return value
        if isinstance(value, list): return [self.redact(v) for v in value]
        if isinstance(value, dict): return {k: self.redact(v) for k, v in value.items()}
        return value

    def save(self):
        (self.path / 'receipt.json').write_text(json.dumps(self.redact(self.receipt), indent=2) + '\n')

    def command(self, name, args, cwd=None, timeout=180):
        log = self.path / 'logs' / (name + '.log')
        start = time.monotonic()
        timed_out = False
        with log.open('w') as output:
            child = subprocess.Popen(list(map(str, args)), cwd=cwd or self.path, env=self.env,
                                     stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=(os.name == 'posix'))
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                if os.name == 'posix': os.killpg(child.pid, signal.SIGKILL)
                else: child.kill()
                code = child.wait()
        record = {'name': name, 'arguments': list(map(str, args)), 'cwd': str(cwd or self.path),
                  'timeout_seconds': timeout, 'elapsed_seconds': round(time.monotonic() - start, 3),
                  'exit_code': code, 'timed_out': timed_out, 'log': str(log.relative_to(self.path)),
                  'log_sha256': sha(log), 'status': 'timeout' if timed_out else 'passed' if code == 0 else 'tool-error'}
        self.receipt['commands'].append(record)
        self.save()
        ensure(not timed_out and code == 0, name + (' timed out' if timed_out else ' failed with exit ' + str(code)))
        return log.read_text()

    def doctor(self, solver=False):
        tools = {'ghc': executable('ghc')}
        self.tool_paths[tools['ghc']] = 'GHC'
        wanted = PROFILES[self.receipt['profile']]
        version = self.command('ghc-version', [tools['ghc'], '--numeric-version']).strip()
        ensure(version == wanted['ghc'], 'GHC version must equal ' + wanted['ghc'] + ', got ' + version)
        self.receipt['versions'] = {'ghc': version, 'python': sys.version.split()[0]}
        ghc_pkg = executable('ghc_pkg') if os.environ.get('GHC_PKG') else str(Path(tools['ghc']).with_name('ghc-pkg'))
        self.tool_paths[ghc_pkg] = 'GHC_PKG'
        packages = self.command('ghc-packages', [ghc_pkg, 'list', '--global', '--simple-output']).split()
        pins = json.loads((ROOT / 'metadata/toolchains.json').read_text())[self.receipt['profile']]['boot_packages']
        ensure(set(pins).issubset(packages), 'GHC boot package set does not match pinned profile')
        self.receipt['boot_packages'] = sorted(packages)
        if solver:
            for name, flag in [('cabal', '--numeric-version'), ('z3', '--version')]:
                tools[name] = executable(name)
                self.tool_paths[tools[name]] = name.upper()
                text = self.command(name + '-version', [tools[name], flag]).strip()
                match = re.search(r'\b\d+(?:\.\d+){2,3}\b', text)
                ensure(match is not None and match[0] == wanted[name], name + ' version must equal ' + wanted[name] + ', got ' + text)
                self.receipt['versions'][name] = match[0]
            self.env['SBV_Z3'] = tools['z3']
        self.receipt['tool_executable_sha256'] = {name: sha(Path(path)) for path, name in self.tool_paths.items()}
        self.save()
        return tools

    def workspace(self):
        work = self.path / 'work'
        work.mkdir()
        for folder in ('source', 'frozen-0.4', 'metadata'):
            shutil.copytree(ROOT / folder, work / folder)
        for name in ('sbv-cancellation-lab.cabal', 'cabal.project'):
            shutil.copy2(ROOT / name, work / name)
        (work / 'logs').mkdir()
        (work / 'build').mkdir()
        return work

    def dependencies(self, work):
        lock = json.loads((ROOT / 'metadata/dependency-lock.json').read_text())
        downloads, vendor = self.path / 'downloads', work / 'vendor'
        downloads.mkdir(); vendor.mkdir()
        self.receipt['dependencies'] = []
        for package in lock['packages']:
            filename = package['name'] + '-' + package['version'] + '.tar.gz'
            archive = downloads / filename
            cache = os.environ.get('SBV_DOWNLOAD_CACHE')
            if cache and (Path(cache) / filename).is_file():
                shutil.copy2(Path(cache) / filename, archive)
            else:
                with urllib.request.urlopen(package['url'], timeout=120) as response:
                    archive.write_bytes(response.read())
            ensure(archive.stat().st_size == package['bytes'] and sha(archive) == package['sha256'], 'Dependency hash/size mismatch: ' + filename)
            with tarfile.open(archive) as tar:
                tar.extractall(vendor, filter='data')
            self.receipt['dependencies'].append(package)
            self.save()

    def replay(self, tools, work):
        binary = work / 'build/replay'
        self.command('replay-build', [tools['ghc'], '-no-user-package-db', '--make', '-fforce-recomp', '-O0', '-Wall', '-Werror', '-XGHC2021',
            '-ifrozen-0.4/src', '-isource', '-outputdir', 'build/replay-obj', 'source/Replay.hs', '-o', binary], cwd=work)
        output = self.command('replay', [binary, 'frozen-0.4/data/content-v1.json'], cwd=work)
        check_replay(output)
        self.receipt['direct_source_replay'] = {'transactions': 1412, 'assertions': 127011,
                                              'positive_required_inputs': 36400, 'zero_required_helper_only_inputs': 2145}

    def prove(self, tools, work):
        self.dependencies(work)
        cabal_dir = self.path / 'cabal-home'; cabal_dir.mkdir()
        self.env['CABAL_DIR'] = str(cabal_dir)
        config = cabal_dir / 'config'
        config.write_text('remote-repo-cache: ' + str(cabal_dir / 'packages') + '\nstore-dir: ' + str(cabal_dir / 'store') + '\nlogs-dir: ' + str(cabal_dir / 'logs') + '\nactive-repositories: :none\n')
        self.env['CABAL_CONFIG'] = str(config)
        cabal = [tools['cabal'], '--config-file=' + str(config)]
        self.command('proof-build', [*cabal, 'v2-build', '--offline', '--with-compiler=' + tools['ghc'], 'exe:prove-cancellation'], cwd=work, timeout=1200)
        binary = self.command('proof-binary', [*cabal, 'list-bin', 'exe:prove-cancellation'], cwd=work).strip()
        try:
            self.command('proof', [binary], cwd=work, timeout=240)
        finally:
            result_path = work / 'metadata/proof-results.json'
            if result_path.is_file():
                self.receipt['solver_results'] = json.loads(result_path.read_text())
                self.save()
        results = json.loads(result_path.read_text())
        self.receipt['solver_results'] = results
        self.save()
        check_results(results)
        ensure('36400 inputs' in (work / 'logs/sbv-core-bridge.txt').read_text(), 'Missing 36,400-input SBV/core bridge')
        ensure('(8,60000,120000,[1,1,1,1,1,1,1,1],0,4,0,4)' in (work / 'logs/solver-witness-core-replay.txt').read_text(), 'Missing extracted SAT witness replay')
        self.receipt['smt_replays'] = {}
        for name, wanted in EXPECTED.items():
            output = self.command('smt-' + name, [tools['z3'], str(work / 'logs/smt' / (name + '.smt2'))], timeout=45)
            verdicts = re.findall(r'^(sat|unsat|unknown)$', output, re.M)
            ensure(verdicts == [wanted] and '(error ' not in output, 'SMT replay is not the expected verdict: ' + name)
            self.receipt['smt_replays'][name] = wanted
        self.receipt['sbv_helper_bridge_inputs'] = 36400
        self.receipt['solver_extracted_witness_replayed'] = True
        plan = work / 'dist-newstyle/cache/plan.json'
        ensure(plan.is_file(), 'Missing Cabal build plan')
        self.receipt['build_plan_sha256'] = sha(plan)
        self.receipt['package_versions'] = sorted({p['pkg-name'] + '-' + p['pkg-version'] for p in json.loads(plan.read_text())['install-plan']})
        wanted_packages = json.loads((ROOT / 'metadata/toolchains.json').read_text())[self.receipt['profile']]['plan_packages']
        ensure(self.receipt['package_versions'] == wanted_packages, 'Cabal plan differs from pinned package set')
        self.receipt['proof_artifacts'] = {str(p.relative_to(work)): sha(p) for folder in ['metadata', 'logs'] for p in sorted((work / folder).rglob('*')) if p.is_file()}


def verify_receipt(path):
    receipt = json.loads((path / 'receipt.json').read_text())
    ensure(receipt.get('schema') == 'sbv-public-reproduction-v1', 'Unsupported receipt schema')
    ensure(receipt.get('mode') in ('doctor', 'replay', 'check'), 'Invalid receipt mode')
    ensure(receipt.get('profile') in PROFILES, 'Invalid receipt profile')
    claims = {'doctor': 'prerequisites-only', 'replay': 'finite-direct-source-replay-only',
              'check': 'six-SInteger-UNSAT-three-SAT-controls-and-finite-source-bridge'}
    ensure(receipt.get('claim') == claims[receipt['mode']], 'Claim does not match executed mode')
    ensure(receipt['status'] == 'passed-scoped', 'Receipt did not pass')
    ensure(receipt['input_sha256'] == verify_inputs(), 'Receipt input identity differs from current source')
    mode = receipt['mode']
    names = ['ghc-version', 'ghc-packages']
    if mode != 'replay': names += ['cabal-version', 'z3-version']
    if mode == 'check': names += ['proof-build', 'proof-binary', 'proof', *['smt-' + name for name in EXPECTED]]
    if mode != 'doctor': names += ['replay-build', 'replay']
    ensure([r['name'] for r in receipt['commands']] == names, 'Missing, duplicate or unexpected command records')
    for command in receipt['commands']:
        ensure(command['exit_code'] == 0 and command['timed_out'] is False and command['status'] == 'passed', 'Unsuccessful command')
        log = path / command['log']
        ensure(log.resolve().is_relative_to(path.resolve()), 'Log path escapes receipt directory')
        ensure(sha(log) == command['log_sha256'], 'Changed log: ' + command['name'])
    versions = receipt['versions']
    pins = PROFILES[receipt['profile']]
    ensure((path / 'logs/ghc-version.log').read_text().strip() == versions['ghc'] == pins['ghc'], 'GHC version mismatch')
    for name in ('cabal', 'z3') if mode != 'replay' else ():
        observed = re.search(r'\b\d+(?:\.\d+){2,3}\b', (path / 'logs' / (name + '-version.log')).read_text())
        ensure(observed is not None and observed[0] == versions[name] == pins[name], 'Tool version mismatch: ' + name)
    boot = sorted((path / 'logs/ghc-packages.log').read_text().split())
    locked = json.loads((ROOT / 'metadata/toolchains.json').read_text())[receipt['profile']]
    ensure(boot == receipt['boot_packages'] and set(locked['boot_packages']).issubset(boot), 'Boot package metadata mismatch')
    if mode != 'doctor':
        check_replay((path / 'logs/replay.log').read_text())
        provenance = json.loads((ROOT / 'provenance.json').read_text())['files']
        for name, entry in provenance.items():
            ensure(sha(path / 'work' / name) == entry['sha256'], 'Changed copied historical input: ' + name)
    if mode == 'check':
        check_results(receipt['solver_results'])
        check_results(json.loads((path / 'work/metadata/proof-results.json').read_text()))
        ensure(receipt['smt_replays'] == EXPECTED, 'Wrong replay verdict map')
        for name, wanted in EXPECTED.items():
            text = (path / 'logs' / ('smt-' + name + '.log')).read_text()
            ensure(re.findall(r'^(sat|unsat|unknown)$', text, re.M) == [wanted] and '(error ' not in text, 'SMT replay log contradicts verdict: ' + name)
        bridge = (path / 'work/logs/sbv-core-bridge.txt').read_text()
        witness = (path / 'work/logs/solver-witness-core-replay.txt').read_text()
        ensure('36400 inputs' in bridge and receipt['sbv_helper_bridge_inputs'] == 36400, 'Helper bridge evidence mismatch')
        ensure('(8,60000,120000,[1,1,1,1,1,1,1,1],0,4,0,4)' in witness and receipt['solver_extracted_witness_replayed'] is True, 'Extracted witness evidence mismatch')
        plan = path / 'work/dist-newstyle/cache/plan.json'
        ensure(sha(plan) == receipt['build_plan_sha256'], 'Changed Cabal build plan')
        plan_packages = sorted({p['pkg-name'] + '-' + p['pkg-version'] for p in json.loads(plan.read_text())['install-plan']})
        ensure(plan_packages == receipt['package_versions'] == locked['plan_packages'], 'Pinned package-plan metadata mismatch')
        for name, digest in receipt['proof_artifacts'].items():
            target = path / 'work' / name
            ensure(target.resolve().is_relative_to((path / 'work').resolve()), 'Artifact path escapes run')
            ensure(sha(target) == digest, 'Changed proof artifact: ' + name)
    print('RECEIPT_VERIFIED ' + receipt['claim'])


def self_test():
    check_results(dict(EXPECTED))
    cases = []
    for value in ['unknown', 'error', 'sat', None, True]:
        changed = dict(EXPECTED); changed['integer_bounds_general'] = value; cases.append(changed)
    changed = dict(EXPECTED); del changed['integer_monotonicity_general']; cases.append(changed)
    changed = dict(EXPECTED); changed['extra'] = 'unsat'; cases.append(changed)
    for changed in cases:
        try: check_results(changed)
        except RuntimeError: pass
        else: raise RuntimeError('Gate accepted invalid map')
    for text in ['', 'ASSERTIONS_TOTAL 127011\nREPLAY_PASS', 'unknown']:
        try: check_replay(text)
        except RuntimeError: pass
        else: raise RuntimeError('Replay gate accepted incomplete output')
    verify_inputs()
    print('SELF_TEST_PASS: exact inputs; 7 solver-map falsifications; 3 incomplete replay falsifications')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['doctor', 'check', 'replay', 'self-test', 'verify'])
    parser.add_argument('--run-dir', default=os.environ.get('RUN_DIR'))
    parser.add_argument('--profile', choices=PROFILES, default='public')
    args = parser.parse_args()
    if args.command == 'self-test': self_test(); return
    ensure(args.run_dir is not None, 'Pass --run-dir or RUN_DIR; each run needs a fresh directory')
    if args.command == 'verify': verify_receipt(Path(args.run_dir).resolve()); return
    ensure(sys.version_info >= (3, 12), 'Python 3.12+ required for safe archive extraction')
    ensure(os.name == 'posix', 'Current optional solver runner is validated for POSIX; default game/quantity checks remain separate')
    run = Run(Path(args.run_dir), args.command, args.profile)
    try:
        tools = run.doctor(solver=args.command != 'replay')
        if args.command != 'doctor':
            work = run.workspace()
            if args.command == 'check': run.prove(tools, work)
            run.replay(tools, work)
        if args.command != 'doctor':
            provenance = json.loads((ROOT / 'provenance.json').read_text())['files']
            for name, entry in provenance.items():
                ensure(sha(work / name) == entry['sha256'], 'Copied historical input changed during execution: ' + name)
        ensure(verify_inputs() == run.receipt['input_sha256'], 'Included source changed during execution')
        run.receipt['status'] = 'passed-scoped'
        run.receipt['claim'] = 'prerequisites-only' if args.command == 'doctor' else 'finite-direct-source-replay-only' if args.command == 'replay' else 'six-SInteger-UNSAT-three-SAT-controls-and-finite-source-bridge'
    except Exception as exc:
        run.receipt['status'] = 'blocked-or-failed'
        run.receipt['error'] = str(exc)
        run.save()
        raise
    run.save()
    print(json.dumps({'status': run.receipt['status'], 'claim': run.receipt['claim'], 'receipt': str(run.path / 'receipt.json')}))


if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        sys.exit(1)
