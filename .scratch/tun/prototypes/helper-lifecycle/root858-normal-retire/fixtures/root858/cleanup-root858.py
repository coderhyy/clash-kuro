#!/usr/bin/python3
"""Retire four exact root858 experiment files; preserve every evidence directory."""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import time

SOURCE = '85834ab8bc8d45c24f232883133a58d13b2daa6f'
LABEL = 'dev.kuro.tun.lifecycle-a'
BASE = Path('/Library/Application Support/Clash Kuro/TunLifecycleExperimentA')
BINARY = Path('/Library/PrivilegedHelperTools') / LABEL
PLIST = Path('/Library/LaunchDaemons') / (LABEL + '.plist')
APPROVAL_SHA = 'c20eb39a0032b73a4b6b5b229377642f2504aac30b77fe9ae592b3bb5ed29ec1'
BINARY_SHA = 'e5c949f29785297b8ba8ac5a5be76f8483dea17d0bf7daf20860cbd33daeb1f1'
CORE_SHA = 'f3e8ae41397c08cbf900ce1f7c8a168285d29954e9bca5d84d69a2b2561adfe9'
NORMAL_EPOCH = '91EE2723-A085-485F-A9E9-E24155642B5B'
KILL_EPOCH = '2F6D8E0A-F1A4-445C-A123-44D86B1CE2E3'
RECORD_NAME = 'cleanup-approved-root858.json'
OWNER = 0


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def decode(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def no_acl(path):
    result = subprocess.run(['/bin/ls', '-lde', str(path)], capture_output=True,
                            text=True, check=True, timeout=5)
    require(len(result.stdout.splitlines()) == 1, 'ACL requires manual review: ' + str(path))


def node(path, directory, mode=None):
    info = path.lstat()
    require(info.st_uid == OWNER and not info.st_mode & 0o6022,
            'unsafe owner/permissions: ' + str(path))
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
            'unsafe type/link count: ' + str(path))
    require(mode is None or stat.S_IMODE(info.st_mode) == mode, 'changed permissions: ' + str(path))
    no_acl(path)
    return info


def chain(path, directory=False):
    for item in list(reversed(path.parents)) + [path]:
        node(item, item != path or directory)


def read(path, mode=0o600, limit=131072):
    chain(path)
    before = node(path, False, mode)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        held = os.fstat(fd)
        require(same(before) == same(held) and 0 <= held.st_size <= limit, 'input replaced/oversized: ' + str(path))
        parts = bytearray()
        while len(parts) <= held.st_size:
            part = os.read(fd, min(65536, held.st_size + 1 - len(parts)))
            if not part:
                break
            parts.extend(part)
        require(same(os.fstat(fd)) == same(held) and same(path.lstat()) == same(held) and len(parts) == held.st_size,
                'input changed while read: ' + str(path))
        return bytes(parts), held
    finally:
        os.close(fd)


def same(info):
    return dict(device=info.st_dev, inode=info.st_ino, owner=info.st_uid, group=info.st_gid,
                mode=stat.S_IMODE(info.st_mode), links=info.st_nlink, size=info.st_size,
                mtimeNS=info.st_mtime_ns, ctimeNS=info.st_ctime_ns)


def sync(directory):
    chain(directory, True)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_record(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), 0o600)
            os.fsync(output.fileno())
    except BaseException:
        # Partial/unknown approval is preserved and must block, never overwritten.
        raise
    sync(path.parent)


def job_absent():
    result = subprocess.run(['/bin/launchctl', 'print', 'system/' + LABEL],
                            capture_output=True, text=True, timeout=10,
                            env={'PATH': '/usr/bin:/bin', 'LANG': 'C'})
    require(result.returncode in (3, 113) and 'Could not find service' in result.stderr,
            'exact experiment job is present or absence unknown; no deletion')


