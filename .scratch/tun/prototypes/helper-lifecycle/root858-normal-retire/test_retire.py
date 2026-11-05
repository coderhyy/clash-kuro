import contextlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('normal_retire', HERE / 'retire-normal-root858.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class RetireTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        fixture = HERE / 'fixtures/root858'
        pins = {fixture / path.name: expected for path, expected in r.PINS.items()}
        self.stack.enter_context(patch.object(r, 'REVIEW', fixture))
        self.stack.enter_context(patch.object(r, 'CLEANUP', fixture / 'cleanup-root858.py'))
        self.stack.enter_context(patch.object(r, 'PINS', pins))
        self.driver, self.observer = r.modules()
        self.approval = json.loads((fixture / 'approval.json').read_bytes())
        self.stack.enter_context(patch.object(self.driver, 'review', return_value=(self.approval, {})))
        self.installed = self.stack.enter_context(patch.object(self.driver, 'installed'))
        self.observation = self.stack.enter_context(patch.object(self.observer, 'processes_absent'))
        self.stack.enter_context(patch.object(r, 'evidence', return_value=({'normal': {}}, 'fixedhash')))
        self.stack.enter_context(patch.object(r.time, 'sleep'))
        self.launch = self.stack.enter_context(patch.object(self.driver.u, 'launch', return_value=SimpleNamespace(returncode=0)))
        self.job = self.stack.enter_context(patch.object(self.driver.u, 'job'))
        self.text = ('program = ' + str(self.driver.BINARY) + '\narguments = {\n'
                     + '\n'.join(self.driver.plist_for(self.approval, 'normal')['ProgramArguments'])
                     + '\n}\nstate = not running\nruns = 1\nlast exit code = 0\n')

    def test_exact_normal_bootout_only_and_absent_retry(self):
        self.job.side_effect = [self.text, self.text, self.text, None]
        r.retire(self.driver, self.observer)
        self.launch.assert_called_once_with('bootout', 'system/dev.kuro.tun.lifecycle-a')
        self.assertEqual(self.observation.call_count, 4)
        self.launch.reset_mock(); self.observation.reset_mock()
        self.job.side_effect = None; self.job.return_value = None
        r.retire(self.driver, self.observer)
        self.launch.assert_not_called()
        self.assertEqual(self.observation.call_count, 4)

    def test_live_reused_unknown_process_or_partial_install_never_bootout(self):
        self.job.return_value = self.text
        self.observation.side_effect = RuntimeError('PID/group unknown')
        with self.assertRaisesRegex(RuntimeError, 'unknown'): r.retire(self.driver, self.observer)
        self.launch.assert_not_called()
        self.observation.side_effect = None
        self.installed.side_effect = RuntimeError('partial installed identity')
        with self.assertRaisesRegex(RuntimeError, 'partial'): r.retire(self.driver, self.observer)
        self.launch.assert_not_called()

    def test_failed_wrong_live_or_missing_job_status_refused(self):
        for value in (self.text.replace('last exit code = 0', 'last exit code = 2'),
                      self.text.replace('runs = 1', 'runs = 2'),
                      self.text.replace('last exit code = 0', ''), self.text + 'pid = 42\n',
                      self.text.replace(self.approval['normalEpoch'], self.approval['killEpoch'])):
            with self.subTest(value=value):
                self.job.return_value = value
                with self.assertRaises(RuntimeError): r.retire(self.driver, self.observer)
                self.launch.assert_not_called()

    def test_evidence_change_or_bootout_failure_stops_without_other_action(self):
        self.job.return_value = self.text
        with patch.object(r, 'evidence', side_effect=[({'normal': {}}, 'first'), ({'normal': {}}, 'changed')]):
            with self.assertRaisesRegex(RuntimeError, 'changed'): r.retire(self.driver, self.observer)
        self.launch.assert_not_called()
        self.launch.return_value = SimpleNamespace(returncode=1)
        with self.assertRaisesRegex(RuntimeError, 'bootout failed'): r.retire(self.driver, self.observer)
        self.launch.assert_called_once_with('bootout', 'system/dev.kuro.tun.lifecycle-a')
        self.launch.reset_mock(); self.launch.return_value = SimpleNamespace(returncode=0)
        self.job.side_effect = [self.text, self.text, self.text, self.text]
        with self.assertRaisesRegex(RuntimeError, 'absence unproven'): r.retire(self.driver, self.observer)
        self.launch.assert_called_once_with('bootout', 'system/dev.kuro.tun.lifecycle-a')

    def test_actual_normal_evidence_wire_shape_and_strict_receipt(self):
        # Actual evidence bytes from the completed run, placed in ordinary-UID temp files only.
        original = {name: (HERE / 'fixtures/root858' / name).read_text() for name in ('normal/evidence.json', 'normal/normal-success.json')}
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); (base / 'normal').mkdir(mode=0o700); (base / 'kill').mkdir(mode=0o700)
            for name in ('normal/evidence.json', 'normal/normal-success.json'):
                path = base / name; path.write_text(original[name]); path.chmod(0o600)
            identity = json.loads((base / 'normal/evidence.json').read_bytes())
            identity['child']['executable'] = str(base / 'normal/mihomo')
            (base / 'normal/evidence.json').write_text(json.dumps(identity))
            with patch.object(self.driver, 'BASE', base), patch.object(self.driver.u, 'chain'), patch.object(self.driver, 'read', side_effect=lambda path, *_: path.read_bytes()):
                # Bypass only the outer mocked evidence(), use the actual function saved below.
                value, _digest = ACTUAL_EVIDENCE(self.driver, self.approval)
                self.assertEqual(value['normal']['child']['pid'], identity['child']['pid'])
                receipt = json.loads((base / 'normal/normal-success.json').read_bytes()); receipt['ownerAbsent'] = 1
                (base / 'normal/normal-success.json').write_text(json.dumps(receipt))
                with self.assertRaisesRegex(RuntimeError, 'bool proof'): ACTUAL_EVIDENCE(self.driver, self.approval)
                (base / 'normal/normal-success.json').write_text(original['normal/normal-success.json'])
                (base / 'kill/attempt.json').write_text('{}')
                with self.assertRaisesRegex(RuntimeError, 'kill/other'): ACTUAL_EVIDENCE(self.driver, self.approval)

    def test_modified_module_pin_rejected_before_import(self):
        pins = dict(r.PINS); pins[r.REVIEW / 'core-driver.py'] = '0' * 64
        with patch.object(r, 'PINS', pins):
            with self.assertRaisesRegex(RuntimeError, 'module bytes changed'): r.modules()


ACTUAL_EVIDENCE = r.evidence
if __name__ == '__main__':
    unittest.main()
