import hashlib
import importlib.util
import json
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

d = load('core_driver', 'core-driver.py')
p = load('core_prepare', 'prepare-core.py')
A = {'format':1, 'normalEpoch':'9913EF14-7359-4007-A87D-D0C396905221', 'killEpoch':'2E39365F-9492-417D-A8A6-EAAB249B1214',
     'fixtureSHA256':'a'*64, 'coreSHA256':'b'*64, 'coreArchiveSHA256':'c'*64, 'normalConfigSHA256':'d'*64, 'killConfigSHA256':'e'*64}
ABSENT = {'supervisor':{'state':'absent'}, 'child':{'state':'absent'}, 'groupObservationKnown':True, 'groupMembers':[], 'workExists':False, 'ownerExists':False}

def job_text():
    return 'program = '+str(d.BINARY)+'\narguments = {\n'+'\n'.join(d.plist_for(A,'normal')['ProgramArguments'])+'\n}\nstate = not running\nruns = 1\nlast exit code = 0\n'

def receipt():
    return {'format':1, 'stage':'normal', 'epoch':A['normalEpoch'], 'status':'passed', 'approvalSHA256':hashlib.sha256(json.dumps(A,sort_keys=True,separators=(',',':')).encode()).hexdigest(),
            'fixtureSHA256':A['fixtureSHA256'], 'coreSHA256':A['coreSHA256'], 'childReaped':True, 'workAbsent':True, 'ownerAbsent':True,
            'termination':{'request':'SIGTERM','observed':True,'exitCode':0,'signal':None}, 'error':''}

