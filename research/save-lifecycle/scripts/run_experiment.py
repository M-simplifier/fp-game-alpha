#!/usr/bin/env python3
"""Isolated, fail-closed public reproduction of the frozen save lifecycle lab."""
import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
if sys.flags.optimize:
    raise RuntimeError('Python optimization mode is unsupported; evidence checks must stay enabled')
from bridge import FIELDS, emit_module, parse_haskell, parse_tlc, validate_row

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
JAR_SHA = '936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88'
JAR_URL = 'https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar'
SUCCESS = 'Model checking completed. No error has been found.'
PACKAGES = {'base': '4.18.3.0', 'array': '0.5.8.0', 'binary': '0.8.9.1',
            'bytestring': '0.11.5.4', 'containers': '0.6.7', 'deepseq': '1.4.8.1',
            'directory': '1.3.8.5', 'filepath': '1.4.301.0', 'mtl': '2.3.1',
            'parsec': '3.1.16.1', 'text': '2.0.2', 'unix': '2.8.6.0'}
MUTANTS = {'Epoch': 'NoStaleSaved', 'Active': 'UniqueResponse', 'Persist': 'NoFalseSuccess'}
CORPUS = ['branch-inflight', 'edit-inflight', 'failure-old-epoch', 'failure-retry',
          'happy-duplicate', 'load-inflight', 'load-late', 'reordered-responses']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, obj):
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + '\n')


