"""Play Station through its Haskell Arena; Python owns transport, never rules."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAX_ATTEMPTS = 256
MAX_JOURNAL_BYTES = 4_000_000


def source_fingerprint():
    paths = [ROOT / 'references/station/app/HeadlessMain.hs']
    for folder in ['references/station/src', 'libraries/game-arena/src', 'libraries/game-transition/src']:
        paths.extend(sorted((ROOT / folder).rglob('*.hs')))
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b'\0' + path.read_bytes().replace(b'\r\n', b'\n') + b'\0')
    return digest.hexdigest()


def executable(fingerprint):
    output = ROOT / '.build' / 'headless' / fingerprint
    binary = output / ('station-headless.exe' if os.name == 'nt' else 'station-headless')
    if binary.is_file():
        return binary
    ghc = shutil.which('ghc')
    if not ghc:
        raise ValueError('GHC is required. Run python tools/fp_game.py doctor.')
    output.mkdir(parents=True, exist_ok=True)
    command = [ghc, '-O1', '-XGHC2021', '-Wall', '-Werror', '-outputdir', str(output),
               '-i' + str(ROOT / 'references/station/src'),
               '-i' + str(ROOT / 'libraries/game-arena/src'),
               '-i' + str(ROOT / 'libraries/game-transition/src'),
               str(ROOT / 'references/station/app/HeadlessMain.hs'), '-o', str(binary)]
    compiled = subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=180)
    if compiled.returncode:
        raise ValueError(compiled.stdout + compiled.stderr)
    return binary


def replay(session):
    fingerprint = source_fingerprint()
    if session['source_fingerprint'] != fingerprint:
        raise ValueError('Game source changed; preserve this journal and start a new session.')
    events = session['events']
    if len(events) > MAX_ATTEMPTS:
        raise ValueError('Episode attempt budget exceeded.')
    commands = []
    for event in events:
        if (type(event['turn']) is not int or event['choice'] not in ['express', 'local', 'defer']):
            raise ValueError('Invalid journal action.')
        commands.append(f"act {event['turn']} {event['choice']}")
    run = subprocess.run([str(executable(fingerprint))], input='\n'.join(commands) + ('\n' if commands else ''),
                         capture_output=True, text=True, encoding='utf-8', errors='strict', timeout=30)
    if run.returncode:
        raise ValueError('Haskell player process failed: ' + run.stderr)
    packets = [json.loads(line) for line in run.stdout.splitlines()]
    if len(packets) != len(events) + 1:
        raise ValueError('Player response count differs from request count.')
    if 'initial' in session and session['initial'] != packets[0]:
        raise ValueError('Initial observation replay differs.')
    for event, packet in zip(events, packets[1:]):
        if 'observation' in event and event['observation'] != packet:
            raise ValueError('Recorded player observation replay differs.')
    return packets


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_name(path.name + '.lock')
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise ValueError('Session is busy. If a process crashed, verify it stopped before removing its .lock file.') from error
    try:
        os.close(descriptor)
        yield
    finally:
        lock.unlink()


def save(path, value):
    serialized = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    if len(serialized.encode("utf-8")) > MAX_JOURNAL_BYTES:
        raise ValueError("Journal byte budget exceeded; previous episode remains unchanged.")
    # Same-directory replace prevents partial journals on ordinary interruption.
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(serialized)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['start', 'observe', 'act', 'report']:
        p = commands.add_parser(name)
        p.add_argument('--session', type=Path, required=True)
        if name == 'start':
            p.add_argument('--exposure', choices=['fresh', 'learned', 'source-informed'], default='source-informed')
        if name == 'act':
            p.add_argument('--turn', type=int, required=True)
            p.add_argument('--choice', choices=['express', 'local', 'defer'], required=True)
            p.add_argument('--request-id', required=True)
            p.add_argument('--reason', default='')
    args = parser.parse_args()
    path = args.session.resolve()
    try:
        with locked(path):
            if args.command == 'start':
                if path.exists():
                    raise ValueError('Session already exists; choose a new file. Reset never overwrites an episode.')
                session = {'schema': 1, 'game': 'station', 'exposure': args.exposure,
                           'source_fingerprint': source_fingerprint(), 'events': []}
                session['initial'] = replay(session)[0]
                save(path, session)
                result = session['initial']
            else:
                if path.stat().st_size > MAX_JOURNAL_BYTES:
                    raise ValueError('Session journal is too large.')
                session = json.loads(path.read_text(encoding='utf-8'))
                if session['schema'] != 1 or session['game'] != 'station':
                    raise ValueError('Unsupported session schema/game.')
                packets = replay(session)
                result = packets[-1]
                if args.command == 'act':
                    if not args.request_id or len(args.request_id) > 120 or len(args.reason) > 4000:
                        raise ValueError('Use request IDs of 1–120 characters and reasons up to 4000 characters.')
                    previous = next((e for e in session['events'] if e['request_id'] == args.request_id), None)
                    if previous:
                        if (previous['turn'], previous['choice'], previous['reason']) != (args.turn, args.choice, args.reason):
                            raise ValueError('Request ID already used with a different payload.')
                        result = {'retry': True, 'observation': previous['observation']}
                    else:
                        if len(session['events']) >= MAX_ATTEMPTS:
                            raise ValueError('Episode truncated by host attempt budget, not a game ending.')
                        event = {'request_id': args.request_id, 'turn': args.turn,
                                 'choice': args.choice, 'reason': args.reason}
                        session['events'].append(event)
                        result = replay(session)[-1]
                        event['observation'] = result
                        save(path, session)
                elif args.command == 'report':
                    events = session['events']
                    accepted = [e for e in events if e['observation']['result'] == 'accepted']
                    result = {'game': 'station', 'exposure': session['exposure'],
                              'source_fingerprint': session['source_fingerprint'], 'replay': 'matched',
                              'status': packets[-1]['status'], 'attempts': len(events),
                              'host_truncated': len(events) >= MAX_ATTEMPTS and packets[-1]['status'] != 'terminal',
                              'accepted': len(accepted), 'refused': len(events) - len(accepted),
                              'refusals_by_kind': {kind: sum(e['observation']['refusal_kind'] == kind for e in events)
                                                   for kind in ['protocol', 'domain']},
                              'choices': {choice: sum(e['choice'] == choice for e in accepted)
                                          for choice in ['express', 'local', 'defer']},
                              'initial': session['initial'], 'events': events,
                              'evaluation': 'Observed play evidence only. No automatic human-fun score; reasons are player reports, not causal proofs.'}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    sys.exit(main())
