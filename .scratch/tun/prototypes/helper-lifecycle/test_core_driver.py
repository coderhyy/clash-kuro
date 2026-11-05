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

if __name__=='__main__':unittest.main()
