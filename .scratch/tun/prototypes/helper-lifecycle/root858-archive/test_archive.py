import contextlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('archive858', HERE / 'archive-root858.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        existing = HERE.parent / 'root858-normal-retire'
        fixture = existing / 'fixtures/root858'
        namespace = {'__file__': str(existing / 'retire-normal-root858.py'), '__name__': 'archive_fixture_admission'}
        exec(compile((existing / 'retire-normal-root858.py').read_bytes(), str(existing / 'retire-normal-root858.py'), 'exec'), namespace)
        namespace['REVIEW'] = fixture
        namespace['CLEANUP'] = fixture / 'cleanup-root858.py'
        namespace['PINS'] = {fixture / path.name: expected for path, expected in namespace['PINS'].items()}
        self.r = namespace
        self.d, self.o = namespace['modules']()
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix='kuro-root-archive-fixture-')))
        self.base = self.root / 'TunLifecycleExperimentA'; self.base.mkdir(mode=0o700)
        self.archive = self.root / 'TunLifecycleExperimentA-root858-preserved'
        for stage in ('normal', 'kill'): (self.base / stage).mkdir(mode=0o700)
        self.binary = self.root / 'lifecycle-a'; self.binary.write_bytes(b'controlled fixture helper'); self.binary.chmod(0o755)
        self.plist = self.root / 'lifecycle-a.plist'
        self.approval = json.loads((fixture / 'approval.json').read_bytes())
        self.approval['coreSHA256'] = self.o.sha(b'controlled fixture Core')
        self.approval['fixtureSHA256'] = self.o.sha(self.binary.read_bytes())
        approval_bytes = json.dumps(self.approval, sort_keys=True, indent=2).encode()
        (self.base / 'approval.json').write_bytes(approval_bytes)
        self.stack.enter_context(patch.object(self.o, 'APPROVAL_SHA', self.o.sha(approval_bytes)))
        self.stack.enter_context(patch.object(self.o, 'OWNER', os.geteuid()))
        self.stack.enter_context(patch.object(a, 'BASE', self.base)); self.stack.enter_context(patch.object(a, 'ARCHIVE', self.archive))
        self.stack.enter_context(patch.object(self.d, 'BASE', self.base)); self.stack.enter_context(patch.object(self.d, 'BINARY', self.binary)); self.stack.enter_context(patch.object(self.d, 'PLIST', self.plist))
        self.plist.write_bytes(plistlib.dumps(self.d.plist_for(self.approval, 'normal'))); self.plist.chmod(0o644)
        for stage in ('normal', 'kill'):
            (self.base / stage / 'mihomo').write_bytes(b'controlled fixture Core'); (self.base / stage / 'mihomo').chmod(0o755)
        for name in a.FILES - {'approval.json'}:
            path = self.base / name
            path.write_bytes((fixture / name).read_bytes() if (fixture / name).exists() else b'fixture non-sensitive diagnostic\n')
            path.chmod(0o600)
        (self.base / 'approval.json').chmod(0o600)
        identity_path = self.base / 'normal/evidence.json'
        identity = json.loads(identity_path.read_bytes())
        identity.update(coreSHA256=self.approval['coreSHA256'], fixtureSHA256=self.approval['fixtureSHA256'])
        identity['supervisor']['executable'] = str(self.binary); identity['child']['executable'] = str(self.base / 'normal/mihomo')
        identity_path.write_text(json.dumps(identity))
        receipt_path = self.base / 'normal/normal-success.json'
        receipt = json.loads(receipt_path.read_bytes())
        receipt.update(coreSHA256=self.approval['coreSHA256'], fixtureSHA256=self.approval['fixtureSHA256'], approvalSHA256=self.o.sha(self.o.encode(self.approval)))
        receipt_path.write_text(json.dumps(receipt))
        # Outer admission/root-only ancestors are substituted; real file bytes/modes/inodes and unlink/rename/fsync are used.
        self.stack.enter_context(patch.object(self.d, 'review', return_value=(self.approval, {})))
        original_read = self.d.read
        self.stack.enter_context(patch.object(self.d, 'read', side_effect=lambda path, _owner, limit=128*1024*1024: original_read(path, os.geteuid(), limit)))
        self.stack.enter_context(patch.object(self.o, 'no_acl'))
        def chain(path, directory=False):
            a.require(path == self.root or path.is_relative_to(self.root), 'fixture escape')
            items = [self.root] + [p for p in list(reversed(path.parents)) + [path] if p.is_relative_to(self.root)]
            for item in dict.fromkeys(items): self.o.node(item, item != path or directory)
        self.stack.enter_context(patch.object(self.o, 'chain', side_effect=chain))
        self.stack.enter_context(patch.object(self.d.u, 'chain', side_effect=chain))
        self.job = self.stack.enter_context(patch.object(self.d.u, 'job', return_value=None))
        self.observer = self.stack.enter_context(patch.object(self.o, 'processes_absent'))
        self.stack.enter_context(patch.object(a.time, 'sleep'))
        self.launch = self.stack.enter_context(patch.object(self.d.u, 'launch', side_effect=AssertionError('archive must not change a job')))
        self.stack.enter_context(patch.object(a, 'rename_exclusive', side_effect=self.rename))
        # Verify the production installed() gate with fixture pins, instead of stubbing that gate.
        self.d.installed(self.approval, 'normal')

    def rename(self, source, destination):
        a.require(not os.path.lexists(destination), 'exclusive archive collision')
        source.rename(destination)

    def run_archive(self): a.archive(self.r, self.d, self.o)

    def test_positive_real_files_and_idempotent_archive(self):
        expected = {name: (self.base / name).read_bytes() for name in a.FILES}
        self.run_archive()
        self.assertFalse(self.base.exists()); self.assertTrue(self.archive.is_dir())
        self.assertFalse(self.binary.exists()); self.assertFalse(self.plist.exists())
        for name, raw in expected.items(): self.assertEqual((self.archive / name).read_bytes(), raw)
        self.assertEqual({p.name for p in (self.archive / 'kill').iterdir()}, set())
        self.run_archive(); self.launch.assert_not_called()

    def test_live_unknown_job_or_process_blocks_before_record(self):
        self.job.return_value = 'present'
        with self.assertRaisesRegex(RuntimeError, 'job present'): self.run_archive()
        self.job.return_value = None; self.observer.side_effect = RuntimeError('group unknown')
        with self.assertRaisesRegex(RuntimeError, 'unknown'): self.run_archive()
        self.assertTrue(self.binary.exists()); self.assertFalse((self.base / a.RECORD).exists())

    def test_unknown_file_symlink_and_kill_attempt_preserved(self):
        for name in ('normal/unknown', 'kill/attempt.json'):
            path = self.base / name; path.write_text('preserve')
            with self.assertRaises(RuntimeError): self.run_archive()
            self.assertTrue(path.exists()); self.assertTrue(self.binary.exists()); path.unlink()
        path = self.base / 'normal/stdout.log'; path.unlink(); path.symlink_to('/no-follow-target')
        with self.assertRaises(RuntimeError): self.run_archive()
        self.assertTrue(path.is_symlink()); self.assertTrue(self.binary.exists())

    def test_changed_identity_after_approval_preserved(self):
        real_write = self.o.write_record
        def write(path, raw):
            real_write(path, raw); self.binary.write_bytes(b'changed helper')
        with patch.object(self.o, 'write_record', side_effect=write):
            with self.assertRaisesRegex(RuntimeError, 'hash changed'): self.run_archive()
        self.assertEqual(self.binary.read_bytes(), b'changed helper'); self.assertTrue(self.plist.exists())

    def test_interrupted_unlink_parent_sync_retries_only_approved_files(self):
        real_sync = self.o.sync; failed = False
        def sync(path):
            nonlocal failed
            if path == self.plist.parent and not self.plist.exists() and not failed:
                failed = True; raise OSError('fixture parent sync failure')
            return real_sync(path)
        with patch.object(self.o, 'sync', side_effect=sync):
            with self.assertRaisesRegex(OSError, 'sync failure'): self.run_archive()
        self.assertTrue((self.base / a.RECORD).exists()); self.assertFalse(self.plist.exists()); self.assertTrue(self.binary.exists())
        self.run_archive(); self.assertTrue(self.archive.exists()); self.assertFalse(self.binary.exists())

    def test_archive_rename_sync_failure_retries_without_new_deletion(self):
        real_sync = self.o.sync
        def sync(path):
            if path == self.root and self.archive.exists(): raise OSError('archive parent sync failure')
            return real_sync(path)
        with patch.object(self.o, 'sync', side_effect=sync):
            with self.assertRaisesRegex(OSError, 'sync failure'): self.run_archive()
        self.assertTrue(self.archive.exists()); self.assertFalse(self.base.exists())
        with patch.object(Path, 'unlink', side_effect=AssertionError('retry must not delete')): self.run_archive()

    def test_archive_collision_or_evidence_change_preserved(self):
        self.archive.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, 'both old'): self.run_archive()
        self.archive.rmdir()
        real_write = self.o.write_record
        def write(path, raw):
            real_write(path, raw); (self.base / 'normal/stdout.log').write_text('changed evidence')
        with patch.object(self.o, 'write_record', side_effect=write):
            with self.assertRaisesRegex(RuntimeError, 'evidence identity changed'): self.run_archive()
        self.assertTrue(self.binary.exists()); self.assertTrue(self.plist.exists())

    def test_postarchive_executable_reappearance_is_preserved_and_rejected(self):
        self.run_archive()
        unexpected = self.archive / 'kill/mihomo'
        unexpected.write_bytes(b'unknown executable'); unexpected.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, 'unexpected executable'): self.run_archive()
        self.assertEqual(unexpected.read_bytes(), b'unknown executable')

    def test_numeric_receipt_boolean_and_partial_install_rejected(self):
        path = self.base / 'normal/normal-success.json'; original = path.read_bytes()
        value = json.loads(original); value['ownerAbsent'] = 1; path.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError, 'bool proof'): self.run_archive()
        path.write_bytes(original); self.binary.unlink()
        with self.assertRaises(OSError): self.run_archive()
        self.assertFalse((self.base / a.RECORD).exists()); self.assertTrue(self.plist.exists())


if __name__ == '__main__': unittest.main()
