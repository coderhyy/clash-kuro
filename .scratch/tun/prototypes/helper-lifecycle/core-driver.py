#!/usr/bin/python3
"""Finite fixed-path experiment driver. System operations require a separate window."""
import argparse
import hashlib
import types
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def read(path, owner=None, limit=128 * 1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and not before.st_mode & 0o6022 and 0 <= before.st_size <= limit and (owner is None or before.st_uid == owner), 'unsafe input: ' + str(path))
        data = bytearray()
        while len(data) <= before.st_size:
            part = os.read(fd, min(65536, before.st_size + 1 - len(data)))
            if not part:
                break
            data.extend(part)
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) and len(data) == before.st_size, 'changed input')
        return bytes(data)
    finally:
        os.close(fd)

# Execute exactly the pinned source; Python's valid bytecode cache is not covered by the inventory.
utility_path = Path(__file__).with_name('experiment-a.py')
utility_bytes = read(utility_path, limit=262144)
require(hashlib.sha256(utility_bytes).hexdigest() == '4b1c05025816da23ffe702eaaaa7598c12d4663c0c8836c608f059479ee64953', 'utility source pin changed')
u = types.ModuleType('lifecycle_a_util')
u.__file__ = str(utility_path)
exec(compile(utility_bytes, str(utility_path), 'exec'), u.__dict__)
BASE, BINARY, PLIST, LABEL = u.DIRECTORY, u.BINARY, u.PLIST, u.LABEL
digest, write_new = u.digest, u.write_new
STAGES = ('normal', 'kill')

