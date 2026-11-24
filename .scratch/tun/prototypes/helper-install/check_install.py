"""Throwaway install-boundary model; no root, process launch, service or network.

Production must anchor at a root-owned directory and check ACLs/code identity too.
Here expected_uid is the test user so negative cases can run in a temporary dir.
"""

import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate manifest key")
        result[key] = value
    return result


def checked_open(parent_fd, name, expected_uid, mode, directory=False):
    if not name or name in (".", "..") or "/" in name:
        raise ValueError("not a single fixed component")
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    if directory:
        flags |= os.O_DIRECTORY
    fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        info = os.fstat(fd)
        if info.st_uid != expected_uid or stat.S_IMODE(info.st_mode) != mode:
            raise ValueError("unexpected owner or permissions")
        if directory:
            if not stat.S_ISDIR(info.st_mode):
                raise ValueError("not a directory")
        elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("not an exclusive regular file")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_snapshot(fd, cap):
    before = os.fstat(fd)
    if before.st_size > cap:
        raise ValueError("file too large")
    data = os.read(fd, cap + 1)
    after = os.fstat(fd)
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    if len(data) > cap or len(data) != before.st_size or stamp(before) != stamp(after):
        raise ValueError("file changed during validation")
    return data


def validate(anchor, expected_manifest_hash, expected_uid):
    """Return inspected bytes; never execute or reopen an approved pathname."""
    anchor_fd = os.open(anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        # anchor is handed over by the fixture; production must validate its ancestry.
        version_fd = checked_open(anchor_fd, "version-1", expected_uid, 0o755, True)
        try:
            manifest_fd = checked_open(version_fd, "manifest.json", expected_uid, 0o644)
            try:
                raw = read_snapshot(manifest_fd, 4096)
            finally:
                os.close(manifest_fd)
            if digest(raw) != expected_manifest_hash:
                raise ValueError("manifest differs from independent approval")
            manifest = json.loads(raw, object_pairs_hook=unique_object)
            if set(manifest) != {"format", "protocol", "core", "helper"}:
                raise ValueError("unexpected manifest field or path")
            if manifest["format"] != "kuro-install-model" or type(manifest["protocol"]) is not int or manifest["protocol"] != 1:
                raise ValueError("unsupported manifest")
            inspected = {}
            for name in ("core", "helper"):
                expected = manifest[name]
                if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
                    raise ValueError("invalid artifact digest")
                fd = checked_open(version_fd, name, expected_uid, 0o755)
                try:
                    data = read_snapshot(fd, 1024 * 1024)
                finally:
                    os.close(fd)
                if digest(data) != expected:
                    raise ValueError("artifact changed")
                inspected[name] = data
            return inspected
        finally:
            os.close(version_fd)
    finally:
        os.close(anchor_fd)


class InstallBoundary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kuro-install-model-")
        self.addCleanup(self.temporary.cleanup)
        self.anchor = Path(self.temporary.name)
        self.version = self.anchor / "version-1"
        self.version.mkdir(mode=0o755)
        self.core = self.version / "core"
        self.helper = self.version / "helper"
        self.manifest = self.version / "manifest.json"
        for path in (self.core, self.helper):
            path.write_bytes(path.name.encode())
            path.chmod(0o755)
        self.policy = {"format": "kuro-install-model", "protocol": 1,
                       "core": digest(b"core"), "helper": digest(b"helper")}
        self.pin = self.write_manifest(self.policy)

    def write_manifest(self, value):
        self.manifest.write_text(json.dumps(value))
        self.manifest.chmod(0o644)
        return digest(self.manifest.read_bytes())

    def check(self, pin=None, uid=None):
        return validate(self.anchor, self.pin if pin is None else pin,
                        os.geteuid() if uid is None else uid)

    def rejected(self):
        with self.assertRaises((ValueError, OSError)):
            self.check()

    def test_valid_fixture(self):
        self.assertEqual(self.check(), {"core": b"core", "helper": b"helper"})

    def test_leaf_symlink(self):
        self.helper.unlink()
        self.helper.symlink_to(self.core)
        self.rejected()

    def test_manifest_symlink(self):
        target = self.anchor / "other.json"
        self.manifest.rename(target)
        self.manifest.symlink_to(target)
        self.rejected()

    def test_directory_symlink(self):
        replacement = self.anchor / "other-version"
        self.version.rename(replacement)
        self.version.symlink_to(replacement, target_is_directory=True)
        self.rejected()

    def test_group_writable_directory(self):
        self.version.chmod(0o775)
        self.rejected()

    def test_writable_helper(self):
        self.helper.chmod(0o777)
        self.rejected()

    def test_setuid_core_metadata(self):
        # Pure metadata injection: do not depend on a filesystem preserving setuid.
        real_fstat = os.fstat
        def injected(fd):
            info = real_fstat(fd)
            if stat.S_ISREG(info.st_mode):
                return SimpleNamespace(st_uid=info.st_uid, st_mode=stat.S_IFREG | 0o4755, st_nlink=1)
            return info
        directory_fd = os.open(self.version, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with patch("os.fstat", side_effect=injected):
                with self.assertRaises(ValueError):
                    checked_open(directory_fd, "core", os.geteuid(), 0o755)
        finally:
            os.close(directory_fd)

    def test_wrong_owner(self):
        with self.assertRaises(ValueError):
            self.check(uid=os.geteuid() + 1)

    def test_hardlink(self):
        os.link(self.core, self.anchor / "core-alias")
        self.rejected()

    def test_replaced_core(self):
        alternate = self.version / "replacement"
        alternate.write_bytes(b"unapproved core")
        alternate.chmod(0o755)
        alternate.replace(self.core)
        self.rejected()

    def test_modified_helper(self):
        self.helper.write_bytes(b"changed helper")
        self.rejected()

    def test_modified_manifest_with_matching_attacker_hash(self):
        self.helper.write_bytes(b"changed helper")
        self.policy["helper"] = digest(b"changed helper")
        self.write_manifest(self.policy)
        self.rejected()  # An attacker-controlled manifest cannot approve itself.

    def test_arbitrary_path_field_even_with_approved_digest(self):
        self.policy["path"] = "../../untrusted"
        pin = self.write_manifest(self.policy)
        with self.assertRaises(ValueError):
            self.check(pin=pin)

    def test_duplicate_manifest_key(self):
        raw = self.manifest.read_bytes().replace(b'"protocol": 1', b'"protocol": 1, "protocol": 1')
        self.manifest.write_bytes(raw)
        with self.assertRaises(ValueError):
            self.check(pin=digest(raw))

    def test_oversized_manifest(self):
        self.manifest.write_bytes(b" " * 4097)
        self.rejected()

    def test_open_descriptor_retains_original_after_path_swap(self):
        directory_fd = os.open(self.version, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fd = checked_open(directory_fd, "core", os.geteuid(), 0o755)
            try:
                alternate = self.version / "replacement"
                alternate.write_bytes(b"replacement")
                alternate.replace(self.core)
                self.assertEqual(read_snapshot(fd, 1024), b"core")
                self.assertEqual(self.core.read_bytes(), b"replacement")
            finally:
                os.close(fd)
        finally:
            os.close(directory_fd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
