#!/usr/bin/python3
"""Test-only fixed-path driver. Never run system commands during offline tests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import struct
import re
import stat
import subprocess
import time
import uuid

LABEL = 'dev.kuro.tun.lifecycle-a'
BINARY = Path('/Library/PrivilegedHelperTools') / LABEL
DIRECTORY = Path('/Library/Application Support/Clash Kuro/TunLifecycleExperimentA')
PLIST = Path('/Library/LaunchDaemons') / (LABEL + '.plist')
REVIEW = Path('/private/tmp/kuro-lifecycle-a-review')
BUILD = Path('/private/tmp/kuro-lifecycle-a/lifecycle-a')
ALLOWED = {'approval.json', 'evidence.json', 'stop.json', 'child-exit.json'}

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def epoch_ok(epoch):
    return str(uuid.UUID(epoch)).upper() == epoch

def architecture(data):
    require(len(data) >= 32, 'truncated Mach-O')
    magic, cpu = struct.unpack('<II', data[:8])
    expected = {'arm64': 0x0100000c, 'x86_64': 0x01000007}.get(platform.machine())
    require(magic == 0xfeedfacf and cpu == expected, 'binary architecture does not match this macOS host')

def plist_for(epoch):
    return {'Label': LABEL, 'ProgramArguments': [str(BINARY), '--supervisor', epoch],
            'RunAtLoad': False, 'KeepAlive': False, 'AbandonProcessGroup': False}

def protected(path, directory=False):
    info = path.lstat()
    require(info.st_uid == 0 and not info.st_mode & 0o6022, f'unsafe owner/mode: {path}')
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
            f'unsafe type/link count: {path}')
    # Fixed paths contain no newlines. ls emits additional lines for ACL entries.
    acl = subprocess.run(['/bin/ls', '-lde', str(path)], capture_output=True, text=True, check=True)
    require(len(acl.stdout.splitlines()) == 1, f'ACL requires manual review: {path}')

def chain(path, leaf_directory=False):
    for item in list(reversed(path.parents)) + [path]:
        protected(item, item != path or leaf_directory)

def read_file(path, owner=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and not before.st_mode & 0o6022,
                f'unsafe input file: {path}')
        require(owner is None or before.st_uid == owner, f'wrong input owner: {path}')
        require(before.st_size <= 4 * 1024 * 1024, f'oversized input: {path}')
        data = b''
        while len(data) <= before.st_size:
            part = os.read(fd, min(65536, before.st_size + 1 - len(data)))
            if not part:
                break
            data += part
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) and len(data) == before.st_size,
                f'input changed: {path}')
        return data
    finally:
        os.close(fd)

def write_new(path, data, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fchmod(output.fileno(), mode)
            os.fsync(output.fileno())
    except BaseException:
        # Preserve partial evidence. No guessed rollback.
        raise

def launch(*args):
    return subprocess.run(['/bin/launchctl', *args], capture_output=True, text=True,
                          env={'PATH': '/usr/bin:/bin', 'LANG': 'C'}, timeout=10)

def job():
    result = launch('print', 'system/' + LABEL)
    if result.returncode == 0:
        return result.stdout
    require(result.returncode in (3, 113) and 'Could not find service' in result.stderr,
            'launchd absence is unknown; preserve files')
    return None

def job_matches(text, epoch, supervisor_pid=None):
    require(text is not None and re.search(r'^\s*program = ' + re.escape(str(BINARY)) + r'\s*$', text, re.M),
            'job fixed program mismatch')
    match = re.search(r'arguments = \{\s*([^}]*)\}', text)
    require(match and match.group(1).split() == [str(BINARY), '--supervisor', epoch], 'job epoch/arguments mismatch')
    if supervisor_pid is not None:
        require(re.search(r'^\s*pid = ' + str(supervisor_pid) + r'\s*$', text, re.M), 'job PID differs from evidence')

def verified(epoch, sha):
    require(epoch_ok(epoch) and re.fullmatch('[0-9a-f]{64}', sha), 'invalid epoch/hash')
    chain(BINARY)
    chain(PLIST)
    chain(DIRECTORY, True)
    for name in DIRECTORY.iterdir():
        require(name.name in ALLOWED, 'unknown file preserved: ' + str(name))
        protected(name)
    binary = read_file(BINARY, 0)
    architecture(binary)
    require(digest(binary) == sha, 'installed binary hash mismatch')
    require(plistlib.loads(read_file(PLIST, 0)) == plist_for(epoch), 'installed plist mismatch')
    approval = json.loads(read_file(DIRECTORY / 'approval.json', 0))
    require(approval == {'epoch': epoch, 'sha256': sha}, 'approval mismatch')

def inspect(epoch):
    # Missing evidence is unknown. Never infer absence from an observer failure.
    result = subprocess.run([str(BINARY), '--inspect', epoch], capture_output=True, text=True, timeout=5)
    require(result.returncode == 0, 'observer/evidence unavailable; preserve files')
    state = json.loads(result.stdout)
    require(state.get('epoch') == epoch, 'observer epoch mismatch')
    print(json.dumps(state, sort_keys=True), flush=True)
    return state

def evidence(epoch):
    value = json.loads(read_file(DIRECTORY / 'evidence.json', 0))
    require(value.get('epoch') == epoch and value.get('label') == LABEL, 'evidence epoch/label mismatch')
    return value

def prepare():
    require(os.geteuid() != 0, 'prepare is ordinary-user only')
    data = read_file(BUILD, os.getuid())
    architecture(data)
    epoch = str(uuid.uuid4()).upper()
    # Fixed directory must not exist; no overwrite or cleanup of prior review.
    REVIEW.mkdir(mode=0o700)
    write_new(REVIEW / 'lifecycle-a', data, 0o755)
    write_new(REVIEW / 'experiment.plist', plistlib.dumps(plist_for(epoch), sort_keys=True), 0o600)
    write_new(REVIEW / 'approval.json', json.dumps({'epoch': epoch, 'sha256': digest(data)}).encode(), 0o600)
    print(json.dumps({'review': str(REVIEW), 'epoch': epoch, 'sha256': digest(data)}, indent=2))

def install(epoch, sha):
    require(epoch_ok(epoch) and re.fullmatch('[0-9a-f]{64}', sha), 'invalid epoch/hash')
    require(job() is None, 'test job already exists')
    for path in (BINARY, PLIST, DIRECTORY):
        require(not os.path.lexists(path), 'existing resource preserved: ' + str(path))
        parent = path.parent
        if parent == DIRECTORY.parent and not os.path.lexists(parent):
            chain(parent.parent, True)
        else:
            chain(parent, True)
    info = REVIEW.lstat()
    require(stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o077 and not REVIEW.is_symlink(), 'unsafe review directory')
    data = read_file(REVIEW / 'lifecycle-a')
    architecture(data)
    approval = read_file(REVIEW / 'approval.json')
    plist = read_file(REVIEW / 'experiment.plist')
    require(digest(data) == sha and json.loads(approval) == {'epoch': epoch, 'sha256': sha}
            and plistlib.loads(plist) == plist_for(epoch), 'review payload/hash mismatch')
    # Copy already-read, pinned bytes; never run source or follow it at root.
    if not os.path.lexists(DIRECTORY.parent):
        DIRECTORY.parent.mkdir(mode=0o755)  # One fixed shared ancestor, never chmod an existing one.
    chain(DIRECTORY.parent, True)
    DIRECTORY.mkdir(mode=0o700)
    write_new(DIRECTORY / 'approval.json', approval, 0o600)
    write_new(BINARY, data, 0o755)
    write_new(PLIST, plist, 0o644)
    verified(epoch, sha)
    print('Installed test files only; job has not been loaded. No automatic partial-install rollback.')

def run(epoch):
    require(job() is None, 'test job already present; no restart')
    require(not (DIRECTORY / 'evidence.json').exists() and not (DIRECTORY / 'stop.json').exists(), 'prior evidence/stop preserved')
    result = launch('bootstrap', 'system', str(PLIST))
    require(result.returncode == 0, 'bootstrap failed; preserve files: ' + result.stderr)
    job_matches(job(), epoch)
    result = launch('kickstart', 'system/' + LABEL)
    require(result.returncode == 0, 'kickstart failed; preserve files: ' + result.stderr)
    deadline = time.monotonic() + 5
    while not (DIRECTORY / 'evidence.json').exists() and time.monotonic() < deadline:
        time.sleep(.1)
    value = evidence(epoch)
    text = job()
    job_matches(text, epoch, value['supervisor']['pid'])
    print('PRESERVE launchctl print before kill: ' + text, flush=True)
    state = inspect(epoch)
    require(state['supervisor'] == state['child'] == 'same-instance-live', 'initial identity not proven')
    print('Within 30 seconds, run kill-test; otherwise use cleanup and a fresh experiment.')

def kill_test(epoch):
    value = evidence(epoch)
    require(not (DIRECTORY / 'stop.json').exists() and not (DIRECTORY / 'child-exit.json').exists(), 'self-stop already requested/observed')
    state = inspect(epoch)
    require(type(state.get('elapsedMilliseconds')) is int and 0 <= state['elapsedMilliseconds'] < 30000,
            'native same-clock observation window expired; use cleanup, not TTL as success')
    require(state['supervisor'] == state['child'] == 'same-instance-live', 'before-kill identity not proven')
    text = job()
    job_matches(text, epoch, value['supervisor']['pid'])
    print('PRESERVE launchctl print before kill: ' + text, flush=True)
    result = launch('kill', 'SIGKILL', 'system/' + LABEL)
    require(result.returncode == 0, 'job-targeted kill failed; preserve evidence')
    time.sleep(1)
    text = job()
    if text is not None: job_matches(text, epoch)
    print('PRESERVE launchctl print at 1s: ' + (text or 'job absent'), flush=True)
    inspect(epoch)
    time.sleep(4)
    text = job()
    if text is not None: job_matches(text, epoch)
    print('PRESERVE launchctl print at 5s: ' + (text or 'job absent'), flush=True)
    state = inspect(epoch)
    passed = (state['supervisor'] == state['child'] == 'absent'
              and type(state.get('elapsedMilliseconds')) is int and state['elapsedMilliseconds'] < 60000
              and not (DIRECTORY / 'stop.json').exists() and not (DIRECTORY / 'child-exit.json').exists())
    print('GROUP-CLEANUP-PASS (this fixture only)' if passed else 'GROUP-CLEANUP-NOT-PROVEN; use cleanup/TTL, not PID signals')

def cleanup(epoch, sha):
    # No unknown process is signalled, even if the recorded PID has been reused.
    value = evidence(epoch)
    print('PRESERVE approval: ' + json.dumps({'epoch': epoch, 'sha256': sha}, sort_keys=True), flush=True)
    print('PRESERVE evidence: ' + json.dumps(value, sort_keys=True), flush=True)
    text = job()
    if text is not None:
        job_matches(text, epoch)
    marker = DIRECTORY / 'stop.json'
    encoded = json.dumps({'epoch': epoch}).encode()
    if marker.exists():
        require(json.loads(read_file(marker, 0)) == {'epoch': epoch}, 'foreign stop marker preserved')
    else:
        write_new(marker, encoded, 0o600)
    deadline = time.monotonic() + 310
    while True:
        state = inspect(epoch)
        if state['supervisor'] == state['child'] == 'absent':
            break
        require(all(state[key] in ('same-instance-live', 'absent') for key in ('supervisor', 'child')),
                'ownership unknown; leave blocked, no PID signal or deletion')
        require(time.monotonic() < deadline, 'bounded cleanup timed out; leave blocked')
        time.sleep(1)
    # The observed job must still be the same approved fixed job before bootout.
    text = job()
    if text is not None:
        job_matches(text, epoch)
        result = launch('bootout', 'system/' + LABEL)
        require(result.returncode == 0, 'bootout failed; preserve files')
    require(job() is None, 'job still present')
    verified(epoch, sha)
    state = inspect(epoch)
    require(state['supervisor'] == state['child'] == 'absent', 'final absence not proven')
    require(evidence(epoch) == value, 'evidence changed; preserve files')
    if (DIRECTORY / 'child-exit.json').exists():
        receipt = json.loads(read_file(DIRECTORY / 'child-exit.json', 0))
        require(set(receipt) == {'epoch', 'reason', 'uptimeMilliseconds'} and receipt['epoch'] == epoch
                and receipt['reason'] in ('stop-marker', 'deadline'), 'foreign/malformed exit receipt preserved')
        print('PRESERVE child receipt: ' + json.dumps(receipt, sort_keys=True), flush=True)
    for name in ('approval.json', 'evidence.json', 'stop.json', 'child-exit.json'):
        path = DIRECTORY / name
        if path.exists():
            path.unlink()
    PLIST.unlink()
    BINARY.unlink()
    DIRECTORY.rmdir()
    print('Exact test resources removed; shared parents and review directory preserved.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'install', 'run', 'kill-test', 'observe', 'cleanup'])
    parser.add_argument('epoch', nargs='?')
    parser.add_argument('sha256', nargs='?')
    args = parser.parse_args()
    if args.operation == 'prepare':
        require(args.epoch is None and args.sha256 is None, 'prepare accepts no extra arguments')
        prepare()
        return
    require(os.geteuid() == 0, 'system steps require explicit administrator execution')
    if args.operation == 'install':
        install(args.epoch, args.sha256)
        return
    verified(args.epoch, args.sha256)
    if args.operation == 'run':
        run(args.epoch)
    elif args.operation == 'kill-test':
        kill_test(args.epoch)
    elif args.operation == 'observe':
        text = job()
        if text is not None:
            job_matches(text, args.epoch)
        inspect(args.epoch)
    else:
        cleanup(args.epoch, args.sha256)

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit('BLOCKED: ' + str(error))
