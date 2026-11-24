#!/usr/bin/python3
"""Offline only: compile fixture and copy locked Core bytes; never execute Core."""
import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import struct
import subprocess
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
BASE = Path('/Library/Application Support/Clash Kuro/TunLifecycleExperimentA')
BINARY = '/Library/PrivilegedHelperTools/dev.kuro.tun.lifecycle-a'
LABEL = 'dev.kuro.tun.lifecycle-a'
TARGETS = {'arm64': ('darwin-arm64', 0x0100000c), 'x86_64': ('darwin-x64', 0x01000007)}

def require(value, message):
    if not value:
        raise RuntimeError(message)

def sha(data):
    return hashlib.sha256(data).hexdigest()

def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()

def regular(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and not info.st_mode & 0o6022, 'unsafe input: ' + str(path))
    return path.read_bytes()

def macho(data):
    require(len(data) >= 32 and struct.unpack('<II', data[:8]) == (0xfeedfacf, TARGETS[platform.machine()][1]) and struct.unpack('<I', data[12:16])[0] == 2, 'wrong executable Mach-O architecture/type')

def plist_for(approval, stage):
    require(stage in ('normal', 'kill'), 'unknown stage')
    return {'Label': LABEL, 'ProgramArguments': [BINARY, '--core-supervisor', stage, approval[stage + 'Epoch']],
            'RunAtLoad': False, 'KeepAlive': False, 'AbandonProcessGroup': False}

def cleanup_source(source_commit, approval, approval_sha):
    # Rebind only the reviewed four-file cleaner; never grant a general cleanup path.
    template = regular(HERE / 'root858-cleanup/cleanup-root858.py')
    require(sha(template) == '768d0938c0d0e321f8152c0328c8a629d0e30379ad57aa3052f1094ccfe482dc', 'reviewed cleanup template changed')
    replacements = {
        'SOURCE': source_commit, 'APPROVAL_SHA': approval_sha,
        'BINARY_SHA': approval['fixtureSHA256'], 'CORE_SHA': approval['coreSHA256'],
        'NORMAL_EPOCH': approval['normalEpoch'], 'KILL_EPOCH': approval['killEpoch'],
        'RECORD_NAME': 'cleanup-approved-window.json',
    }
    text = template.decode()
    for name, value in replacements.items():
        text, count = re.subn(r'^' + name + r" = '[^'\n]*'$", name + ' = ' + repr(value), text, flags=re.M)
        require(count == 1, 'cleanup template binding missing: ' + name)
    return text.replace('root858', 'window').encode()

def source_inventory():
    result = {}
    def visit(path):
        path = path.resolve()
        require(path.is_relative_to(HERE) or path.is_relative_to(REPO / 'apps/desktop/native/mac'), 'import escapes reviewed source')
        relative = str(path.relative_to(REPO))
        if relative in result:
            return
        data = regular(path)
        result[relative] = sha(data)
        for imported in re.findall(rb'^\s*#(?:import|include)\s+"([^"\n]+)"', data, re.M):
            visit(path.parent / imported.decode())
    visit(HERE / 'lifecycle-a.m')
    for name in ('prepare-core.py', 'core-driver.py', 'experiment-a.py', 'test_core_driver.py', 'CORE.md', 'root858-cleanup/cleanup-root858.py', 'root858-archive/archive-root858.py', 'root858-archive/test_archive.py'):
        result[str((HERE / name).relative_to(REPO))] = sha(regular(HERE / name))
    result['apps/desktop/core.lock.json'] = sha(regular(REPO / 'apps/desktop/core.lock.json'))
    return dict(sorted(result.items()))

def verify_source(source_commit, sources):
    def git(*args):
        return subprocess.check_output(['/usr/bin/git', *args], cwd=REPO)
    require(git('rev-parse','HEAD').decode().strip() == source_commit, 'source commit is not current HEAD')
    require(not git('status','--porcelain','--untracked-files=all','--',*sources).strip(), 'commit/freeze every input before preparation')
    for name, expected in sources.items():
        require(sha(git('show',source_commit+':'+name)) == expected, 'source bytes differ from committed blob: '+name)