def sync(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def plist_for(approval, stage):
    require(stage in STAGES, 'invalid stage')
    return {'Label': LABEL, 'ProgramArguments': [str(BINARY), '--core-supervisor', stage, approval[stage + 'Epoch']], 'RunAtLoad': False, 'KeepAlive': False, 'AbandonProcessGroup': False}

def approval_value(value):
    require(set(value) == {'format', 'normalEpoch', 'killEpoch', 'fixtureSHA256', 'coreSHA256', 'coreArchiveSHA256', 'normalConfigSHA256', 'killConfigSHA256'} and type(value['format']) is int and value['format'] == 1, 'closed approval required')
    require(all(u.epoch_ok(value[key]) for key in ('normalEpoch','killEpoch')) and value['normalEpoch'] != value['killEpoch'], 'fresh distinct epochs required')
    require(all(re.fullmatch('[0-9a-f]{64}', value[key]) for key in value if key.endswith('SHA256')), 'invalid hash')
    return value

def review(review_path, approval_sha):
    require(re.fullmatch('[0-9a-f]{64}', approval_sha), 'exact reviewed approval SHA required')
    info = review_path.lstat()
    require(str(review_path).startswith('/private/tmp/kuro-lifecycle-core-review-') and review_path.parent == Path('/private/tmp') and review_path.resolve() == review_path and stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o077, 'unsafe review directory')
    approval_bytes = read(review_path / 'approval.json', limit=16384)
    require(digest(approval_bytes) == approval_sha, 'approval bytes changed')
    approval = approval_value(json.loads(approval_bytes))
    artifact = json.loads(read(review_path / 'artifact.json', limit=262144))
    require(re.fullmatch('[0-9a-f]{40}', artifact.get('sourceCommit','')) and artifact.get('sourceClean') is True and artifact.get('sourceBlobsVerified') is True, 'committed blob-verified source record required')
    require(artifact['approvalSHA256'] == approval_sha and artifact['fixtureSHA256'] == approval['fixtureSHA256'] and artifact['coreSHA256'] == approval['coreSHA256'], 'artifact binding mismatch')
    expected = {'lifecycle-a','normal/mihomo','kill/mihomo','normal.plist','kill.plist','approval.json','core-driver.py','experiment-a.py','CORE.md','core.lock.json','cleanup.py','archive-root858.py'}
    require(set(artifact['inventory']) == expected, 'unknown review inventory entry')
    payload = {name: read(review_path / name) for name in expected}
    require(read(Path(__file__).resolve()) == payload['core-driver.py'] and read(Path(__file__).with_name('experiment-a.py').resolve()) == payload['experiment-a.py'], 'executing driver/utility differs from reviewed bytes')
    require(all(digest(payload[name]) == expected for name, expected in artifact['inventory'].items()), 'review inventory changed')
    sums = read(review_path / 'SHA256SUMS', limit=16384).decode().splitlines()
    expected_sums = {name: digest(payload[name]) for name in expected}
    expected_sums['artifact.json'] = digest(read(review_path / 'artifact.json', limit=262144))
    require(len(sums) == len(expected_sums) and set(sums) == {value + '  ' + name for name, value in expected_sums.items()}, 'completed preparation checksum inventory mismatch/missing')
    require(digest(payload['lifecycle-a']) == approval['fixtureSHA256'] and all(digest(payload[stage + '/mihomo']) == approval['coreSHA256'] and plistlib.loads(payload[stage + '.plist']) == plist_for(approval, stage) for stage in STAGES), 'review fixed payload mismatch')
    return approval, payload

def installed(approval, stage):
    u.chain(BINARY)
    u.chain(PLIST)
    u.chain(BASE, True)
    require(digest(read(BINARY, 0)) == approval['fixtureSHA256'] and approval_value(json.loads(read(BASE / 'approval.json', 0))) == approval and plistlib.loads(read(PLIST, 0)) == plist_for(approval, stage), 'installed identity mismatch')
    for name in STAGES:
        u.chain(BASE / name, True)
        u.chain(BASE / name / 'mihomo')
        require(digest(read(BASE / name / 'mihomo', 0)) == approval['coreSHA256'], 'installed Core copy changed')

def job_matches(text, approval, stage, pid=None):
    require(text is not None and re.search(r'^\s*program = ' + re.escape(str(BINARY)) + r'\s*$', text, re.M), 'job program mismatch')
    match = re.search(r'arguments = \{\s*([^}]*)\}', text)
    require(match and match.group(1).split() == plist_for(approval, stage)['ProgramArguments'], 'job stage/epoch mismatch')
    if pid is not None:
        require(re.search(r'^\s*pid = ' + str(pid) + r'\s*$', text, re.M), 'job live PID mismatch')

def normal_job_passed(text, approval):
    job_matches(text, approval, 'normal')
    require(not re.search(r'^\s*pid = [1-9][0-9]*\s*$', text, re.M)
            and re.search(r'^\s*state = not running\s*$', text, re.M)
            and re.search(r'^\s*runs = 1\s*$', text, re.M)
            and re.search(r'^\s*last exit code = 0\s*$', text, re.M)
            and not re.search(r'^\s*last terminating signal =', text, re.M),
            'normal exact job did not complete with exit0 once; receipt alone cannot unlock kill')

def inspect(approval, stage):
    result = subprocess.run([str(BINARY), '--core-inspect', stage, approval[stage + 'Epoch']], capture_output=True, text=True, timeout=5, env={'PATH':'/usr/bin:/bin','LANG':'C'})
    require(result.returncode == 0, 'native observer unavailable; preserve all evidence')
    value = json.loads(result.stdout)
    require(value['epoch'] == approval[stage + 'Epoch'], 'observer epoch mismatch')
    print(json.dumps(value, sort_keys=True), flush=True)
    return value

def absent(value):
    require(value.get('supervisor') == {'state':'absent'} and value.get('child') == {'state':'absent'} and value.get('groupObservationKnown') is True and value.get('groupMembers') == [], 'exact process/group absence unproven; never signal recorded PID/PGID')

def normal_receipt(value, approval):
    keys = {'format','stage','epoch','status','approvalSHA256','coreSHA256','fixtureSHA256','childReaped','workAbsent','ownerAbsent','termination','error'}
    # Native canonical sorted JSON uses no whitespace; these fields are all ASCII.
    canonical = json.dumps(approval, sort_keys=True, separators=(',', ':')).encode()
    require(set(value) == keys and type(value['format']) is int and value['format'] == 1 and value['stage'] == 'normal' and value['epoch'] == approval['normalEpoch'] and value['status'] == 'passed' and value['error'] == '' and value['approvalSHA256'] == digest(canonical) and value['coreSHA256'] == approval['coreSHA256'] and value['fixtureSHA256'] == approval['fixtureSHA256'], 'protected normal receipt mismatch')
    require(all(value[key] is True for key in ('childReaped','workAbsent','ownerAbsent')), 'normal cleanup bool proof missing')
    termination = value['termination']
    require(set(termination) == {'request','observed','exitCode','signal'} and termination['observed'] is True and termination['request'] in ('SIGTERM','SIGKILL') and ((type(termination['exitCode']) is int and termination['exitCode'] == 0 and termination['signal'] is None) or (termination['exitCode'] is None and termination['signal'] == (15 if termination['request'] == 'SIGTERM' else 9))), 'controlled held termination missing')

def install(approval, payload):
    require(u.job() is None, 'job already exists')
    for path in (BINARY, PLIST, BASE):
        require(not os.path.lexists(path), 'existing resource preserved: ' + str(path))
        if path.parent == BASE.parent and not os.path.lexists(path.parent):
            u.chain(path.parent.parent, True)
        else:
            u.chain(path.parent, True)
    if not os.path.lexists(BASE.parent):
        BASE.parent.mkdir(mode=0o755)
    u.chain(BASE.parent, True)
    BASE.mkdir(mode=0o700)
    write_new(BASE / 'approval.json', payload['approval.json'], 0o600)
    for stage in STAGES:
        (BASE / stage).mkdir(mode=0o700)
        write_new(BASE / stage / 'mihomo', payload[stage + '/mihomo'], 0o755)
    write_new(BINARY, payload['lifecycle-a'], 0o755)
    write_new(PLIST, payload['normal.plist'], 0o644)
    sync(BASE)
    sync(PLIST.parent)
    sync(BINARY.parent)
    installed(approval, 'normal')
    print('Installed fixed experiment only; not bootstrapped. Partial failures are retained.')

def start(approval, stage):
    installed(approval, stage)
    require(u.job() is None, 'existing job is not restarted')
    require({p.name for p in (BASE / stage).iterdir()} == {'mihomo'}, 'attempt/evidence/unknown files already present: no retry')
    result = u.launch('bootstrap', 'system', str(PLIST))
    require(result.returncode == 0, 'bootstrap failed: ' + result.stderr)
    job_matches(u.job(), approval, stage)
    result = u.launch('kickstart', 'system/' + LABEL)
    require(result.returncode == 0, 'kickstart failed: ' + result.stderr)

def normal(approval):
    start(approval, 'normal')
    deadline = time.monotonic() + 12
    while not (BASE / 'normal/normal-success.json').exists() and time.monotonic() < deadline:
        if (BASE / 'normal/result.json').exists():
            result = json.loads(read(BASE / 'normal/result.json', 0, 16384))
            require(result.get('status') == 'passed', 'normal stage reported blocked; keep failed epoch')
        time.sleep(.1)
    normal_receipt(json.loads(read(BASE / 'normal/normal-success.json', 0, 16384)), approval)
    # Receipt is not sufficient: the supervisor may still be exiting after publish.
    until = time.monotonic() + 3
    while True:
        value = inspect(approval, 'normal')
        if value['supervisor'] == value['child'] == {'state':'absent'}:
            break
        require(all(value[key]['state'] in ('absent','same-instance-live') for key in ('supervisor','child')) and time.monotonic() < until, 'normal termination unknown/timed out')
        time.sleep(.05)
    # Read actual kernel identities/group/work twice.
    for _ in range(2):
        value = inspect(approval, 'normal')
        absent(value)
        require(value['workExists'] is False and value['ownerExists'] is False, 'normal work/owner residue')
        time.sleep(.1)
    deadline = time.monotonic() + 3
    while True:
        text = u.job()
        job_matches(text, approval, 'normal')
        code = re.search(r'^\s*last exit code = (-?[0-9]+)\s*$', text, re.M)
        require(code is None or int(code.group(1)) == 0, 'normal job exit was nonzero; success file is not sufficient')
        if code and re.search(r'^\s*state = not running\s*$', text, re.M):
            normal_job_passed(text, approval)
            print('PRESERVE normal job status: ' + text, flush=True)
            break
        require(time.monotonic() < deadline and not re.search(r'^\s*last terminating signal =', text, re.M), 'normal job exit evidence unavailable')
        time.sleep(.05)
    print('NORMAL-PASS; main must independently verify these identities and paths before continuing the distinct kill epoch within the approved window.')

def prepare_kill(approval, payload):
    installed(approval, 'normal')
    normal_receipt(json.loads(read(BASE / 'normal/normal-success.json', 0, 16384)), approval)
    for _ in range(2):
        value = inspect(approval, 'normal')
        absent(value)
        require(not value['workExists'] and not value['ownerExists'], 'normal residue')
    text = u.job()
    normal_job_passed(text, approval)
    require(u.launch('bootout', 'system/' + LABEL).returncode == 0 and u.job() is None, 'normal job absence unknown')
    require(read(PLIST, 0) == payload['normal.plist'], 'normal plist changed')
    temporary = PLIST.with_name(PLIST.name + '.next-' + approval['killEpoch'])
    write_new(temporary, payload['kill.plist'], 0o644)
    require(read(PLIST, 0) == payload['normal.plist'], 'plist changed before replacement')
    os.replace(temporary, PLIST)
    sync(PLIST.parent)
    installed(approval, 'kill')
    print('Distinct kill epoch prepared, not started. No attempt can be repeated.')

def kill_test(approval):
    start(approval, 'kill')
    deadline = time.monotonic() + 7
    while not (BASE / 'kill/evidence.json').exists() and time.monotonic() < deadline:
        time.sleep(.05)
    evidence = json.loads(read(BASE / 'kill/evidence.json', 0, 16384))
    require(evidence['epoch'] == approval['killEpoch'], 'kill evidence missing/mismatch')
    value = inspect(approval, 'kill')
    require(value['supervisor'] == value['child'] == {'state':'same-instance-live'} and value['groupObservationKnown'] is True and set(value['groupMembers']) == {evidence['supervisor']['pid'], evidence['child']['pid']} and type(value['elapsedMilliseconds']) is int and 0 <= value['elapsedMilliseconds'] < 25000, 'finite live job/group window not proven')
    job_matches(u.job(), approval, 'kill', evidence['supervisor']['pid'])
    require(not (BASE / 'kill/result.json').exists() and not (BASE / 'kill/reaped.json').exists(), 'fallback/early reap already happened')
    require(u.launch('kill', 'SIGKILL', 'system/' + LABEL).returncode == 0, 'job-targeted kill failed')
    # No fallback PID/PGID signal. A survivor causes an immediate blocked result.
    for delay in (1, 4):
        time.sleep(delay)
        value = inspect(approval, 'kill')
        absent(value)
        require(not (BASE / 'kill/result.json').exists() and not (BASE / 'kill/reaped.json').exists(), 'supervisor fallback/reap cannot prove launchd cleanup')
    write_new(BASE / 'kill/group-observation.json', json.dumps(value, sort_keys=True).encode(), 0o600)
    sync(BASE / 'kill')
    print('GROUP-CLEANUP-PASS (1s/5s observations only). Owner/work intentionally retained after supervisor death; main independently checks identity/path absence, then reviews exact cleanup.')

def retire(approval, stage):
    installed(approval, stage)
    for _ in range(2):
        absent(inspect(approval, stage))
    text = u.job()
    if text is not None:
        job_matches(text, approval, stage)
        require(not re.search(r'^\s*pid = [1-9][0-9]*\s*$', text, re.M), 'job remains live')
        require(u.launch('bootout', 'system/' + LABEL).returncode == 0 and u.job() is None, 'job unload failed/unknown')
    print('Job absent; root files/evidence retained. No recursive cleanup or persisted-PID adoption. Main must review exact known-file removal separately.')

def cleanup_module(payload, review_path):
    namespace = {'__file__': str(review_path / 'cleanup.py'), '__name__': 'reviewed_fixed_cleanup'}
    exec(compile(payload['cleanup.py'], str(review_path / 'cleanup.py'), 'exec'), namespace)
    return namespace


def recovery_identity(approval, stage):
    directory = BASE / stage
    u.chain(directory, True)
    path = directory / 'evidence.json'
    u.chain(path)
    require(stat.S_IMODE(BASE.lstat().st_mode) == stat.S_IMODE(directory.lstat().st_mode) == 0o700
            and stat.S_IMODE(path.lstat().st_mode) == 0o600, 'recovery evidence must remain root0700/0600')
    raw = read(path, 0, 16384)
    value = json.loads(raw)
    require(set(value) == {'format','stage','epoch','coreSHA256','fixtureSHA256','supervisor','child','startedMilliseconds'}
            and type(value['format']) is int and value['format'] == 1 and value['stage'] == stage
            and value['epoch'] == approval[stage + 'Epoch'] and value['coreSHA256'] == approval['coreSHA256']
            and value['fixtureSHA256'] == approval['fixtureSHA256'] and type(value['startedMilliseconds']) is int
            and value['startedMilliseconds'] >= 0, 'recovery stage/epoch/pins malformed')
    for name, executable in (('supervisor', BINARY), ('child', directory / 'mihomo')):
        item = value[name]
        require(set(item) == {'pid','startSeconds','startMicros','processGroup','executable'}
                and all(type(item[key]) is int and 2 <= item[key] <= 2147483647 for key in ('pid','processGroup'))
                and type(item['startSeconds']) is int and 1 <= item['startSeconds'] <= 9007199254740991
                and type(item['startMicros']) is int and 0 <= item['startMicros'] <= 999999
                and item['executable'] == str(executable), 'recovery process identity malformed')
    require(value['supervisor']['pid'] == value['supervisor']['processGroup'] == value['child']['processGroup']
            and value['supervisor']['pid'] != value['child']['pid'], 'recovery inherited group mismatch')
    return value, raw


def recover_retire(approval, stage, observer):
    # Recovery uses independent kernel reads; a malformed acceptance observer cannot authorize or block it.
    installed(approval, stage)
    identity, raw = recovery_identity(approval, stage)
    for _ in range(3):
        installed(approval, stage)
        require(recovery_identity(approval, stage)[1] == raw, 'recovery evidence changed')
        observer['processes_absent']({stage:identity})
        text = u.job()
        if text is not None:
            job_matches(text, approval, stage)
            require(not re.search(r'^\s*pid = [1-9][0-9]*\s*$', text, re.M)
                    and re.search(r'^\s*state = not running\s*$', text, re.M)
                    and re.search(r'^\s*runs = 1\s*$', text, re.M), 'recovery exact job is not stopped once')
        time.sleep(.05)
    # Recheck after the final observation, immediately before the only permitted mutation.
    require(recovery_identity(approval, stage)[1] == raw, 'recovery evidence changed before bootout')
    observer['processes_absent']({stage:identity})
    text = u.job()
    if text is not None:
        job_matches(text, approval, stage)
        require(not re.search(r'^\s*pid = [1-9][0-9]*\s*$', text, re.M)
                and re.search(r'^\s*state = not running\s*$', text, re.M)
                and re.search(r'^\s*runs = 1\s*$', text, re.M), 'recovery job changed before bootout')
        require(u.launch('bootout', 'system/' + LABEL).returncode == 0, 'recovery fixed job bootout failed')
    require(u.job() is None, 'recovery job absence unproven')
    observer['processes_absent']({stage:identity})
    installed(approval, stage)
    require(recovery_identity(approval, stage)[1] == raw, 'recovery evidence changed after bootout')
    print('RECOVERED-JOB-ONLY: exact stopped job absent; all installation files and evidence retained. This is not stage acceptance.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['install','normal','prepare-kill','kill-test','inspect-normal','inspect-kill','retire-normal','retire-kill','cleanup','recover-normal','recover-kill','archive-old'])
    parser.add_argument('--review', required=True, type=Path)
    parser.add_argument('--approval-sha', required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, 'system driver requires separately authorized root window; never sudo automatically')
    approval, payload = review(args.review, args.approval_sha)
    if args.operation == 'archive-old':
        namespace = {'__file__': str(args.review / 'archive-root858.py'), '__name__': 'reviewed_old858_archive'}
        exec(compile(payload['archive-root858.py'], str(args.review / 'archive-root858.py'), 'exec'), namespace)
        namespace['archive'](*namespace['modules']())
    elif args.operation == 'install': install(approval, payload)
    elif args.operation == 'normal': normal(approval)
    elif args.operation == 'prepare-kill': prepare_kill(approval, payload)
    elif args.operation == 'kill-test': kill_test(approval)
    elif args.operation == 'cleanup':
        cleanup_module(payload, args.review)['cleanup']()
    elif args.operation.startswith('recover-'):
        recover_retire(approval, args.operation.removeprefix('recover-'), cleanup_module(payload, args.review))
    elif args.operation.startswith('inspect-'):
        stage = args.operation.removeprefix('inspect-'); installed(approval, stage); inspect(approval, stage)
    else: retire(approval, args.operation.removeprefix('retire-'))

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit('BLOCKED: ' + str(error) + '; preserve all resources; never signal recorded PID/PGID')
