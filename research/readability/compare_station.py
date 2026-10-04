"""Compare Station player packets across two compiled source revisions.

The baseline drives finite history enumeration. Expected packets are never
rewritten from the refactored implementation; comparison includes raw bytes.
"""
import argparse
from collections import deque
import json
from pathlib import Path
import subprocess


CHOICES = ('express', 'local', 'defer')


def run(binary, commands):
    result = subprocess.run([str(binary)], input=('\n'.join(commands) + '\n').encode('utf-8'),
                            capture_output=True, timeout=10, check=True)
    if result.stderr:
        raise AssertionError('Player process wrote unexpected diagnostics')
    return result.stdout


def probes(turn):
    return ['observe', ' \tobserve \t', '', 'unknown', 'observe extra', 'act',
            'act 1', 'act 1 local extra', 'act nope local', 'act 1 unknown',
            'act -18446744073709551615 local', 'act 18446744073709551617 local',
            f'act {turn - 1} local']


def compare(baseline, current):
    histories = deque([()])
    states = attempts = terminals = cases = packets = 0

    def check(commands):
        nonlocal cases, packets
        expected = run(baseline, commands)
        actual = run(current, commands)
        cases += 1
        if actual != expected:
            raise AssertionError(f'Player packet bytes differ in case {cases}: {commands!r}')
        decoded = [json.loads(line) for line in expected.decode('utf-8').splitlines()]
        if len(decoded) != len(commands) + 1:
            raise AssertionError('Baseline response count differs from command count')
        packets += len(decoded)
        return decoded

    while histories:
        history = histories.popleft()
        states += 1
        turn = len(history) + 1
        prefix = [f'act {number} {choice}' for number, choice in enumerate(history, 1)]
        commands = [*prefix, *probes(turn)]
        if len(history) == 6:
            terminals += 1
            check([*commands, *[f'act {turn} {choice}' for choice in CHOICES], 'observe'])
            continue
        for choice in CHOICES:
            attempts += 1
            action = f'act {turn} {choice}'
            # Check the choice, its observation and an immediate retry with the
            # old turn number. Accepted choices alone grow the baseline tree.
            result = check([*commands, action, 'observe', action, 'observe'])
            if result[len(commands) + 1]['result'] == 'accepted':
                histories.append((*history, choice))

    if (states, attempts, terminals) != (864, 969, 541):
        raise AssertionError(f'Unexpected baseline tree: {(states, attempts, terminals)}')
    print(f'Station packet comparison: PASS ({states} histories, {attempts} choices, '
          f'{terminals} terminals; {cases} cases, {packets} byte-identical packets)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path, help='Player binary compiled before the refactor')
    parser.add_argument('current', type=Path, help='Player binary compiled after the refactor')
    arguments = parser.parse_args()
    compare(arguments.baseline.resolve(strict=True), arguments.current.resolve(strict=True))


if __name__ == '__main__':
    main()