def prepare(output, source_commit):
    require(os.geteuid() != 0 and platform.system() == 'Darwin' and platform.machine() in TARGETS, 'native ordinary-user macOS build only')
    require(re.fullmatch('[0-9a-f]{40}', source_commit), 'main must provide exact frozen source commit')
    require(output.is_absolute() and str(output).startswith('/private/tmp/kuro-lifecycle-core-review-') and output.parent.resolve() == Path('/private/tmp'), 'fresh fixed-prefix review directory required')
    lock_bytes = regular(REPO / 'apps/desktop/core.lock.json')
    lock = json.loads(lock_bytes)
    target, _ = TARGETS[platform.machine()]
    entry = lock['mihomo']['targets'][target]
    require(lock['mihomo']['version'] == 'v1.19.33' and entry['format'] == 'gz' and re.fullmatch('[0-9a-f]{64}', entry['sha256']), 'fixed Core lock required')
    archive = regular(REPO / 'apps/desktop/resources/.cache' / entry['sha256'])
    require(sha(archive) == entry['sha256'], 'locked cached archive hash changed')
    core = gzip.decompress(archive)
    require(len(core) <= 128 * 1024 * 1024, 'oversized Core executable')
    macho(core)
    sources = source_inventory()
    verify_source(source_commit, sources)
    output.mkdir(mode=0o700)  # EXCL; failed build is retained, never recursively removed.
    binary = output / 'lifecycle-a'
    flags = ['-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-O2', '-DKURO_LIFECYCLE_CORE=1', '-DKURO_CORE_EXPERIMENT=1',
             '-DKURO_EXPERIMENT_CORE_SHA256="' + sha(core) + '"', '-DKURO_EXPERIMENT_ARCHIVE_SHA256="' + sha(archive) + '"',
             '-framework', 'Foundation', '-framework', 'Security', '-framework', 'SystemConfiguration', '-lbsm']
    subprocess.run(['/usr/bin/clang', *flags, str(HERE / 'lifecycle-a.m'), '-o', str(binary)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', str(binary)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)
    runner = regular(binary)
    macho(runner)
    approval = {'format': 1, 'normalEpoch': str(uuid.uuid4()).upper(), 'killEpoch': str(uuid.uuid4()).upper(),
                'fixtureSHA256': sha(runner), 'coreSHA256': sha(core), 'coreArchiveSHA256': sha(archive)}
    for stage in ('normal', 'kill'):
        # Config-only entry executes our reviewed serializer, not the Core.
        config = subprocess.check_output([str(binary), '--config', stage, approval[stage + 'Epoch']], timeout=5)
        value = json.loads(config)
        require(value['tun']['enable'] is False and value['dns']['enable'] is False and all(value[key] == 0 for key in ('port','socks-port','mixed-port','redir-port','tproxy-port')) and b'\\/' not in config, 'unsafe noTUN config')
        approval[stage + 'ConfigSHA256'] = sha(config)
    def write(name, data, mode=0o600):
        fd = os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
    for stage in ('normal', 'kill'):
        (output / stage).mkdir(mode=0o700)
        write(stage + '/mihomo', core, 0o755)
        write(stage + '.plist', plistlib.dumps(plist_for(approval, stage), sort_keys=True))
    write('approval.json', json_bytes(approval))
    write('cleanup.py', cleanup_source(source_commit, approval, sha(json_bytes(approval))))
    write('archive-root858.py', regular(HERE / 'root858-archive/archive-root858.py'))
    for name in ('core-driver.py', 'experiment-a.py', 'CORE.md'):
        write(name, regular(HERE / name))
    write('core.lock.json', lock_bytes)
    inventory = {str(path.relative_to(output)): sha(regular(path)) for path in sorted(output.rglob('*')) if path.is_file()}
    artifact = {'format': 1, 'purpose': 'fixed-core-noTUN-launchd-group-experiment', 'sourceCommit': source_commit,
                'sourceClean': True, 'sourceBlobsVerified': True, 'sourceFiles': sources, 'target': target, 'coreVersion': 'v1.19.33',
                'coreArchiveURL': entry['url'], 'coreArchiveSHA256': sha(archive), 'coreSHA256': sha(core), 'fixtureSHA256': sha(runner),
                'approvalSHA256': sha(json_bytes(approval)), 'inventory': inventory, 'compiler': {'path': '/usr/bin/clang', 'flags': flags},
                'coreExecuted': False, 'installed': False, 'systemActionsExecuted': False,
                'groupPolicy': 'inherited launchd group; no ExperimentWorker/Guardian calls; AbandonProcessGroup=false'}
    require(source_inventory() == sources, 'source changed during offline preparation; keep failed output, do not install')
    verify_source(source_commit, sources)
    write('artifact.json', json_bytes(artifact))
    sums = {str(path.relative_to(output)): sha(regular(path)) for path in sorted(output.rglob('*')) if path.is_file()}
    write('SHA256SUMS', ''.join(value + '  ' + name + '\n' for name, value in sums.items()).encode())
    print(json.dumps({'review': str(output), 'approvalSHA256': artifact['approvalSHA256'], 'fixtureSHA256': sha(runner), 'artifactSHA256': sha(json_bytes(artifact)), 'normalEpoch': approval['normalEpoch'], 'killEpoch': approval['killEpoch'], 'coreExecuted': False}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    args = parser.parse_args()
    prepare(args.output, args.source_commit)