class CoreDriverTests(unittest.TestCase):
    def test_generated_cleanup_is_bound_to_new_approval_and_rejects_template_change(self):
        source_commit = 'f' * 40
        approval_sha = p.sha(p.json_bytes(A))
        raw = p.cleanup_source(source_commit, A, approval_sha)
        namespace = {'__name__': 'fixed_cleanup_fixture'}
        exec(compile(raw, 'cleanup.py', 'exec'), namespace)
        for key, expected in {'SOURCE':source_commit, 'APPROVAL_SHA':approval_sha,
                'BINARY_SHA':A['fixtureSHA256'], 'CORE_SHA':A['coreSHA256'],
                'NORMAL_EPOCH':A['normalEpoch'], 'KILL_EPOCH':A['killEpoch'],
                'RECORD_NAME':'cleanup-approved-window.json'}.items():
            self.assertEqual(namespace[key], expected)
        self.assertEqual(str(namespace['BASE']), '/Library/Application Support/Clash Kuro/TunLifecycleExperimentA')
        self.assertEqual(len(namespace['targets']()), 4)
        with patch.object(p, 'regular', return_value=b'changed template'):
            with self.assertRaisesRegex(RuntimeError, 'template changed'): p.cleanup_source(source_commit, A, approval_sha)

    def test_generated_cleanup_uses_real_four_file_positive_and_failure_regressions(self):
        # Reuse the reviewed cleaner's actual temporary-file suite with a new approval, not hand-written cleanup models.
        import types
        path = p.HERE / 'root858-cleanup/test_cleanup.py'
        spec = importlib.util.spec_from_file_location('generated_cleanup_suite', path)
        suite_module = importlib.util.module_from_spec(spec); spec.loader.exec_module(suite_module)
        cleaner = types.ModuleType('generated_window_cleanup')
        exec(compile(p.cleanup_source('f'*40, A, p.sha(p.json_bytes(A))), 'cleanup.py', 'exec'), cleaner.__dict__)
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory); (fixture / 'approval.json').write_bytes(p.json_bytes(A))
            with patch.object(suite_module, 'd', cleaner), patch.object(suite_module, 'FROZEN', fixture):
                names = ('test_success_removes_only_four_preserves_unknown_and_idempotent',
                         'test_partial_install_without_record_rejected_no_deletion',
                         'test_durable_approval_precedes_any_unlink',
                         'test_interrupted_each_unlink_retries_with_fresh_absence_checks',
                         'test_same_bytes_replacement_and_changed_mode_rejected',
                         'test_no_fallback_or_partial_kill_proof_accepted')
                suite = unittest.TestSuite(suite_module.CleanupTests(name) for name in names)
                result = unittest.TestResult(); suite.run(result)
                self.assertEqual(result.testsRun, len(names))
                self.assertEqual(result.errors + result.failures, [])

    def test_review_binds_generated_cleanup_and_old_archive_payload(self):
        import plistlib
        with tempfile.TemporaryDirectory(prefix='kuro-lifecycle-core-review-wire-', dir='/private/tmp') as directory:
            review = Path(directory)
            approval = dict(A, fixtureSHA256=p.sha(b'fixture helper'), coreSHA256=p.sha(b'fixture core'))
            approval_bytes = p.json_bytes(approval); approval_sha = p.sha(approval_bytes)
            payload = {'lifecycle-a':b'fixture helper', 'normal/mihomo':b'fixture core', 'kill/mihomo':b'fixture core',
                       'normal.plist':plistlib.dumps(p.plist_for(approval,'normal')), 'kill.plist':plistlib.dumps(p.plist_for(approval,'kill')),
                       'approval.json':approval_bytes, 'core-driver.py':Path(d.__file__).read_bytes(),
                       'experiment-a.py':Path(d.__file__).with_name('experiment-a.py').read_bytes(), 'CORE.md':b'fixture source admission only',
                       'core.lock.json':b'{}', 'cleanup.py':p.cleanup_source('f'*40,approval,approval_sha),
                       'archive-root858.py':(Path(d.__file__).parent/'root858-archive/archive-root858.py').read_bytes()}
            for name, raw in payload.items():
                path = review/name; path.parent.mkdir(mode=0o700,parents=True,exist_ok=True);path.write_bytes(raw)
            artifact=dict(sourceCommit='f'*40,sourceClean=True,sourceBlobsVerified=True,approvalSHA256=approval_sha,
                          fixtureSHA256=approval['fixtureSHA256'],coreSHA256=approval['coreSHA256'],inventory={name:p.sha(raw) for name,raw in payload.items()})
            (review/'artifact.json').write_bytes(p.json_bytes(artifact))
            sums={**artifact['inventory'],'artifact.json':p.sha((review/'artifact.json').read_bytes())}
            (review/'SHA256SUMS').write_text(''.join(value+'  '+name+'\n' for name,value in sums.items()))
            accepted, admitted=d.review(review,approval_sha)
            self.assertEqual(accepted,approval);self.assertEqual(admitted,payload)
            (review/'cleanup.py').write_bytes(b'changed cleanup')
            with self.assertRaisesRegex(RuntimeError,'inventory changed'):d.review(review,approval_sha)

    def test_native_observer_serialization_preserves_boolean_wire_types(self):
        # Compile the exact production result builder and serializer, not @YES samples.
        source = (p.HERE / 'lifecycle-core.m').read_text()
        builder = source[source.index('static NSDictionary *LCInspectResult('):source.index('static int LCInspect(')]
        inspect = source[source.index('static int LCInspect('):source.index('static int LCSelfTest(')]
        self.assertIn('LCInspectResult(', inspect)
        helper = (p.REPO / 'apps/desktop/native/mac/kuro-tun-helper.m').read_text()
        serializer = next(line for line in helper.splitlines() if line.startswith('static NSData *JSONData('))
        main = r'''int main(void) { @autoreleasepool {
          for (unsigned bits=0;bits<8;bits++) {
            NSArray *members=(bits&1)?@[]:nil;
            NSDictionary *result=LCInspectResult(@"9913EF14-7359-4007-A87D-D0C396905221",@{@"state":@"absent"},@{@"state":@"absent"},members,5,(BOOL)((bits&2)!=0),(BOOL)((bits&4)!=0),nil);
            NSData *bytes=JSONData(result);fwrite(bytes.bytes,1,bytes.length,stdout);puts("");
          }
        } return 0; }'''
        with tempfile.TemporaryDirectory() as directory:
            native = Path(directory) / 'wire.m'; binary = Path(directory) / 'wire'
            native.write_text('#import <Foundation/Foundation.h>\n' + serializer + '\n' + builder + main)
            subprocess.run(['/usr/bin/clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-O2', '-framework', 'Foundation', str(native), '-o', str(binary)], check=True, capture_output=True, timeout=30)
            values = [json.loads(line) for line in subprocess.check_output([str(binary)], text=True, timeout=5).splitlines()]
        self.assertEqual(len(values), 8)
        for bits, value in enumerate(values):
            for field, mask in (('groupObservationKnown', 1), ('workExists', 2), ('ownerExists', 4)):
                self.assertIs(type(value[field]), bool)
                self.assertIs(value[field], bool(bits & mask))
            if bits & 1:
                d.absent(value)
            else:
                with self.assertRaises(RuntimeError): d.absent(value)
        legacy = dict(values[1], groupObservationKnown=1)
        with self.assertRaises(RuntimeError): d.absent(legacy)
        with patch.object(d, 'installed'), patch.object(d, 'inspect', return_value=legacy), patch.object(d.u, 'launch') as launch:
            with self.assertRaises(RuntimeError): d.retire(A, 'normal')
            launch.assert_not_called()

    def test_exact_plist_inherits_group_and_closed_cli(self):
        value = p.plist_for(A, 'normal')
        self.assertEqual(value, d.plist_for(A, 'normal'))
        self.assertIs(value['AbandonProcessGroup'], False)
        self.assertIs(value['RunAtLoad'], False)
        self.assertEqual(value['ProgramArguments'][1:], ['--core-supervisor','normal',A['normalEpoch']])
        with self.assertRaises(RuntimeError): p.plist_for(A,'anything')

    def test_distinct_epochs_and_closed_approval(self):
        self.assertEqual(d.approval_value(A.copy()), A)
        for bad in (dict(A, killEpoch=A['normalEpoch']), dict(A, extra=True), dict(A, format=True), dict(A, coreSHA256='wrong')):
            with self.assertRaises(RuntimeError): d.approval_value(bad)

    def test_protected_normal_success_closed_booleans_and_pins(self):
        d.normal_receipt(receipt(), A)
        for key in ('childReaped','workAbsent','ownerAbsent'):
            with self.assertRaises(RuntimeError): d.normal_receipt(dict(receipt(), **{key:1}), A)
        for key in ('epoch','coreSHA256','fixtureSHA256','approvalSHA256','status','error'):
            with self.assertRaises(RuntimeError): d.normal_receipt(dict(receipt(), **{key:'wrong'}), A)
        bad=receipt();bad['termination']['request']='none'
        with self.assertRaises(RuntimeError): d.normal_receipt(bad,A)
        bad=receipt();bad['termination']['exitCode']=37
        with self.assertRaises(RuntimeError): d.normal_receipt(bad,A)

    def test_unknown_reused_live_or_incomplete_group_never_absent(self):
        d.absent(ABSENT)
        for value in (dict(ABSENT,child={'state':'unknown'}), dict(ABSENT,supervisor={'state':'identity-mismatch-do-not-signal'}), dict(ABSENT,groupObservationKnown=False), dict(ABSENT,groupMembers=[5])):
            with self.assertRaises(RuntimeError): d.absent(value)

    def test_normal_success_receipt_does_not_mask_job_exit_failure(self):
        text=job_text()
        d.normal_job_passed(text,A)
        for bad in (text.replace('last exit code = 0','last exit code = 2'),text.replace('last exit code = 0','last exit code = (never exited)'),text.replace('last exit code = 0',''),text.replace('runs = 1','runs = 2'),text+'pid = 42\n',text+'last terminating signal = Killed: 9\n'):
            with self.assertRaises(RuntimeError):d.normal_job_passed(bad,A)
        with patch.object(d,'installed'),patch.object(d,'read',return_value=json.dumps(receipt()).encode()),patch.object(d,'inspect',return_value=ABSENT),patch.object(d.u,'job',return_value=text.replace('last exit code = 0','last exit code = 2')),patch.object(d.u,'launch') as launch:
            with self.assertRaises(RuntimeError):d.prepare_kill(A,{})
            launch.assert_not_called()

    def test_job_exact_stage_epoch_and_live_pid(self):
        text='program = '+str(d.BINARY)+'\narguments = {\n'+'\n'.join(d.plist_for(A,'kill')['ProgramArguments'])+'\n}\npid = 42\n'
        d.job_matches(text,A,'kill',42)
        for stage,pid in (('normal',42),('kill',43)):
            with self.assertRaises(RuntimeError):d.job_matches(text,A,stage,pid)

    def test_attempt_unknown_file_blocks_start_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);(base/'normal').mkdir();(base/'normal/mihomo').touch();(base/'normal/attempt.json').touch()
            with patch.object(d,'BASE',base),patch.object(d,'installed'),patch.object(d.u,'job',return_value=None),patch.object(d.u,'launch') as launch:
                with self.assertRaises(RuntimeError):d.start(A,'normal')
                launch.assert_not_called()

    def test_result_can_precede_atomic_success_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);(base/'normal').mkdir();(base/'normal/result.json').write_text(json.dumps(receipt()))
            def wait(_):
                (base/'normal/normal-success.json').write_text(json.dumps(receipt()))
            with patch.object(d,'BASE',base),patch.object(d,'start'),patch.object(d,'read',side_effect=lambda path,*_:path.read_bytes()),patch.object(d,'inspect',return_value=ABSENT),patch.object(d.u,'job',return_value=job_text()),patch.object(d.time,'sleep',side_effect=wait):
                d.normal(A)
            self.assertTrue((base/'normal/normal-success.json').exists())

    def test_prepare_kill_unknown_preserves_job_and_plist(self):
        with patch.object(d,'installed'),patch.object(d,'read',return_value=json.dumps(receipt()).encode()),patch.object(d,'inspect',return_value=dict(ABSENT,child={'state':'unknown'})),patch.object(d.u,'launch') as launch:
            with self.assertRaises(RuntimeError):d.prepare_kill(A,{})
            launch.assert_not_called()

    def test_kill_unknown_cannot_signal_persisted_pid(self):
        evidence={'epoch':A['killEpoch'],'supervisor':{'pid':42},'child':{'pid':43}}
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(d,'BASE',Path(directory)),patch.object(d,'start'),patch.object(d,'read',return_value=json.dumps(evidence).encode()),patch.object(d,'inspect',return_value=dict(ABSENT,child={'state':'unknown'})),patch.object(d.u,'launch') as launch,patch.object(d.time,'monotonic',side_effect=[1,100]):
                with self.assertRaises(RuntimeError):d.kill_test(A)
                launch.assert_not_called()

    def test_retire_unknown_cannot_bootout_or_delete(self):
        with patch.object(d,'installed'),patch.object(d,'inspect',return_value=dict(ABSENT,child={'state':'unknown'})),patch.object(d.u,'launch') as launch:
            with self.assertRaises(RuntimeError):d.retire(A,'kill')
            launch.assert_not_called()

    def test_reject_symlink_and_nonregular_read(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);(base/'file').write_text('known');(base/'link').symlink_to(base/'file')
            self.assertEqual(d.read(base/'file'),b'known')
            with self.assertRaises(OSError):d.read(base/'link')
            with self.assertRaises(RuntimeError):d.read(base)

    def test_nonroot_system_entry_does_not_launch(self):
        with patch('sys.argv',['core-driver.py','normal','--review','/private/tmp/kuro-lifecycle-core-review-test','--approval-sha','a'*64]),patch.object(d.os,'geteuid',return_value=501),patch.object(d.u,'launch') as launch:
            with self.assertRaises(RuntimeError):d.main()
            launch.assert_not_called()

    def test_builder_reads_exact_committed_source_blobs(self):
        source_commit='a'*40
        data=b'reviewed source'
        with patch.object(p.subprocess,'check_output',side_effect=[(source_commit+'\n').encode(),b'',data]) as command:
            p.verify_source(source_commit,{'only.m':p.sha(data)})
            self.assertEqual(command.call_args_list[-1].args[0],['/usr/bin/git','show',source_commit+':only.m'])
        with patch.object(p.subprocess,'check_output',side_effect=[(source_commit+'\n').encode(),b'',b'other bytes']):
            with self.assertRaises(RuntimeError):p.verify_source(source_commit,{'only.m':p.sha(data)})
        with patch.object(p.subprocess,'check_output',side_effect=[(source_commit+'\n').encode(),b' M only.m']):
            with self.assertRaises(RuntimeError):p.verify_source(source_commit,{'only.m':p.sha(data)})

    def test_reused_source_has_no_group_or_environment_branch_in_session(self):
        source=(p.REPO/'apps/desktop/native/mac/tun-session.m').read_text()
        spawn=source[source.index('- (BOOL)spawnExecutable:'):source.index('- (BOOL)reapUntil:')]
        self.assertNotIn('POSIX_SPAWN_SETPGROUP',spawn)
        self.assertNotIn('posix_spawnattr_setpgroup',spawn)
        self.assertIn('"PATH=/usr/bin:/bin", "LANG=C", NULL',spawn)
        own=(p.HERE/'lifecycle-core.m').read_text()
        run=own[own.index('static int LCRun('):own.index('static int LCInspect(')]
        self.assertNotIn('ExperimentWorker(',run)
        self.assertNotIn('ExperimentGuardian(',run)
        self.assertNotIn('setpgid(',run)
        self.assertNotIn('setsid(',run)

