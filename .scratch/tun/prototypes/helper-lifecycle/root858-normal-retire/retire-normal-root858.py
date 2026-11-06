#!/usr/bin/python3
"""Separately authorized root858 normal-job retirement only. Never removes files."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import time

REVIEW = Path('/private/tmp/kuro-lifecycle-core-review-85834ab')
CLEANUP = Path('/private/tmp/kuro-root858-cleanup-candidate/cleanup-root858.py')
APPROVAL_SHA = 'c20eb39a0032b73a4b6b5b229377642f2504aac30b77fe9ae592b3bb5ed29ec1'
PINS = {REVIEW / 'core-driver.py': '88e2c6b830b51c48498c6c44d32a2a17eeb5700b006854b2b5d4ac9b4836668f',
        REVIEW / 'experiment-a.py': '4b1c05025816da23ffe702eaaaa7598c12d4663c0c8836c608f059479ee64953',
        CLEANUP: '768d0938c0d0e321f8152c0328c8a629d0e30379ad57aa3052f1094ccfe482dc'}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def modules():
    # Execute only already-hashed bytes, including the driver's nested utility import.
    sources = {}
    for path, expected in PINS.items():
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 <= info.st_size <= 131072, 'invalid pinned module: ' + str(path))
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                raw = stream.read(131073)
            require(hashlib.sha256(raw).hexdigest() == expected, 'pinned module bytes changed: ' + str(path))
            sources[path] = raw
        finally:
            os.close(fd)
    original_spec = importlib.util.spec_from_file_location
    class BytesLoader:
        def __init__(self, path): self.path = path
        def create_module(self, _spec): return None
        def exec_module(self, module):
            module.__file__ = str(self.path)
            exec(compile(sources[self.path], str(self.path), 'exec'), module.__dict__)
    def pinned_spec(name, location, **_kwargs):
        path = Path(location)
        require(path in sources, 'unapproved nested module import')
        return original_spec(name, str(path), loader=BytesLoader(path))
    importlib.util.spec_from_file_location = pinned_spec
    try:
        result = []
        for name, path in (('root858_driver', REVIEW / 'core-driver.py'), ('root858_observer', CLEANUP)):
            spec = pinned_spec(name, path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            result.append(module)
        return result
    finally:
        importlib.util.spec_from_file_location = original_spec


def evidence(driver, approval):
    # Same exact normal native identity shape; data is observation-only, never a signal target.
    driver.u.chain(driver.BASE, True)
    require(stat.S_IMODE(driver.BASE.lstat().st_mode) == 0o700, 'evidence base must remain root0700')
    directory = driver.BASE / 'normal'
    driver.u.chain(directory, True)
    require(stat.S_IMODE(directory.lstat().st_mode) == 0o700, 'normal evidence must remain root0700')
    for path in (directory / 'normal-success.json', directory / 'evidence.json'):
        driver.u.chain(path)
        require(stat.S_IMODE(path.lstat().st_mode) == 0o600, 'evidence file must remain root0600')
    receipt_bytes = driver.read(directory / 'normal-success.json', 0, 16384)
    driver.normal_receipt(json.loads(receipt_bytes), approval)
    raw = driver.read(directory / 'evidence.json', 0, 16384)
    value = json.loads(raw)
    require(set(value) == {'format', 'stage', 'epoch', 'coreSHA256', 'fixtureSHA256', 'supervisor', 'child', 'startedMilliseconds'}
            and type(value['format']) is int and value['format'] == 1 and value['stage'] == 'normal'
            and value['epoch'] == approval['normalEpoch'] and value['coreSHA256'] == approval['coreSHA256']
            and value['fixtureSHA256'] == approval['fixtureSHA256'], 'normal epoch/pins mismatch')
    for key, executable in (('supervisor', driver.BINARY), ('child', directory / 'mihomo')):
        identity = value[key]
        require(set(identity) == {'pid', 'startSeconds', 'startMicros', 'processGroup', 'executable'}
                and all(type(identity[k]) is int and 2 <= identity[k] <= 2147483647 for k in ('pid', 'processGroup'))
                and type(identity['startSeconds']) is int and 1 <= identity['startSeconds'] <= 9007199254740991
                and type(identity['startMicros']) is int and 0 <= identity['startMicros'] <= 999999
                and identity['executable'] == str(executable), 'normal process identity malformed')
    require(value['supervisor']['pid'] == value['supervisor']['processGroup'] == value['child']['processGroup']
            and value['supervisor']['pid'] != value['child']['pid'], 'normal inherited group mismatch')
    require(type(value['startedMilliseconds']) is int and value['startedMilliseconds'] >= 0, 'normal clock evidence malformed')
    require(not os.path.lexists(directory / 'owner.json') and not os.path.lexists(directory / 'session-work'), 'normal owner/work remains')
    # No kill attempt/evidence may be present. The original installed() also fixes the normal plist.
    for name in ('attempt.json', 'evidence.json', 'group-observation.json', 'result.json', 'reaped.json', 'owner.json', 'session-work'):
        require(not os.path.lexists(driver.BASE / 'kill' / name), 'kill/other epoch is not eligible for this entry')
    return {'normal': value}, hashlib.sha256(raw + b'\0' + receipt_bytes).hexdigest()


def retire(driver, observer):
    approval, _payload = driver.review(REVIEW, APPROVAL_SHA)
    driver.installed(approval, 'normal')
    identities, evidence_hash = evidence(driver, approval)
    for _ in range(2):
        driver.installed(approval, 'normal')
        require(evidence(driver, approval)[1] == evidence_hash, 'normal evidence changed')
        observer.processes_absent(identities)
        text = driver.u.job()
        if text is not None:
            driver.normal_job_passed(text, approval)
        time.sleep(.1)
    # Last independent readback before the sole mutation; no native bool/int coercion.
    driver.installed(approval, 'normal')
    require(evidence(driver, approval)[1] == evidence_hash, 'normal evidence changed before retirement')
    observer.processes_absent(identities)
    text = driver.u.job()
    if text is not None:
        driver.normal_job_passed(text, approval)
        result = driver.u.launch('bootout', 'system/' + driver.LABEL)
        require(result.returncode == 0, 'exact normal job bootout failed/unknown; preserve everything')
    require(driver.u.job() is None, 'normal job absence unproven after retirement')
    observer.processes_absent(identities)
    driver.installed(approval, 'normal')
    require(evidence(driver, approval)[1] == evidence_hash, 'normal evidence changed after retirement')
    print('NORMAL-JOB-RETIRED: exact normal job and recorded processes/group absent; all files/evidence retained. No Core start, file deletion or PID/group signal.')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 1 and os.geteuid() == 0, 'fixed no-argument normal retirement requires new explicit administrator authorization')
        retire(*modules())
    except Exception as error:
        raise SystemExit('BLOCKED: ' + str(error) + '; preserve all files and evidence; never signal recorded PID/PGID')