def inputs():
    """Identity applies to all immutable payload and executable runner files."""
    paths = [p for folder in ('model', 'src', 'fixtures', 'vendor', 'scripts')
             for p in (ROOT / folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    paths += [ROOT / 'provenance.json']
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(paths)}


def verify_sources():
    manifest = json.loads((ROOT / 'provenance.json').read_text())
    require(len(manifest['files']) == 49, 'unexpected immutable input count')
    for record in manifest['files']:
        path = ROOT / record['relative_path']
        data = path.read_bytes()
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        require(len(data) == record['bytes'] and sha(path) == record['sha256']
                and blob == record['git_blob_sha1'], 'changed frozen input: ' + record['relative_path'])
    return len(manifest['files'])


def classify(code, text, expected=0, markers=(), timed_out=False, negative=False):
    """A nonzero exit alone is never evidence of a desired rejection."""
    if timed_out:
        return 'timeout'
    if re.search(r'\bunknown\b', text, re.I):
        return 'unknown'
    if code == 0 and expected != 0:
        return 'unexpected-acceptance'
    if code != expected or not all(marker in text for marker in markers):
        return 'tool-error'
    if not negative and re.search(r'(?m)^Error:|^Exception', text):
        return 'tool-error'
    if re.search(r'OutOfMemoryError|StackOverflowError|Exception in thread|Cannot find|Could not find', text):
        return 'tool-error'
    return 'expected-counterexample' if negative else 'passed-scoped'


def parse_counts(text):
    m = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', text)
    return dict(zip(('generated', 'distinct', 'queued'), [int(x.replace(',', '')) for x in m.groups()])) if m else None


def expected_runs():
    runs = {name: (0, (), False) for name in ['python-version', 'java-version', 'ghc-version', 'ghc-packages', 'build', 'freshness-build']}
    for name in ('safety', 'fair-liveness'):
        runs[name] = (0, (SUCCESS,), False)
    runs['unfair-liveness-control'] = (13, ('Temporal properties were violated.',), True)
    for mutant, invariant in MUTANTS.items():
        runs['mutant-' + mutant] = (12, ('Invariant ' + invariant + ' is violated.',), True)
        for prefix in ('replay-mutant-', 'replay-corrected-'):
            runs[prefix + mutant] = (0, (), False)
        runs['validate-mutant' + mutant] = (11, ('Error: Deadlock reached.',), True)
        if mutant != 'Persist':
            runs['validate-corrected' + mutant] = (0, (SUCCESS,), False)
    for name in CORPUS:
        runs['corpus-' + name] = (0, (), False)
        runs['validate-' + name] = (0, (SUCCESS,), False)
    runs['freshness-assumption'] = (0, ('("same-full-ticket-reused",True)',), False)
    runs['optimized-parser-negative'] = (1, ('Python optimization mode is unsupported',), True)
    runs['typed-reference-negative'] = (1, ('non-integer scalar epoch',), True)
    return runs


class Experiment:
    def __init__(self, run_dir):
        self.root = run_dir.resolve()
        require(self.root != ROOT and not self.root.is_relative_to(ROOT), 'RUN_DIR must be outside research/save-lifecycle')
        require(self.root != REPO, 'RUN_DIR must not be the repository root')
        self.jar = self.root / 'tools/tla2tools-v1.7.4.jar'
        self.work = self.root / 'work'
        self.build = self.root / 'build'
        self.logs = self.root / 'logs'
        self.runs = []
        self.tools = {key: os.environ.get(key, default) for key, default in
                      [('GHC', 'ghc'), ('GHC_PKG', 'ghc-pkg'), ('JAVA', 'java')]}
        self.tools['PYTHON'] = sys.executable
        self.replacements = [(str(self.root), '$RUN_DIR'), (str(ROOT), '$EXPERIMENT'), (str(REPO), '$REPO')]
        for key, value in self.tools.items():
            resolved = shutil.which(value)
            self.tools[key] = resolved or value
            if resolved:
                self.replacements.append((resolved, '$' + key))
        self.replacements.sort(key=lambda item: -len(item[0]))
        self.env = dict(os.environ, TZ='UTC', LC_ALL='C.UTF-8', PYTHONDONTWRITEBYTECODE='1',
                        GHC_ENVIRONMENT='-', JAVA_TOOL_OPTIONS='', JDK_JAVA_OPTIONS='', _JAVA_OPTIONS='')
        # Runtime temporary files and Java preferences also remain inside RUN_DIR.
        self.env.pop('GHC_PACKAGE_PATH', None)
        self.env.update(TMPDIR=str(self.root / 'tmp'), HOME=str(self.root / 'home'))

    def redact(self, text):
        for old, new in self.replacements:
            text = text.replace(old, new)
        return text

    def run(self, name, command, expected=0, markers=(), negative=False, cwd=None, timeout=180):
        command = [str(x) for x in command]
        log = self.logs / (name + '.log')
        start = now()
        tick = time.monotonic()
        timed_out = False
        with log.open('w') as output:
            process = subprocess.Popen(command, cwd=cwd or self.work, env=self.env,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGKILL)
                code = process.wait()
        text = self.redact(log.read_text(errors='replace'))
        log.write_text(text)
        status = classify(code, text, expected, markers, timed_out, negative)
        record = {'name': name, 'command': [self.redact(x) for x in command],
                  'cwd': self.redact(str(cwd or self.work)), 'start_utc': start,
                  'end_utc': now(), 'wall_seconds': round(time.monotonic() - tick, 6),
                  'timeout_seconds': timeout, 'timed_out': timed_out,
                  'exit_code': code, 'expected_exit_code': expected,
                  'status': status, 'expected_markers': list(markers),
                  'markers': {m: m in text for m in markers},
                  'log': log.relative_to(self.root).as_posix(), 'log_sha256': sha(log)}
        counts = parse_counts(text)
        if counts:
            record['tlc'] = counts
        self.runs.append(record)
        print(json.dumps({'name': name, 'status': status, 'exit': code}), flush=True)
        require(status in ('passed-scoped', 'expected-counterexample'), name + ': ' + status + '; inspect ' + record['log'])
        return log

    def tlc(self, name, config, module='SaveLifecycle', expected=0, markers=(SUCCESS,)):
        return self.run(name, [self.tools['JAVA'], '-Xmx512m', '-XX:+UseParallelGC',
                              '-Djava.io.tmpdir=' + str(self.root / 'tmp'), '-cp', self.jar,
                              'tlc2.TLC', '-workers', '1', '-seed', '1', '-fp', '0',
                              '-metadir', self.build / ('tlc-' + name),
                              '-config', config + '.cfg', module], expected, markers,
                        negative=expected != 0, cwd=self.work / 'model')

    def haskell(self, name, mode, events):
        storage = self.root / 'storage' / name
        storage.mkdir(parents=True)
        return self.run(name, [self.build / 'lifecycle', mode,
                              self.work / 'vendor/colony0.2/data/content-v1.json', events, storage])

    def validate(self, name, log, valid=True):
        module = 'Trace' + re.sub('[^A-Za-z0-9]', '', name)
        rows = parse_haskell(log)
        emit_module(rows, self.work / 'model' / (module + '.tla'))
        self.tlc('validate-' + name, module, module, 0 if valid else 11,
                 (SUCCESS,) if valid else ('Error: Deadlock reached.',))
        if valid:
            require(self.runs[-1].get('tlc', {}).get('distinct') == len(rows), 'trace state count mismatch: ' + name)
        return len(rows)

    def fetch(self):
        if self.jar.exists():
            require(sha(self.jar) == JAR_SHA, 'pinned TLC jar checksum mismatch; remove only the invalid jar to retry')
            return
        self.jar.parent.mkdir(parents=True, exist_ok=True)
        temp = self.jar.with_suffix('.download')
        try:
            with urllib.request.urlopen(JAR_URL, timeout=90) as response, temp.open('wb') as output:
                size = 0
                while block := response.read(65536):
                    size += len(block)
                    require(size <= 3000000, 'TLC download exceeds size limit')
                    output.write(block)
            require(sha(temp) == JAR_SHA, 'downloaded TLC jar checksum mismatch')
            temp.replace(self.jar)
        finally:
            if temp.exists():
                temp.unlink()

    def versions(self, record=False):
        for key, executable in self.tools.items():
            require(shutil.which(executable) is not None, f'prerequisite missing: {key} executable {executable!r}')
        commands = {'python-version': [self.tools['PYTHON'], '--version'],
                    'java-version': [self.tools['JAVA'], '-version'],
                    'ghc-version': [self.tools['GHC'], '--numeric-version'],
                    'ghc-packages': [self.tools['GHC_PKG'], '--global', '--no-user-package-db', 'list', '--simple-output']}
        texts = {}
        for name, command in commands.items():
            if record:
                texts[name] = self.run(name, command).read_text().strip()
            else:
                result = subprocess.run(command, capture_output=True, text=True, timeout=30)
                require(result.returncode == 0, 'prerequisite command failed: ' + name)
                texts[name] = self.redact(result.stdout + result.stderr).strip()
        require(os.name == 'posix', 'Linux/POSIX is required (native save uses unix)')
        require(sys.version_info >= (3, 10), 'Python >= 3.10 is required')
        require(texts['ghc-version'] == '9.6.7', 'public route requires GHC 9.6.7; historical run used 9.6.6')
        require(re.search(r'version "21(?:[.\"])', texts['java-version']), 'public route requires Java 21')
        package_set = texts['ghc-packages'].split()
        for name, version in PACKAGES.items():
            require(name + '-' + version in package_set, 'prerequisite package mismatch: ' + name + '-' + version)
        return texts

    def publish(self, evidence):
        # A failed final integrity check must never leave a green receipt behind.
        write_json(self.root / 'evidence.json', evidence)
        try:
            verify(self.root)
        except BaseException as error:
            evidence.update(status='tool-error', error=self.redact(str(error)), completed_utc=now())
            write_json(self.root / 'evidence.json', evidence)
            raise

    def execute(self):
        require(not any((self.root / p).exists() for p in ['evidence.json', 'work', 'build', 'logs']),
                'RUN_DIR already contains a run; choose a new directory (tools alone may be reused)')
        self.root.mkdir(parents=True, exist_ok=True)
        for path in (self.logs, self.build, self.root / 'tmp', self.root / 'home'):
            path.mkdir()
        evidence = {'schema': 'save-lifecycle-public-run-v1', 'status': 'unknown', 'started_utc': now(),
                    'historical_run': False, 'runs': self.runs}
        write_json(self.root / 'evidence.json', evidence)
        try:
            verify_sources()
            initial = inputs()
            # Prerequisites are checked before download/build/checker execution.
            self.work.mkdir()
            versions = self.versions(record=True)
            self.fetch()
            for folder in ('model', 'src', 'fixtures', 'vendor'):
                shutil.copytree(ROOT / folder, self.work / folder)
            compile_flags = ['-no-user-package-db', '-hide-all-packages']
            for name in PACKAGES:
                compile_flags += ['-package', name + '-' + PACKAGES[name]]
            compile_flags += ['-i' + str(self.work / 'vendor/colony0.2/src'), '-O1', '-Wall', '-Werror']
            self.run('build', [self.tools['GHC'], '-fforce-recomp', *compile_flags,
                              '-outputdir', self.build, 'src/Main.hs', '-o', self.build / 'lifecycle'])
            self.tlc('safety', 'Correct')
            require(self.runs[-1].get('tlc') == {'generated': 583932, 'distinct': 79227, 'queued': 0}, 'safety state-space count changed')
            self.tlc('fair-liveness', 'Fair')
            self.tlc('unfair-liveness-control', 'Unfair', expected=13, markers=('Temporal properties were violated.',))
            bridges = []
            for mutant, invariant in MUTANTS.items():
                log = self.tlc('mutant-' + mutant, 'Mutant' + mutant, expected=12,
                               markers=('Invariant ' + invariant + ' is violated.',))
                rows = parse_tlc(log)
                prefix = self.work / 'fixtures' / ('generated-mutant-' + mutant.lower())
                write_json(prefix.with_suffix('.json'), rows)
                events = prefix.with_suffix('.events')
                events.write_text(''.join(f"{r['event']} {r['request']}\n" for r in rows[1:]))
                # Deterministic settings must reproduce the supplied historical counterexample.
                reference = [validate_row(x) for x in json.loads((self.work / 'fixtures' / ('mutant-' + mutant.lower() + '.json')).read_text())]
                require(rows == reference, 'generated counterexample differs from frozen fixture: ' + mutant)
                actual = self.haskell('replay-mutant-' + mutant, mutant + 'Mutant', events)
                require(rows == parse_haskell(actual), 'TLC/Haskell 13-field mismatch: ' + mutant)
                corrected = self.haskell('replay-corrected-' + mutant, 'Correct', events)
                require(parse_haskell(corrected)[-1]['accepted'] != rows[-1]['accepted'], 'corrected callback accepted mutant: ' + mutant)
                if mutant != 'Persist':
                    self.validate('corrected' + mutant, corrected)
                self.validate('mutant' + mutant, actual, False)
                bridges.append({'mutation': mutant, 'states': len(rows), 'fields_per_state': len(FIELDS),
                                'all_fields_equal': True, 'matches_frozen_counterexample': True,
                                'corrected_trace_checked_by_tlc': mutant != 'Persist',
                                'invalid_mutant_trace_rejected': True})
            corpus = []
            for name in CORPUS:
                log = self.haskell('corpus-' + name, 'Correct', self.work / 'fixtures' / (name + '.events'))
                corpus.append({'name': name, 'states': self.validate(name, log)})
            require(sum(row['states'] for row in corpus) == 78, 'corpus state total changed')
            (self.build / 'freshness').mkdir()
            self.run('freshness-build', [self.tools['GHC'], *compile_flags, '-outputdir', self.build / 'freshness',
                                        'src/TicketFreshness.hs', '-o', self.build / 'ticket-freshness'])
            self.run('freshness-assumption', [self.build / 'ticket-freshness'], markers=('("same-full-ticket-reused",True)',))
            bad = self.logs / 'parser-missing-field.log'
            bad.write_text('STATE {"event":"Init"}\n')
            expect_parser_rejection(bad)
            self.run('optimized-parser-negative', [self.tools['PYTHON'], '-O', ROOT / 'scripts/bridge.py', 'compare',
                                                   self.work / 'fixtures/mutant-epoch.json', self.logs / 'replay-mutant-Epoch.log'],
                     1, ('Python optimization mode is unsupported',), negative=True)
            row = parse_haskell(self.logs / 'corpus-load-late.log')[0]
            row['epoch'] = True
            bad_bool = self.logs / 'parser-bool-as-int.log'
            bad_bool.write_text('STATE ' + json.dumps(row) + '\n')
            expect_parser_rejection(bad_bool)
            refs = json.loads((self.work / 'fixtures/mutant-epoch.json').read_text())
            refs[-1]['epoch'] = True
            bad_ref = self.logs / 'parser-bad-reference.json'
            write_json(bad_ref, refs)
            self.run('typed-reference-negative', [self.tools['PYTHON'], ROOT / 'scripts/bridge.py', 'compare',
                                                  bad_ref, self.logs / 'replay-mutant-Epoch.log'],
                     1, ('non-integer scalar epoch',), negative=True)
            require(inputs() == initial, 'read-only laboratory input changed during run')
            artifacts = {p.relative_to(self.root).as_posix(): sha(p)
                         for p in sorted(self.work.rglob('*')) if p.is_file()}
            evidence.update(status='passed-scoped', completed_utc=now(), versions=versions,
                            input_sha256=initial, artifact_sha256=artifacts,
                            source_unchanged=True, tools={'tlc_release': 'v1.7.4', 'tlc_version': '2.19',
                            'jar_sha256': JAR_SHA, 'jar_bytes': self.jar.stat().st_size, 'jar_url': JAR_URL,
                            'heap_limit_mib': 512, 'workers': 1, 'seed': 1, 'fingerprint_polynomial': 0},
                            finite_scope={'epochs': 2, 'request_ids_per_epoch': 2, 'edits_per_epoch': 1,
                                          'active_requests_per_epoch': 1, 'fresh_ticket_required': True},
                            counterexample_bridges=bridges, corpus=corpus,
                            parser_missing_field_rejected=True, parser_boolean_integer_rejected=True,
                            limits=['Finite model exploration and finite traces, not universal refinement',
                                    'Frozen Colony 0.2, one serialized laboratory caller',
                                    'Persist mutant rejected by caller gate, not core storage-phase check',
                                    'Fairness permits terminal failure; no successful-save or latency guarantee',
                                    'Fresh complete ticket identity required; identical-ticket reuse is unsafe',
                                    'No shared writer, process/power crash, reconnect, UI or browser guarantees'])
        except BaseException as exc:
            evidence.update(status='tool-error', error=self.redact(str(exc)), completed_utc=now())
            write_json(self.root / 'evidence.json', evidence)
            raise
        self.publish(evidence)
        print('LAB passed-scoped (new public GHC 9.6.7 route)', flush=True)


def expect_parser_rejection(path):
    try:
        parse_haskell(path)
    except (ValueError, AssertionError):
        return
    raise RuntimeError('parser accepted malformed trace: ' + path.name)


def verify(run_dir):
    """Bind named semantic outcomes to complete logs and current input bytes."""
    verify_sources()
    evidence = json.loads((run_dir / 'evidence.json').read_text())
    require(evidence['schema'] == 'save-lifecycle-public-run-v1' and evidence['status'] == 'passed-scoped', 'run did not pass')
    require(evidence.get('historical_run') is False and evidence.get('source_unchanged') is True, 'incorrect run identity')
    require(evidence['finite_scope'] == {'epochs': 2, 'request_ids_per_epoch': 2, 'edits_per_epoch': 1,
                                        'active_requests_per_epoch': 1, 'fresh_ticket_required': True}, 'incorrect finite scope')
    require(evidence['input_sha256'] == inputs(), 'changed laboratory input or runner')
    jar = run_dir / 'tools/tla2tools-v1.7.4.jar'
    require(sha(jar) == JAR_SHA, 'changed TLC jar')
    require(evidence['tools'] == {'tlc_release': 'v1.7.4', 'tlc_version': '2.19', 'jar_sha256': JAR_SHA,
                                  'jar_bytes': jar.stat().st_size, 'jar_url': JAR_URL, 'heap_limit_mib': 512,
                                  'workers': 1, 'seed': 1, 'fingerprint_polynomial': 0}, 'incorrect TLC tool metadata')
    expected = expected_runs()
    runs = evidence['runs']
    require(len(runs) == len(expected) and {r['name'] for r in runs} == set(expected), 'incomplete or duplicate named runs')
    for record in runs:
        code, markers, negative = expected[record['name']]
        require(record['log'] == 'logs/' + record['name'] + '.log', 'unexpected log path')
        log = run_dir / record['log']
        require(log.resolve().is_relative_to(run_dir.resolve()), 'log path escapes run')
        require(record['expected_exit_code'] == code and record['expected_markers'] == list(markers), 'changed expected result metadata')
        require(record['markers'] == {marker: True for marker in markers}, 'missing semantic marker metadata')
        require(sha(log) == record['log_sha256'], 'changed log: ' + record['name'])
        text = log.read_text()
        outcome = classify(record['exit_code'], text, code, markers, record['timed_out'], negative)
        require(outcome == record['status'] and outcome in ('passed-scoped', 'expected-counterexample'), 'invalid outcome: ' + record['name'])
        if 'tlc' in record:
            require(record['tlc'] == parse_counts(text), 'changed TLC counts')
    versions = {name: (run_dir / 'logs' / (name + '.log')).read_text().strip()
                for name in ('python-version', 'java-version', 'ghc-version', 'ghc-packages')}
    require(evidence['versions'] == versions, 'version metadata differs from logs')
    require(versions['ghc-version'] == '9.6.7' and re.search(r'version "21(?:[.\"])', versions['java-version']), 'unsupported tool versions')
    require(all(name + '-' + version in versions['ghc-packages'].split() for name, version in PACKAGES.items()), 'unsupported package set')
    safety = next(r for r in runs if r['name'] == 'safety')
    require(safety['tlc'] == {'generated': 583932, 'distinct': 79227, 'queued': 0}, 'wrong safety state counts')
    actual_artifacts = {p.relative_to(run_dir).as_posix(): sha(p)
                        for p in sorted((run_dir / 'work').rglob('*')) if p.is_file()}
    require(actual_artifacts == evidence['artifact_sha256'], 'changed generated/copied artifact set')
    for record in json.loads((ROOT / 'provenance.json').read_text())['files']:
        path = record['relative_path']
        if not path.startswith('scripts/'):
            require(sha(run_dir / 'work' / path) == record['sha256'], 'changed frozen run input: ' + path)
    bridges = []
    for mutant in MUTANTS:
        tlc_rows = parse_tlc(run_dir / 'logs' / ('mutant-' + mutant + '.log'))
        haskell_rows = parse_haskell(run_dir / 'logs' / ('replay-mutant-' + mutant + '.log'))
        require(tlc_rows == haskell_rows, 'invalid 13-field bridge: ' + mutant)
        reference = json.loads((ROOT / 'fixtures' / ('mutant-' + mutant.lower() + '.json')).read_text())
        require(tlc_rows == reference, 'frozen mutant mismatch')
        corrected = parse_haskell(run_dir / 'logs' / ('replay-corrected-' + mutant + '.log'))
        require(corrected[-1]['accepted'] != tlc_rows[-1]['accepted'], 'corrected callback mismatch')
        bridges.append({'mutation': mutant, 'states': len(tlc_rows), 'fields_per_state': 13, 'all_fields_equal': True,
                        'matches_frozen_counterexample': True, 'corrected_trace_checked_by_tlc': mutant != 'Persist',
                        'invalid_mutant_trace_rejected': True})
    require(evidence['counterexample_bridges'] == bridges, 'incorrect bridge metadata')
    corpus = []
    for name in CORPUS:
        count = len(parse_haskell(run_dir / 'logs' / ('corpus-' + name + '.log')))
        result = next(r for r in runs if r['name'] == 'validate-' + name)
        require(result['tlc']['distinct'] == count, 'corpus TLC/state count mismatch: ' + name)
        corpus.append({'name': name, 'states': count})
    require(corpus == evidence['corpus'] and sum(r['states'] for r in corpus) == 78, 'incorrect corpus total')
    expect_parser_rejection(run_dir / 'logs/parser-missing-field.log')
    expect_parser_rejection(run_dir / 'logs/parser-bool-as-int.log')
    print(json.dumps({'verification': 'passed-scoped', 'named_runs': len(runs), 'frozen_inputs': 49, 'corpus_states': 78}), flush=True)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['doctor', 'fetch', 'check', 'verify', 'self-test'], nargs='?', default='check')
    parser.add_argument('--run-dir', type=pathlib.Path, default=pathlib.Path(os.environ.get('RUN_DIR', str(REPO / '.build/save-lifecycle'))))
    args = parser.parse_args()
    if args.command == 'self-test':
        import unittest
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'scripts'), 'test_runner.py')
        raise SystemExit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
    if args.command == 'verify':
        verify(args.run_dir.resolve())
    else:
        experiment = Experiment(args.run_dir)
        if args.command == 'doctor':
            print(json.dumps({'frozen_inputs': verify_sources(), 'versions': experiment.versions(),
                              'tlc_jar': 'verified' if experiment.jar.exists() and sha(experiment.jar) == JAR_SHA else 'not present or invalid'}, indent=2))
        elif args.command == 'fetch':
            experiment.fetch()
            print('TLC v1.7.4 SHA-256 verified')
        else:
            experiment.execute()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
