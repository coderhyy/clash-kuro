import contextlib
import ctypes
import errno
from types import SimpleNamespace
from unittest.mock import Mock
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('cleanup_root858', HERE / 'cleanup-root858.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
FROZEN = HERE / 'fixtures/root858'


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='kuro-cleanup-fixture-', dir='/private/tmp')
        self.root = Path(self.temporary.name)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(self.stack.close)
        self.base = self.root / 'evidence'
        self.binary = self.root / 'protected-tools/lifecycle-a'
        self.plist = self.root / 'launchdaemons/lifecycle-a.plist'
        for key, value in dict(BASE=self.base, BINARY=self.binary, PLIST=self.plist,
                               OWNER=os.geteuid(), BINARY_SHA=d.sha(b'fixture binary'), CORE_SHA=d.sha(b'fixture core')).items():
            self.stack.enter_context(patch.object(d, key, value))
        self.stack.enter_context(patch.object(d, 'no_acl'))
        # Only the isolated temporary root substitutes protected system ancestors.
        def fixture_chain(path, directory=False):
            self.assertTrue(path.is_relative_to(self.root))
            for item in list(reversed(path.parents)) + [path]:
                if item == self.root or item.is_relative_to(self.root):
                    d.node(item, item != path or directory)
        self.stack.enter_context(patch.object(d, 'chain', side_effect=fixture_chain))
        self.job = self.stack.enter_context(patch.object(d, 'job_absent'))
        self.process = self.stack.enter_context(patch.object(d, 'processes_absent'))
        self.stack.enter_context(patch.object(d.time, 'sleep'))
        self.base.mkdir(mode=0o700)
        self.binary.parent.mkdir(mode=0o755)
        self.plist.parent.mkdir(mode=0o755)
        self.write(self.base / 'approval.json', (FROZEN / 'approval.json').read_bytes())
        approval = d.decode((self.base / 'approval.json').read_bytes())
        for index, (stage, epoch) in enumerate((('normal', d.NORMAL_EPOCH), ('kill', d.KILL_EPOCH))):
            directory = self.base / stage
            directory.mkdir(mode=0o700)
            self.write(directory / 'mihomo', b'fixture core', 0o755)
            group = 10000 + index * 2
            supervisor = dict(pid=group, startSeconds=100, startMicros=0, processGroup=group, executable=str(self.binary))
            child = dict(pid=group + 1, startSeconds=101, startMicros=1, processGroup=group, executable=str(directory / 'mihomo'))
            self.write(directory / 'evidence.json', d.encode(dict(format=1, stage=stage, epoch=epoch,
                       coreSHA256=d.CORE_SHA, fixtureSHA256=d.BINARY_SHA, supervisor=supervisor, child=child, startedMilliseconds=100)))
        self.write(self.binary, b'fixture binary', 0o755)
        self.write(self.plist, plistlib.dumps(d.plist_value()), 0o644)
        self.write(self.base / 'normal/normal-success.json', d.encode(dict(format=1, stage='normal', epoch=d.NORMAL_EPOCH,
                   status='passed', approvalSHA256=d.sha(d.encode(approval)), coreSHA256=d.CORE_SHA, fixtureSHA256=d.BINARY_SHA,
                   childReaped=True, workAbsent=True, ownerAbsent=True,
                   termination=dict(request='SIGTERM', observed=True, exitCode=0, signal=None), error='')))
        self.write(self.base / 'kill/group-observation.json', d.encode(dict(epoch=d.KILL_EPOCH, supervisor=dict(state='absent'),
                   child=dict(state='absent'), groupMembers=[], groupObservationKnown=True, elapsedMilliseconds=5000,
                   workExists=True, ownerExists=True, error='')))
        # Evidence is never a deletion candidate, even if unknown to the script.
        self.write(self.base / 'kill/owner.json', b'original owner bytes')
        (self.base / 'kill/session-work').mkdir(mode=0o700)
        self.write(self.base / 'kill/session-work/cache.db', b'original cache bytes')
        self.write(self.base / 'kill/stdout.log', b'original log bytes')
        self.write(self.base / 'kill/unrecognized-file', b'unknown evidence')
        self.original = {p: p.read_bytes() for p in self.base.rglob('*') if p.is_file() and p.name != 'mihomo'}

    def write(self, path, data, mode=0o600):
        path.write_bytes(data)
        path.chmod(mode)

    def assert_preserved(self):
        for path, raw in self.original.items():
            self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(stat.S_IMODE(self.base.stat().st_mode), 0o700)
        self.assertTrue((self.base / 'kill/session-work').is_dir())

    def record(self):
        hashes, _ = d.proof()
        value = dict(format=1, sourceCommit=d.SOURCE, approvalSHA256=d.APPROVAL_SHA,
                     evidenceSHA256=hashes, targets=[d.snapshot(*item) for item in d.targets()])
        d.write_record(self.base / d.RECORD_NAME, d.encode(value))
        return value

    def test_success_removes_only_four_preserves_unknown_and_idempotent(self):
        d.cleanup()
        self.assertTrue(all(not os.path.lexists(path) for path, _, _ in d.targets()))
        self.assert_preserved()
        self.assertTrue((self.base / d.RECORD_NAME).is_file())
        self.assertGreaterEqual(self.job.call_count, 7)
        self.assertGreaterEqual(self.process.call_count, 7)
        self.job.reset_mock(); self.process.reset_mock()
        d.cleanup()
        self.assertGreaterEqual(self.process.call_count, 7)
        self.assert_preserved()

    def test_partial_install_without_record_rejected_no_deletion(self):
        (self.base / 'normal/mihomo').unlink()
        with self.assertRaises(FileNotFoundError): d.cleanup()
        self.assertTrue(self.plist.exists() and self.binary.exists() and (self.base / 'kill/mihomo').exists())
        self.assertFalse((self.base / d.RECORD_NAME).exists())
        self.assert_preserved()

    def test_durable_approval_precedes_any_unlink(self):
        with patch.object(d, 'sync', side_effect=OSError('first approval sync failed')):
            with self.assertRaisesRegex(OSError, 'approval sync'): d.cleanup()
        self.assertTrue(all(path.exists() for path, _, _ in d.targets()))
        self.assertTrue((self.base / d.RECORD_NAME).exists())
        d.cleanup(); self.assert_preserved()

    def test_interrupted_each_unlink_retries_with_fresh_absence_checks(self):
        for position in range(4):
            with self.subTest(position=position):
                # Recreate fixture for each interruption point.
                if position: self.tearDown(); self.doCleanups(); self.setUp()
                real_sync = d.sync
                parent = d.targets()[position][0].parent
                fail = [True]
                def interrupted(path):
                    if path == parent and not d.targets()[position][0].exists() and fail[0]:
                        fail[0] = False
                        raise OSError('post-unlink parent sync failed')
                    real_sync(path)
                with patch.object(d, 'sync', side_effect=interrupted):
                    with self.assertRaisesRegex(OSError, 'post-unlink'): d.cleanup()
                self.job.reset_mock(); self.process.reset_mock()
                d.cleanup()
                self.assertGreaterEqual(self.job.call_count, 7)
                self.assertGreaterEqual(self.process.call_count, 7)
                self.assert_preserved()

    def test_same_bytes_replacement_and_changed_mode_rejected(self):
        self.record()
        old = self.binary.with_suffix('.held')
        self.binary.rename(old)
        self.write(self.binary, b'fixture binary', 0o755)
        with self.assertRaisesRegex(RuntimeError, 'identity changed'): d.cleanup()
        self.assertTrue(all(path.exists() for path, _, _ in d.targets()))
        self.binary.unlink(); old.rename(self.binary)
        # Restoring the old inode still changed ctime: never silently re-approve it.
        with self.assertRaisesRegex(RuntimeError, 'identity changed'): d.cleanup()
        self.assert_preserved()

    def test_symlink_core_preserved_never_followed(self):
        self.record()
        core = self.base / 'normal/mihomo'
        core.unlink(); core.symlink_to(self.base / 'kill/unrecognized-file')
        with self.assertRaisesRegex(RuntimeError, 'type/link'): d.cleanup()
        self.assertTrue(core.is_symlink())
        self.assert_preserved()

    def test_changed_approval_unknown_record_or_evidence_block(self):
        self.record()
        record = self.base / d.RECORD_NAME
        old = record.read_bytes()
        value = d.decode(old); value['extra'] = True
        self.write(record, d.encode(value))
        with self.assertRaisesRegex(RuntimeError, 'approval'): d.cleanup()
        self.assertTrue(all(path.exists() for path, _, _ in d.targets()))
        self.write(record, old)
        evidence = self.base / 'kill/evidence.json'
        value = d.decode(evidence.read_bytes()); value['child']['startSeconds'] += 1
        self.write(evidence, d.encode(value))
        with self.assertRaisesRegex(RuntimeError, 'approval'): d.cleanup()
        self.assertTrue(all(path.exists() for path, _, _ in d.targets()))

    def test_live_job_process_unknown_or_reused_blocks_before_record(self):
        for target in (self.job, self.process):
            target.side_effect = RuntimeError('absence unknown')
            with self.assertRaisesRegex(RuntimeError, 'unknown'): d.cleanup()
            self.assertFalse((self.base / d.RECORD_NAME).exists())
            self.assertTrue(all(path.exists() for path, _, _ in d.targets()))
            target.side_effect = None

    def test_no_fallback_or_partial_kill_proof_accepted(self):
        marker = self.base / 'kill/reaped.json'
        self.write(marker, b'{}')
        with self.assertRaisesRegex(RuntimeError, 'fallback'): d.cleanup()
        marker.unlink()
        path = self.base / 'kill/group-observation.json'
        value = d.decode(path.read_bytes()); value['groupObservationKnown'] = 1
        self.write(path, d.encode(value))
        with self.assertRaisesRegex(RuntimeError, 'kill observation'): d.cleanup()
        self.assertFalse((self.base / d.RECORD_NAME).exists())

    def test_target_mode_and_acl_rejected(self):
        self.binary.chmod(0o700)
        with self.assertRaisesRegex(RuntimeError, 'permissions'): d.cleanup()
        self.binary.chmod(0o755)
        with patch.object(d, 'no_acl', side_effect=RuntimeError('ACL requires manual review')):
            with self.assertRaisesRegex(RuntimeError, 'ACL'): d.cleanup()
        self.assertFalse((self.base / d.RECORD_NAME).exists())

    def test_libproc_empty_group_padding_negative_and_overflow(self):
        identity = dict(pid=10000, processGroup=10000)
        evidence = {'normal': dict(supervisor=identity, child=identity)}
        def absent(*_):
            ctypes.set_errno(errno.ESRCH)
            return 0
        for count, member, failure, accepted in ((0, 0, 0, True), (4, 0, 0, True),
                (4, -1, 0, False), (4, 99, 0, False), (-1, 0, 0, False),
                (3, 0, 0, False), (256, 0, 0, False), (0, 0, errno.EPERM, False)):
            with self.subTest(count=count, member=member, errno=failure):
                def group(_type, _group, members, _size):
                    members[0] = member
                    ctypes.set_errno(failure)
                    return count
                lib = SimpleNamespace(proc_pidinfo=Mock(side_effect=absent), proc_listpids=Mock(side_effect=group))
                with patch.object(d.ctypes, 'CDLL', return_value=lib):
                    if accepted:
                        ORIGINAL_PROCESSES_ABSENT(evidence)
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'group absence unknown'):
                            ORIGINAL_PROCESSES_ABSENT(evidence)

    def test_real_libproc_self_pid_never_absent(self):
        # Read only; no child/Core/launchctl/process signal is executed.
        identity = dict(pid=os.getpid(), processGroup=os.getpgrp())
        actual = self.process.side_effect
        self.process.side_effect = None
        with patch.object(d, 'processes_absent', wraps=ORIGINAL_PROCESSES_ABSENT):
            with self.assertRaisesRegex(RuntimeError, 'live/reused/unknown'):
                d.processes_absent({'normal': dict(supervisor=identity, child=identity)})
        self.process.side_effect = actual


ORIGINAL_PROCESSES_ABSENT = d.processes_absent
if __name__ == '__main__':
    unittest.main()
