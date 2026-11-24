#!/usr/bin/python3
"""Proposal only: retire four old858 files and preserve its exact evidence by rename."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time

RETIRE = Path('/private/tmp/kuro-root858-normal-retire-candidate/retire-normal-root858.py')
RETIRE_SHA = '29c5fc0ae37902f77a89ed1f03ff2fcaeabe4dbad541d096d24ab6432a61fd27'
BASE = Path('/Library/Application Support/Clash Kuro/TunLifecycleExperimentA')
ARCHIVE = BASE.with_name('TunLifecycleExperimentA-root858-preserved')
RECORD = 'archive-approved-root858.json'
FILES = {'approval.json', 'normal/attempt.json', 'normal/config.redacted.json',
         'normal/evidence.json', 'normal/launch.json', 'normal/normal-success.json',
         'normal/reaped.json', 'normal/result.json', 'normal/stdout.log', 'normal/stderr.log'}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def modules():
    fd = os.open(RETIRE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and 0 < info.st_size < 32768,
                'invalid pinned recovery module')
        raw = os.read(fd, 32768)
        require(hashlib.sha256(raw).hexdigest() == RETIRE_SHA, 'pinned recovery module changed')
    finally:
        os.close(fd)
    namespace = {'__file__': str(RETIRE), '__name__': 'root858_archive_recovery'}
    exec(compile(raw, str(RETIRE), 'exec'), namespace)
    return namespace, *namespace['modules']()


def directory(o, path):
    o.chain(path, True)
    info = o.node(path, True, 0o700)
    return {key: o.same(info)[key] for key in ('device', 'inode', 'owner', 'group', 'mode')}


def inventory(o, location):
    result = {}
    directory(o, location)
    require({p.name for p in location.iterdir()} <= {'approval.json', 'normal', 'kill', RECORD},
            'unknown top-level evidence preserved')
    for stage in ('normal', 'kill'):
        directory(o, location / stage)
        allowed = {Path(name).name for name in FILES if name.startswith(stage + '/')} | {'mihomo'}
        require({p.name for p in (location / stage).iterdir()} <= allowed, 'unknown stage object preserved')
    for name in sorted(FILES):
        raw, info = o.read(location / name)
        result[name] = dict(sha256=o.sha(raw), **o.same(info))
    return result


def exact_targets(d, o, approval):
    return ((d.PLIST, 0o644, None), (BASE / 'normal/mihomo', 0o755, approval['coreSHA256']),
            (BASE / 'kill/mihomo', 0o755, approval['coreSHA256']),
            (d.BINARY, 0o755, approval['fixtureSHA256']))


def target_snapshot(d, o, approval, target):
    path, mode, pin = target
    raw, info = o.read(path, mode, 128 * 1024 * 1024)
    if pin:
        require(o.sha(raw) == pin, 'fixed target hash changed: ' + str(path))
    else:
        import plistlib
        require(plistlib.loads(raw) == d.plist_for(approval, 'normal'), 'normal plist changed')
    return dict(path=str(path), sha256=o.sha(raw), **o.same(info))


def absent(d, o, identities):
    require(d.u.job() is None, 'job present/unknown; preserve all resources')
    o.processes_absent(identities)


def rename_exclusive(source, destination):
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    library.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    library.renamex_np.restype = ctypes.c_int
    require(library.renamex_np(os.fsencode(source), os.fsencode(destination), 4) == 0,
            'exclusive fixed archive rename failed: errno=' + str(ctypes.get_errno()))


def validate_record(d, o, approval, value):
    require(set(value) == {'format', 'approvalSHA256', 'directories', 'files', 'targets', 'identities', 'evidenceSHA256'}
            and type(value['format']) is int and value['format'] == 1
            and value['approvalSHA256'] == o.APPROVAL_SHA
            and set(value['directories']) == {'', 'normal', 'kill'}
            and set(value['files']) == FILES and type(value['targets']) is list and len(value['targets']) == 4,
            'unknown archive approval preserved')
    for item, target in zip(value['targets'], exact_targets(d, o, approval)):
        path, mode, pin = target
        require(set(item) == {'path', 'sha256', 'device', 'inode', 'owner', 'group', 'mode', 'links', 'size', 'mtimeNS', 'ctimeNS'}
                and item['path'] == str(path) and item['mode'] == mode and item['owner'] == o.OWNER
                and item['links'] == 1 and type(item['sha256']) is str and len(item['sha256']) == 64
                and all(type(item[key]) is int and item[key] >= 0 for key in ('device','inode','owner','group','mode','links','size','mtimeNS','ctimeNS'))
                and (pin is None or item['sha256'] == pin), 'invalid target approval')
    require(set(value['identities']) == {'normal'} and type(value['evidenceSHA256']) is str
            and len(value['evidenceSHA256']) == 64, 'invalid evidence binding')


def evidence_at(d, o, approval, location, value):
    raw, _ = o.read(location / 'normal/evidence.json')
    receipt, _ = o.read(location / 'normal/normal-success.json')
    d.normal_receipt(o.decode(receipt), approval)
    require(o.sha(raw + b'\0' + receipt) == value['evidenceSHA256']
            and o.decode(raw) == value['identities']['normal'], 'archived normal evidence binding changed')
    identity = value['identities']['normal']
    require(set(identity) == {'format','stage','epoch','coreSHA256','fixtureSHA256','supervisor','child','startedMilliseconds'}
            and type(identity['format']) is int and identity['format'] == 1 and identity['stage'] == 'normal'
            and type(identity['startedMilliseconds']) is int and identity['startedMilliseconds'] >= 0, 'invalid original identity shape')
    for name in ('supervisor','child'):
        item = identity[name]
        require(set(item) == {'pid','startSeconds','startMicros','processGroup','executable'}
                and all(type(item[key]) is int and 2 <= item[key] <= 2147483647 for key in ('pid','processGroup'))
                and type(item['startSeconds']) is int and 1 <= item['startSeconds'] <= 9007199254740991
                and type(item['startMicros']) is int and 0 <= item['startMicros'] <= 999999, 'invalid original process identity')
    require(identity['supervisor']['pid'] == identity['supervisor']['processGroup'] == identity['child']['processGroup']
            and identity['supervisor']['pid'] != identity['child']['pid'], 'original group binding changed')
    require(identity['epoch'] == approval['normalEpoch'] and identity['coreSHA256'] == approval['coreSHA256']
            and identity['fixtureSHA256'] == approval['fixtureSHA256']
            and identity['child']['executable'] == str(BASE / 'normal/mihomo')
            and identity['supervisor']['executable'] == str(d.BINARY), 'old epoch/executable binding changed')


def archive(r, d, o):
    approval, _ = d.review(r['REVIEW'], r['APPROVAL_SHA'])
    archived = os.path.lexists(ARCHIVE)
    require(not (archived and os.path.lexists(BASE)), 'both old and archive exist; preserve both')
    location = ARCHIVE if archived else BASE
    record = location / RECORD
    if not os.path.lexists(record):
        require(not archived, 'archive without approved receipt is unknown')
        d.installed(approval, 'normal')
        identities, evidence_hash = r['evidence'](d, approval)
        for _ in range(2):
            absent(d, o, identities)
            time.sleep(.05)
        value = dict(format=1, approvalSHA256=o.APPROVAL_SHA,
                     directories={name: directory(o, BASE / name) for name in ('', 'normal', 'kill')},
                     files=inventory(o, BASE), targets=[target_snapshot(d, o, approval, t) for t in exact_targets(d, o, approval)],
                     identities=identities, evidenceSHA256=evidence_hash)
        o.write_record(record, o.encode(value))
    record_bytes, _ = o.read(record)
    value = o.decode(record_bytes)
    validate_record(d, o, approval, value)
    evidence_at(d, o, approval, location, value)
    o.sync(location)  # Retry a completed record write whose directory fsync previously failed.
    require(inventory(o, location) == value['files'], 'preserved evidence identity changed')
    for name, expected in value['directories'].items():
        require(directory(o, location / name) == expected, 'evidence directory replaced')
    if not archived:
        require(r['evidence'](d, approval) == (value['identities'], value['evidenceSHA256']), 'normal evidence changed')
        targets = exact_targets(d, o, approval)
        # Validate every remaining file before any deletion; missing requires the durable prior approval.
        for target, expected in zip(targets, value['targets']):
            if os.path.lexists(target[0]):
                require(target_snapshot(d, o, approval, target) == expected, 'target changed; preserve all remaining files')
        for target, expected in zip(targets, value['targets']):
            require(o.read(record)[0] == record_bytes and inventory(o, BASE) == value['files'], 'archive approval/evidence changed')
            require(r['evidence'](d, approval) == (value['identities'], value['evidenceSHA256']), 'normal identity changed')
            absent(d, o, value['identities'])
            path = target[0]
            if os.path.lexists(path):
                require(target_snapshot(d, o, approval, target) == expected, 'target changed before removal')
                path.unlink()
            o.sync(path.parent)
        require(all(not os.path.lexists(path) for path, _, _ in targets), 'fixed installation file remains')
        absent(d, o, value['identities'])
        require(inventory(o, BASE) == value['files'] and o.read(record)[0] == record_bytes, 'evidence changed before archive')
        o.chain(BASE.parent, True)
        require(not os.path.lexists(ARCHIVE), 'archive collision preserved')
        rename_exclusive(BASE, ARCHIVE)
    # After a rename/fsync failure the exact archive receipt supports only this final verification, never new deletion.
    o.sync(ARCHIVE.parent)
    require(all(not os.path.lexists(ARCHIVE / stage / 'mihomo') for stage in ('normal', 'kill')),
            'unexpected executable in archived evidence preserved')
    require(not os.path.lexists(BASE) and inventory(o, ARCHIVE) == value['files']
            and o.read(ARCHIVE / RECORD)[0] == record_bytes, 'archive completion unproven')
    require(all(not os.path.lexists(path) for path, _, _ in exact_targets(d, o, approval)), 'installed path reappeared')
    absent(d, o, value['identities'])
    print('OLD858-ARCHIVED: four exact installation files absent; original evidence preserved at ' + str(ARCHIVE)
          + '. No job start, bootout, signal, recursive deletion or acceptance conversion.')


if __name__ == '__main__':
    try:
        require(len(sys.argv) == 1 and os.geteuid() == 0, 'fixed no-argument archival requires next concentrated authorization')
        archive(*modules())
    except Exception as error:
        raise SystemExit('BLOCKED: ' + str(error) + '; preserve all evidence/unknown objects')