def processes_absent(evidence):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    lib.proc_listpids.restype = ctypes.c_int
    for stage, item in evidence.items():
        for name in ('supervisor', 'child'):
            buffer = ctypes.create_string_buffer(4096)
            ctypes.set_errno(0)
            result = lib.proc_pidinfo(item[name]['pid'], 3, 0, buffer, len(buffer))
            require(result == 0 and ctypes.get_errno() == errno.ESRCH,
                    stage + '/' + name + ' PID is live/reused/unknown; never signal it')
        members = (ctypes.c_int * 64)()
        ctypes.set_errno(0)
        count = lib.proc_listpids(2, item['supervisor']['processGroup'], members, ctypes.sizeof(members))
        require(0 <= count < ctypes.sizeof(members) and count % ctypes.sizeof(ctypes.c_int) == 0
                and ctypes.get_errno() == 0 and all(members[i] == 0 for i in range(count // ctypes.sizeof(ctypes.c_int))),
                stage + ' complete process-group absence unknown; no deletion')


def plist_value():
    return dict(Label=LABEL, ProgramArguments=[str(BINARY), '--core-supervisor', 'kill', KILL_EPOCH],
                RunAtLoad=False, KeepAlive=False, AbandonProcessGroup=False)


def proof():
    node(BASE, True, 0o700)
    raw, _ = read(BASE / 'approval.json')
    require(sha(raw) == APPROVAL_SHA, 'not the frozen root858 approval')
    approval = decode(raw)
    hashes = {'approval.json': sha(raw)}
    evidence = {}
    for stage, epoch in (('normal', NORMAL_EPOCH), ('kill', KILL_EPOCH)):
        node(BASE / stage, True, 0o700)
        name = stage + '/evidence.json'
        data, _ = read(BASE / name)
        item = decode(data)
        require(set(item) == {'format', 'stage', 'epoch', 'coreSHA256', 'fixtureSHA256', 'supervisor', 'child', 'startedMilliseconds'}
                and type(item['format']) is int and item['format'] == 1 and item['stage'] == stage and item['epoch'] == epoch
                and item['coreSHA256'] == CORE_SHA and item['fixtureSHA256'] == BINARY_SHA,
                'stage identity/pins changed: ' + stage)
        for who, executable in (('supervisor', BINARY), ('child', BASE / stage / 'mihomo')):
            identity = item[who]
            require(set(identity) == {'pid', 'startSeconds', 'startMicros', 'processGroup', 'executable'}
                    and all(type(identity[k]) is int and identity[k] >= (0 if k == 'startMicros' else 2)
                            for k in ('pid', 'startSeconds', 'startMicros', 'processGroup'))
                    and identity['startMicros'] <= 999999 and identity['pid'] <= 2147483647
                    and identity['processGroup'] <= 2147483647 and identity['executable'] == str(executable),
                    'malformed process identity: ' + stage + '/' + who)
        require(item['supervisor']['pid'] == item['supervisor']['processGroup'] == item['child']['processGroup']
                and item['child']['pid'] != item['supervisor']['pid'], 'unexpected inherited group')
        hashes[name] = sha(data)
        evidence[stage] = item
    data, _ = read(BASE / 'normal/normal-success.json')
    value = decode(data)
    require(set(value) == {'format', 'stage', 'epoch', 'status', 'approvalSHA256', 'coreSHA256', 'fixtureSHA256', 'childReaped', 'workAbsent', 'ownerAbsent', 'termination', 'error'}
            and type(value['format']) is int and value['format'] == 1 and value['stage'] == 'normal'
            and value['epoch'] == NORMAL_EPOCH and value['status'] == 'passed' and value['error'] == ''
            and value['approvalSHA256'] == sha(encode(approval)) and value['coreSHA256'] == CORE_SHA
            and value['fixtureSHA256'] == BINARY_SHA
            and all(value[k] is True for k in ('childReaped', 'workAbsent', 'ownerAbsent')),
            'normal success receipt missing/mismatched')
    ended = value['termination']
    require(set(ended) == {'request', 'observed', 'exitCode', 'signal'} and ended['observed'] is True
            and ended['request'] in ('SIGTERM', 'SIGKILL')
            and ((type(ended['exitCode']) is int and ended['exitCode'] == 0 and ended['signal'] is None)
                 or (ended['exitCode'] is None and type(ended['signal']) is int
                     and ended['signal'] == (15 if ended['request'] == 'SIGTERM' else 9))), 'normal controlled stop missing')
    hashes['normal/normal-success.json'] = sha(data)
    require(not os.path.lexists(BASE / 'normal/owner.json') and not os.path.lexists(BASE / 'normal/session-work'), 'normal cleanup incomplete')
    require(not os.path.lexists(BASE / 'kill/result.json') and not os.path.lexists(BASE / 'kill/reaped.json'), 'kill fallback/reap is not launchd success')
    data, _ = read(BASE / 'kill/group-observation.json')
    observed = decode(data)
    require(set(observed) == {'epoch', 'supervisor', 'child', 'groupMembers', 'groupObservationKnown', 'elapsedMilliseconds', 'workExists', 'ownerExists', 'error'}
            and observed['epoch'] == KILL_EPOCH and observed['supervisor'] == observed['child'] == {'state': 'absent'}
            and observed['groupMembers'] == [] and observed['groupObservationKnown'] is True
            and type(observed['elapsedMilliseconds']) is int and 0 <= observed['elapsedMilliseconds'] < 30000
            and type(observed['workExists']) is bool and type(observed['ownerExists']) is bool and observed['error'] == '',
            'bounded successful kill observation missing')
    hashes['kill/group-observation.json'] = sha(data)
    return hashes, evidence


def targets():
    return ((PLIST, 0o644, None), (BASE / 'normal/mihomo', 0o755, CORE_SHA),
            (BASE / 'kill/mihomo', 0o755, CORE_SHA), (BINARY, 0o755, BINARY_SHA))


def snapshot(path, mode, pin):
    raw, info = read(path, mode, 128 * 1024 * 1024)
    require(sha(raw) == pin if pin else plistlib.loads(raw) == plist_value(), 'target pin/plist differs: ' + str(path))
    return dict(path=str(path), sha256=sha(raw), **same(info))


def validate_record(value, hashes):
    require(set(value) == {'format', 'sourceCommit', 'approvalSHA256', 'evidenceSHA256', 'targets'}
            and type(value['format']) is int and value['format'] == 1 and value['sourceCommit'] == SOURCE
            and value['approvalSHA256'] == APPROVAL_SHA and value['evidenceSHA256'] == hashes
            and type(value['targets']) is list and len(value['targets']) == 4, 'changed/unknown cleanup approval preserved')
    for item, (path, mode, pin) in zip(value['targets'], targets()):
        require(set(item) == {'path', 'sha256', 'device', 'inode', 'owner', 'group', 'mode', 'links', 'size', 'mtimeNS', 'ctimeNS'}
                and item['path'] == str(path) and item['mode'] == mode and item['owner'] == OWNER and item['links'] == 1
                and all(type(item[k]) is int and item[k] >= 0 for k in ('device', 'inode', 'owner', 'group', 'mode', 'links', 'size', 'mtimeNS', 'ctimeNS'))
                and item['size'] <= 128 * 1024 * 1024 and item['inode'] > 0 and len(item['sha256']) == 64
                and (pin is None or item['sha256'] == pin), 'invalid fixed target approval')


def cleanup():
    hashes, evidence = proof()
    for _ in range(2):
        job_absent()
        processes_absent(evidence)
        time.sleep(.05)
    record = BASE / RECORD_NAME
    if not os.path.lexists(record):
        value = dict(format=1, sourceCommit=SOURCE, approvalSHA256=APPROVAL_SHA,
                     evidenceSHA256=hashes, targets=[snapshot(*item) for item in targets()])
        write_record(record, encode(value))
    record_bytes, _ = read(record)
    value = decode(record_bytes)
    validate_record(value, hashes)
    # Retry the directory sync even if the initial exclusive write finished but fsync failed.
    sync(BASE)
    for item, (path, mode, pin) in zip(value['targets'], targets()):
        if os.path.lexists(path):
            require(snapshot(path, mode, pin) == item, 'target identity changed; preserved: ' + str(path))
    for item, (path, mode, pin) in zip(value['targets'], targets()):
        require(proof()[0] == hashes and read(record)[0] == record_bytes, 'cleanup evidence/approval changed')
        job_absent()
        processes_absent(evidence)
        chain(path.parent, True)
        if os.path.lexists(path):
            require(snapshot(path, mode, pin) == item, 'target identity changed; preserved: ' + str(path))
            # A root-only fixed ancestor excludes ordinary-UID replacement during unlink.
            require(same(path.lstat()) == {k: v for k, v in item.items() if k not in ('path', 'sha256')}, 'target replaced before unlink')
            path.unlink()
        sync(path.parent)
    require(all(not os.path.lexists(path) for path, _, _ in targets()), 'cleanup target remains')
    require(proof()[0] == hashes and read(record)[0] == record_bytes, 'final evidence/approval changed')
    job_absent()
    processes_absent(evidence)
    print('CLEANUP-PASS: four exact installation files absent; approval/logs/owner/work/cache and all directories retained. No PID/group signal or recursive deletion.')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 1 and os.geteuid() == 0, 'fixed no-argument root858 cleanup requires a separately authorized root window')
        cleanup()
    except (RuntimeError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit('BLOCKED: ' + str(error) + '; preserve evidence/unknown objects; no guessed cleanup')
