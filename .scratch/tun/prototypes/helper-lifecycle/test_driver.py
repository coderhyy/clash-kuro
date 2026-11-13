import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('driver', str(Path(__file__).with_name('experiment-a.py')))
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
EPOCH = '9913EF14-7359-4007-A87D-D0C396905221'
SHA = 'a' * 64
class DriverTest(unittest.TestCase):
    def test_job_binding(self):
        good = 'program = ' + str(d.BINARY) + '\narguments = {\n' + str(d.BINARY) + '\n--supervisor\n' + EPOCH + '\n}\npid = 42\n'
        d.job_matches(good, EPOCH, 42)
        for value in (good.replace(EPOCH, 'BAD'), good.replace('--supervisor', '--other'), good.replace('pid = 42', 'pid = 43')):
            with self.assertRaises(RuntimeError):
                d.job_matches(value, EPOCH, 42)
    def test_missing_record_never_deletes(self):
        with patch.object(d, 'evidence', side_effect=FileNotFoundError), patch.object(d, 'launch') as launch:
            with self.assertRaises(FileNotFoundError): d.cleanup(EPOCH, SHA)
            launch.assert_not_called()
    def test_wrong_epoch_marker_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'stop.json').write_text(json.dumps({'epoch':'OTHER'}))
            with patch.object(d,'DIRECTORY',base), patch.object(d,'evidence',return_value={}), patch.object(d,'job',return_value=None), patch.object(d,'read_file',side_effect=lambda p, o: p.read_bytes()), patch.object(d,'launch') as launch:
                with self.assertRaises(RuntimeError): d.cleanup(EPOCH,SHA)
                launch.assert_not_called()
                self.assertEqual(json.loads((base/'stop.json').read_bytes())['epoch'],'OTHER')
    def test_unknown_observation_no_bootout(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(d,'DIRECTORY',Path(temporary)), patch.object(d,'evidence',return_value={}), patch.object(d,'job',return_value=None), patch.object(d,'inspect',return_value={'supervisor':'absent','child':'unknown'}), patch.object(d,'launch') as launch:
                with self.assertRaises(RuntimeError):d.cleanup(EPOCH,SHA)
                launch.assert_not_called()
                self.assertTrue((Path(temporary)/'stop.json').exists())
    def test_reused_pid_no_bootout(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(d,'DIRECTORY',Path(temporary)), patch.object(d,'evidence',return_value={}), patch.object(d,'job',return_value=None), patch.object(d,'inspect',return_value={'supervisor':'absent','child':'identity-mismatch-do-not-signal'}), patch.object(d,'launch') as launch:
                with self.assertRaises(RuntimeError):d.cleanup(EPOCH,SHA)
                launch.assert_not_called()
    def test_file_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)/'target'; target.write_text('hello')
            link = Path(temporary)/'link'; link.symlink_to(target)
            with self.assertRaises(OSError):d.read_file(link)
    def test_file_refuses_fifo_without_blocking(self):
        import os
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'pipe'; os.mkfifo(path)
            with self.assertRaises(RuntimeError):d.read_file(path)
    def test_nonroot_system_operation_rejected(self):
        with patch.object(d.os,'geteuid',return_value=501),patch.object(d.sys if hasattr(d,'sys') else __import__('sys'),'argv',['driver','install',EPOCH,SHA]),patch.object(d,'launch') as launch:
            with self.assertRaises(RuntimeError):d.main()
            launch.assert_not_called()
if __name__ == '__main__':unittest.main()
