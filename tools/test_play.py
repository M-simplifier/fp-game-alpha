"""End-to-end contract tests for the actual Haskell player protocol."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import play


class PlayerContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = play.executable(play.source_fingerprint())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / 'episode.json'

    def tearDown(self):
        self.temporary.cleanup()

    def cli(self, command, *flags, success=True):
        result = subprocess.run([sys.executable, str(play.ROOT / 'tools/play.py'), command,
                                 '--session', str(self.path), *flags], capture_output=True,
                                text=True, encoding='utf-8', timeout=60)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        return json.loads(result.stdout if success else result.stderr)

    def test_player_story_and_visibility(self):
        first = self.cli('start')
        self.assertEqual(first['order']['name'], '焼きたてパンのかご')
        self.assertNotIn('おばあちゃんへの花束', json.dumps(first, ensure_ascii=False))
        self.assertEqual(set(first), {'protocol', 'game', 'result', 'feedback', 'refusal_kind', 'status', 'turn',
                                     'completed', 'total', 'resources', 'order', 'options', 'ending'})
        self.assertEqual(first['resources'], {'energy': 8, 'tickets': 3, 'delivered': 0})
        self.assertEqual(first, self.cli('observe'))
        self.cli('start', success=False)

    def test_retry_stale_and_terminal(self):
        self.cli('start', '--exposure', 'source-informed')
        after = self.cli('act', '--turn', '1', '--choice', 'local', '--request-id', 'r1', '--reason', 'save tickets')
        saved = self.path.read_bytes()
        retry = self.cli('act', '--turn', '1', '--choice', 'local', '--request-id', 'r1', '--reason', 'save tickets')
        self.assertTrue(retry['retry'])
        self.assertEqual(retry['observation'], after)
        self.assertEqual(saved, self.path.read_bytes())
        self.cli('act', '--turn', '1', '--choice', 'express', '--request-id', 'r1', success=False)
        stale = self.cli('act', '--turn', '1', '--choice', 'local', '--request-id', 'stale')
        self.assertEqual(stale['result'], 'refused')
        self.assertEqual(stale['refusal_kind'], 'protocol')
        self.assertEqual(stale['resources'], after['resources'])
        self.assertEqual(stale['turn'], 2)
        for turn in range(2, 7):
            end = self.cli('act', '--turn', str(turn), '--choice', 'defer', '--request-id', f'r{turn}')
        self.assertEqual(end['status'], 'terminal')
        self.assertIsNone(end['turn'])
        self.assertIsNone(end['order'])
        refused = self.cli('act', '--turn', '7', '--choice', 'defer', '--request-id', 'post-end')
        self.assertEqual(refused['resources'], end['resources'])
        report = self.cli('report')
        self.assertEqual(report['accepted'], 6)
        self.assertEqual(report['refused'], 2)
        self.assertEqual(report['replay'], 'matched')
        self.assertEqual(report['exposure'], 'source-informed')

    def test_unaffordable_command_and_malformed_line(self):
        commands = 'act 1 express\nact 2 express\nact 3 express\nact 4 express\ninvalid\nobserve\n'
        result = subprocess.run([str(self.binary)], input=commands, text=True, encoding='utf-8', capture_output=True, check=True)
        packets = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(packets[4]['result'], 'refused')
        self.assertEqual(packets[4]['refusal_kind'], 'domain')
        self.assertEqual(packets[4]['turn'], 4)
        self.assertEqual(packets[4]['resources'], packets[3]['resources'])
        self.assertEqual(packets[5]['result'], 'refused')
        self.assertEqual(packets[6]['turn'], 4)

    def test_protocol_validation_precedes_turn_resolution(self):
        malformed_shape = 'Expected observe or act <visible-turn> express|local|defer.'
        malformed_action = 'Expected act <visible-turn> express|local|defer.'
        invalid = [('', malformed_shape), ('observe extra', malformed_shape),
                   ('act 1', malformed_shape), ('act 1 local extra', malformed_shape),
                   ('act nope local', malformed_action), ('act 1 unknown', malformed_action)]
        for terminal in [False, True]:
            prefix = [f'act {turn} defer' for turn in range(1, 7)] if terminal else []
            valid_shape_error = 'The episode has ended.' if terminal else 'Stale turn; observe again.'
            cases = [*invalid, ('act 0 local', valid_shape_error)]
            commands = '\n'.join([*prefix, *[command for command, _ in cases]]) + '\n'
            result = subprocess.run([str(self.binary)], input=commands, text=True,
                                    encoding='utf-8', capture_output=True, check=True)
            packets = [json.loads(line) for line in result.stdout.splitlines()]
            before = packets[len(prefix)]
            self.assertEqual(len(packets), len(prefix) + len(cases) + 1)
            for (command, feedback), packet in zip(cases, packets[len(prefix) + 1:]):
                with self.subTest(terminal=terminal, command=command):
                    expected = {**before, 'result': 'refused', 'feedback': feedback,
                                'refusal_kind': 'protocol'}
                    self.assertEqual(packet, expected)

    def test_replay_drift_and_source_change_rejected(self):
        self.cli('start')
        journal = json.loads(self.path.read_text(encoding='utf-8'))
        journal['initial']['resources']['energy'] = 99
        self.path.write_text(json.dumps(journal), encoding='utf-8')
        self.assertIn('replay differs', self.cli('observe', success=False)['error'])
        journal['source_fingerprint'] = 'invalid'
        self.path.write_text(json.dumps(journal), encoding='utf-8')
        self.assertIn('source changed', self.cli('observe', success=False)['error'])

    def test_unbounded_transport_numbers_never_wrap(self):
        for turn in ['18446744073709551617', '-18446744073709551615', '4294967297']:
            result = subprocess.run([str(self.binary)], input=f'act {turn} local\n',
                                    text=True, encoding='utf-8', capture_output=True, check=True)
            packets = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(packets[-1]['result'], 'refused')
            self.assertEqual(packets[-1]['turn'], 1)
            self.assertEqual(packets[-1]['resources'], packets[0]['resources'])

    def test_byte_budget_rejects_before_replacing_journal(self):
        self.cli('start')
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'byte budget'):
            play.save(self.path, {'value': '🌱' * (play.MAX_JOURNAL_BYTES // 4)})
        self.assertEqual(before, self.path.read_bytes())
        self.cli('observe')

    def test_lock_blocks_overlapping_updates(self):
        self.cli('start')
        self.path.with_name(self.path.name + '.lock').touch()
        self.assertIn('busy', self.cli('observe', success=False)['error'])

    def test_attempt_budget_is_not_game_ending(self):
        self.cli('start')
        journal = json.loads(self.path.read_text(encoding='utf-8'))
        # Hostile/stale repeated turns cannot secretly progress the game.
        journal['events'] = [{'request_id': str(i), 'turn': 0, 'choice': 'defer', 'reason': ''}
                             for i in range(play.MAX_ATTEMPTS)]
        for event, packet in zip(journal['events'], play.replay(journal)[1:]):
            event['observation'] = packet
        self.path.write_text(json.dumps(journal), encoding='utf-8')
        report = self.cli('report')
        self.assertTrue(report['host_truncated'])
        self.assertEqual(report['status'], 'running')
        self.assertEqual(report['accepted'], 0)
        self.assertIn('truncated', self.cli('act', '--turn', '1', '--choice', 'defer', '--request-id', 'overflow', success=False)['error'])


if __name__ == '__main__':
    unittest.main()
