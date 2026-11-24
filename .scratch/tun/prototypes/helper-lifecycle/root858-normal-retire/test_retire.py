import contextlib
import ctypes
import errno
import os
import stat
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch, Mock

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


class RecoverySeparationTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        fixture = HERE / 'fixtures/root858'
        self.stack.enter_context(patch.object(r, 'REVIEW', fixture))
        self.stack.enter_context(patch.object(r, 'CLEANUP', fixture / 'cleanup-root858.py'))
        self.stack.enter_context(patch.object(r, 'PINS', {fixture / path.name: value for path, value in r.PINS.items()}))
        self.driver, self.observer = r.modules()
        self.approval = json.loads((fixture / 'approval.json').read_bytes())
        self.stack.enter_context(patch.object(self.driver, 'review', return_value=(self.approval, {})))
        self.installed = self.stack.enter_context(patch.object(self.driver, 'installed'))
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        (self.base / 'normal').mkdir(mode=0o700); (self.base / 'kill').mkdir(mode=0o700)
        for name in ('normal/evidence.json', 'normal/normal-success.json'):
            path = self.base / name; path.write_bytes((fixture / name).read_bytes()); path.chmod(0o600)
        self.record = self.base / 'normal/evidence.json'
        value = json.loads(self.record.read_bytes()); value['child']['executable'] = str(self.base / 'normal/mihomo')
        self.record.write_text(json.dumps(value)); self.identity = value
        (self.base / 'normal/unknown-evidence').write_text('must remain')
        self.stack.enter_context(patch.object(self.driver, 'BASE', self.base))
        original_read = self.driver.read
        self.stack.enter_context(patch.object(self.driver, 'read', side_effect=lambda path, _owner, limit: original_read(path, os.geteuid(), limit)))
        def ordinary_protected_chain(path, directory=False):
            # Substitute only ownership/ACL of the temporary root; preserve real file reads/modes/type checks.
            r.require(path.is_relative_to(self.base), 'fixture path escape')
            for item in list(reversed(path.parents)) + [path]:
                if item == self.base or item.is_relative_to(self.base):
                    info = item.lstat()
                    r.require(info.st_uid == os.geteuid() and not info.st_mode & 0o6022 and
                              (stat.S_ISDIR(info.st_mode) if item != path or directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1), 'fixture protection failed')
        self.stack.enter_context(patch.object(self.driver.u, 'chain', side_effect=ordinary_protected_chain))
        self.stack.enter_context(patch.object(r.time, 'sleep'))
        self.stack.enter_context(patch.object(self.driver, 'inspect', side_effect=AssertionError('recovery must not reuse acceptance observer')))
        self.stack.enter_context(patch.object(self.driver, 'start', side_effect=AssertionError('must not start Core')))
        self.stack.enter_context(patch.object(self.observer, 'cleanup', side_effect=AssertionError('must not delete files')))
        self.kernel = 'absent'; self.mutate = False; self.pid_reads = 0; self.loaded = True
        def pid_info(pid, flavor, _arg, _buffer, _size):
            self.assertIn(pid, [self.identity['supervisor']['pid'], self.identity['child']['pid']]); self.assertEqual(flavor, 3)
            self.pid_reads += 1
            if self.mutate and self.pid_reads == 2:
                changed = json.loads(self.record.read_bytes()); changed['child']['startMicros'] += 1
                self.record.write_text(json.dumps(changed))
            ctypes.set_errno(errno.ESRCH if self.kernel in ('absent', 'group-live', 'group-unknown') else (errno.EPERM if self.kernel == 'unknown' else 0))
            return 136 if self.kernel == 'live' else 0
        def group_info(flavor, group, _buffer, _size):
            self.assertEqual((flavor, group), (2, self.identity['supervisor']['processGroup']))
            if self.kernel == 'group-live':
                _buffer[0] = 55555
                ctypes.set_errno(0); return ctypes.sizeof(ctypes.c_int)
            ctypes.set_errno(errno.EPERM if self.kernel == 'group-unknown' else 0)
            return -1 if self.kernel == 'group-unknown' else 0
        lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=pid_info), proc_listpids=Mock(side_effect=group_info))
        self.stack.enter_context(patch.object(self.observer.ctypes, 'CDLL', return_value=lib))
        self.text = ('program = ' + str(self.driver.BINARY) + '\narguments = {\n'
                     + '\n'.join(self.driver.plist_for(self.approval, 'normal')['ProgramArguments'])
                     + '\n}\nstate = not running\nruns = 1\nlast exit code = 0\n')
        def launch(*args):
            if args == ('print', 'system/dev.kuro.tun.lifecycle-a'):
                return SimpleNamespace(returncode=0 if self.loaded else 113, stdout=self.text if self.loaded else '', stderr='' if self.loaded else 'Could not find service')
            self.assertEqual(args, ('bootout', 'system/dev.kuro.tun.lifecycle-a'))
            self.loaded = False
            return SimpleNamespace(returncode=0)
        self.launch = self.stack.enter_context(patch.object(self.driver.u, 'launch', side_effect=launch))

    def test_numeric_observer_rejects_acceptance_but_independent_recovery_retires(self):
        legacy = json.loads('{"supervisor":{"state":"absent"},"child":{"state":"absent"},"groupMembers":[],"groupObservationKnown":1}')
        with self.assertRaises(RuntimeError): self.driver.absent(legacy)
        with patch.object(self.driver, 'inspect', return_value=legacy):
            with self.assertRaises(RuntimeError): self.driver.retire(self.approval, 'normal')
        self.launch.assert_not_called()
        before = {path: path.read_bytes() for path in self.base.rglob('*') if path.is_file()}
        # Actual receipt/identity validation -> actual libproc observer with injected kernel -> actual job parser -> fixed bootout.
        r.retire(self.driver, self.observer)
        self.assertFalse(self.loaded); self.assertEqual(self.pid_reads, 8)
        self.assertEqual([call.args for call in self.launch.call_args_list if call.args[0] != 'print'], [('bootout', 'system/dev.kuro.tun.lifecycle-a')])
        self.assertEqual({path: path.read_bytes() for path in self.base.rglob('*') if path.is_file()}, before)
        self.assertTrue(all(call.args == (self.approval, 'normal') for call in self.installed.call_args_list))

    def test_live_unknown_wrong_epoch_and_changed_record_never_retire(self):
        for state in ('live', 'unknown', 'group-live', 'group-unknown'):
            self.kernel = state
            with self.assertRaisesRegex(RuntimeError, 'unknown'): r.retire(self.driver, self.observer)
            self.launch.assert_not_called(); self.assertTrue(self.loaded)
        self.kernel = 'absent'
        original = self.record.read_bytes(); value = json.loads(original); value['epoch'] = self.approval['killEpoch']
        self.record.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError, 'epoch/pins'): r.retire(self.driver, self.observer)
        self.launch.assert_not_called(); self.record.write_bytes(original)
        self.pid_reads = 0; self.mutate = True
        with self.assertRaisesRegex(RuntimeError, 'evidence changed'): r.retire(self.driver, self.observer)
        self.assertFalse(any(call.args[0] == 'bootout' for call in self.launch.call_args_list)); self.assertTrue(self.loaded)
        self.assertNotEqual(self.record.read_bytes(), original)  # Changed evidence is preserved.



ACTUAL_EVIDENCE = r.evidence
if __name__ == '__main__':
    unittest.main()