class IndependentRecoveryTests(unittest.TestCase):
    def setUp(self):
        import contextlib
        import ctypes
        import errno
        import os
        from types import SimpleNamespace
        from unittest.mock import Mock
        self.ctypes = ctypes; self.errno = errno
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(patch.object(d, 'BASE', self.base))
        self.stack.enter_context(patch.object(d, 'installed'))
        self.stack.enter_context(patch.object(d.u, 'chain'))
        original_read = d.read
        self.stack.enter_context(patch.object(d, 'read', side_effect=lambda path, _owner, limit: original_read(path, os.geteuid(), limit)))
        self.stack.enter_context(patch.object(d.time, 'sleep'))
        self.inspect = self.stack.enter_context(patch.object(d, 'inspect', side_effect=AssertionError('recovery must not execute native acceptance observer')))
        self.observer = d.cleanup_module({'cleanup.py':p.cleanup_source('f'*40, A, p.sha(p.json_bytes(A)))}, Path('/private/tmp/review-fixture'))
        self.kernel = 'absent'; self.loaded = True; self.pid_reads = 0; self.mutate = False
        def pid_info(_pid, _flavor, _arg, _buffer, _size):
            self.pid_reads += 1
            if self.mutate and self.pid_reads == 2:
                value = json.loads(self.record.read_bytes()); value['child']['startMicros'] += 1
                self.record.write_text(json.dumps(value))
            ctypes.set_errno(errno.ESRCH if self.kernel in ('absent','group-live','group-unknown') else errno.EPERM if self.kernel == 'unknown' else 0)
            return 136 if self.kernel == 'live' else 0
        def group_info(_type, _group, members, _size):
            if self.kernel == 'group-live': members[0] = 99999
            ctypes.set_errno(errno.EPERM if self.kernel == 'group-unknown' else 0)
            return -1 if self.kernel == 'group-unknown' else 4 if self.kernel == 'group-live' else 0
        library = SimpleNamespace(proc_pidinfo=Mock(side_effect=pid_info), proc_listpids=Mock(side_effect=group_info))
        self.stack.enter_context(patch.object(self.observer['ctypes'], 'CDLL', return_value=library))
        def launch(*args):
            if args[0] == 'print':
                return SimpleNamespace(returncode=0 if self.loaded else 113, stdout=self.text if self.loaded else '', stderr='' if self.loaded else 'Could not find service')
            self.assertEqual(args, ('bootout', 'system/' + d.LABEL)); self.loaded = False
            return SimpleNamespace(returncode=0)
        self.launch = self.stack.enter_context(patch.object(d.u, 'launch', side_effect=launch))
        self.configure_stage('normal')

    def configure_stage(self, stage):
        self.stage = stage; directory = self.base / stage
        directory.mkdir(mode=0o700, exist_ok=True)
        self.record = directory / 'evidence.json'
        value = dict(format=1, stage=stage, epoch=A[stage+'Epoch'], coreSHA256=A['coreSHA256'], fixtureSHA256=A['fixtureSHA256'], startedMilliseconds=1,
                     supervisor=dict(pid=6000,startSeconds=100,startMicros=0,processGroup=6000,executable=str(d.BINARY)),
                     child=dict(pid=6001,startSeconds=101,startMicros=1,processGroup=6000,executable=str(directory/'mihomo')))
        self.record.write_text(json.dumps(value)); self.record.chmod(0o600)
        # Nonzero original exit is not stage acceptance; exact kernel absence still permits only job retirement.
        self.text = 'program = '+str(d.BINARY)+'\narguments = {\n'+'\n'.join(d.plist_for(A,stage)['ProgramArguments'])+'\n}\nstate = not running\nruns = 1\nlast exit code = 37\n'

    def test_numeric_acceptance_refused_but_independent_exact_job_recovery_succeeds(self):
        for stage in ('normal','kill'):
            with self.subTest(stage=stage):
                self.configure_stage(stage); self.loaded = True; self.launch.reset_mock()
                with self.assertRaises(RuntimeError): d.absent(dict(ABSENT, groupObservationKnown=1))
                before = {path:path.read_bytes() for path in self.base.rglob('*') if path.is_file()}
                d.recover_retire(A,stage,self.observer)
                self.assertFalse(self.loaded); self.inspect.assert_not_called()
                self.assertEqual([call.args for call in self.launch.call_args_list if call.args[0]!='print'], [('bootout','system/'+d.LABEL)])
                self.assertEqual({path:path.read_bytes() for path in self.base.rglob('*') if path.is_file()},before)
                self.launch.reset_mock(); d.recover_retire(A,stage,self.observer)
                self.assertFalse(any(call.args[0]!='print' for call in self.launch.call_args_list))

    def test_live_unknown_wrong_epoch_changed_evidence_and_job_rejected(self):
        for state in ('live','unknown','group-live','group-unknown'):
            self.kernel = state
            with self.assertRaises(RuntimeError): d.recover_retire(A,'normal',self.observer)
            self.assertTrue(self.loaded); self.launch.assert_not_called()
        self.kernel = 'absent'; original = self.record.read_bytes()
        value=json.loads(original);value['epoch']=A['killEpoch'];self.record.write_text(json.dumps(value))
        with self.assertRaises(RuntimeError):d.recover_retire(A,'normal',self.observer)
        self.launch.assert_not_called();self.record.write_bytes(original)
        self.mutate=True;self.pid_reads=0
        with self.assertRaisesRegex(RuntimeError,'evidence changed'):d.recover_retire(A,'normal',self.observer)
        self.assertFalse(any(call.args[0]!='print' for call in self.launch.call_args_list));self.assertTrue(self.loaded)
        self.record.write_bytes(original);self.mutate=False;self.launch.reset_mock()
        self.text += 'pid = 6000\n'
        with self.assertRaisesRegex(RuntimeError,'not stopped'):d.recover_retire(A,'normal',self.observer)
        self.assertFalse(any(call.args[0]!='print' for call in self.launch.call_args_list));self.assertTrue(self.loaded)

if __name__=='__main__':unittest.main()
