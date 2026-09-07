#!/usr/bin/env python3
"""Bounded tests for the Bazel self-extracting-archive transform."""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import zipfile


def load(path: Path):
    spec = importlib.util.spec_from_file_location("bazel_bootstrap", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


MODULE = load(Path(sys.argv[1])) if len(sys.argv) > 1 else None


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.loader = self.root / "ld-linux.so"
        self.loader.write_text("loader")
        self.shell = self.root / "bash"
        self.shell.write_text("shell")
        self.shell.chmod(0o755)
        self.patchelf = self.root / "patchelf"
        self.patchelf.write_text(
            """#!/usr/bin/env python3
from pathlib import Path
import sys
if sys.argv[1] == "--print-interpreter":
    print("/lib64/ld-linux-x86-64.so.2")
elif sys.argv[1] == "--print-needed":
    print("libc.so.6")
elif sys.argv[1] == "--set-interpreter":
    path = Path(sys.argv[3])
    data = path.read_bytes()
    marker = sys.argv[1].encode()
    offset = data.find(b"PK\\x03\\x04")
    if offset < 0:
        offset = len(data)
    path.write_bytes(data[:offset] + marker + data[offset:])
else:
    raise SystemExit(2)
"""
        )
        self.patchelf.chmod(0o755)
        self.source = self.root / "bazel.raw"
        self.source.write_bytes(
            b"\x7fELF-fixed-launcher-prefix:"
            + MODULE.RAW_LAUNCHER_INTERPRETER
            + b"\n"
        )
        with zipfile.ZipFile(self.source, "a") as archive:
            archive.writestr("A-server.jar", b"jar")
            info = zipfile.ZipInfo("process-wrapper", (1980, 1, 1, 0, 0, 0))
            info.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(info, b"\x7fELF-helper")
            archive.writestr("install_base_key", b"0" * 32)
        self.sha256 = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def tearDown(self):
        self.tmp.cleanup()

    def run_repack(self, name: str = "bazel") -> dict:
        return MODULE.repack(
            self.source,
            self.root / name,
            self.patchelf,
            self.loader,
            self.shell,
            "/gnu/store/glibc/lib:/gnu/store/gcc/lib",
            self.sha256,
            1,
            self.root / f"{name}.json",
        )

    def test_repack_preserves_order_and_changes_key(self):
        manifest = self.run_repack()
        with zipfile.ZipFile(self.root / "bazel") as archive:
            self.assertEqual(
                [entry.filename for entry in archive.infolist()],
                [
                    "A-server.jar",
                    "process-wrapper",
                    "process-wrapper.gvisor-real",
                    "install_base_key",
                ],
            )
            self.assertEqual(
                archive.read("install_base_key").decode(),
                MODULE.transformed_install_key(
                    self.sha256,
                    self.patchelf,
                    self.loader,
                    self.shell,
                    "/gnu/store/glibc/lib:/gnu/store/gcc/lib",
                ),
            )
            self.assertIn(b"LD_LIBRARY_PATH=/gnu/store/glibc/lib", archive.read("process-wrapper"))
            self.assertIn(b"--set-interpreter", archive.read("process-wrapper.gvisor-real"))
            self.assertNotIn(b"--set-rpath", archive.read("process-wrapper.gvisor-real"))
        self.assertEqual(manifest["elf_member_count"], 1)
        self.assertEqual(manifest["wrapped_executable_count"], 1)
        self.assertTrue(manifest["embedded_jdk_retained"])

    def test_repack_is_deterministic(self):
        first = self.run_repack("one")
        second = self.run_repack("two")
        self.assertEqual((self.root / "one").read_bytes(), (self.root / "two").read_bytes())
        self.assertEqual(first["repacked_sha256"], second["repacked_sha256"])

    def test_wrong_source_hash_fails_closed(self):
        with self.assertRaisesRegex(MODULE.BootstrapError, "SHA-256 changed"):
            MODULE.repack(
                self.source,
                self.root / "bazel",
                self.patchelf,
                self.loader,
                self.shell,
                "/gnu/store/glibc/lib",
                "0" * 64,
                1,
                None,
            )

    def test_fhs_runpath_is_rejected(self):
        with self.assertRaisesRegex(MODULE.BootstrapError, "non-FHS"):
            MODULE.repack(
                self.source,
                self.root / "bazel",
                self.patchelf,
                self.loader,
                self.shell,
                "/usr/lib",
                self.sha256,
                1,
                None,
            )

    def test_elf_count_is_a_gate(self):
        with self.assertRaisesRegex(MODULE.BootstrapError, "ELF count changed"):
            MODULE.repack(
                self.source,
                self.root / "bazel",
                self.patchelf,
                self.loader,
                self.shell,
                "/gnu/store/glibc/lib",
                self.sha256,
                2,
                None,
            )


if __name__ == "__main__":
    if MODULE is None:
        raise SystemExit("usage: test_bazel_bootstrap.py BAZEL_BOOTSTRAP.py")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
