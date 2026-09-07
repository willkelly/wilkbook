#!/usr/bin/env python3
"""Mutation tests for the exact kernel-config delta checker."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent
CHECKER = HERE / "check_kernel_config_delta.py"


class KernelConfigDeltaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wilkbook-config-delta-")
        self.root = pathlib.Path(self.temporary.name)
        self.base = self.root / "base.config"
        self.final = self.root / "final.config"
        self.allowed = self.root / "allowed.txt"
        self.evidence = self.root / "evidence"
        self.base.write_text(
            "CONFIG_ARM64=y\n# CONFIG_USER_NS is not set\nCONFIG_SECCOMP=y\n",
            encoding="utf-8",
        )
        self.final.write_text(
            "CONFIG_ARM64=y\nCONFIG_USER_NS=y\nCONFIG_SECCOMP=y\n",
            encoding="utf-8",
        )
        self.allowed.write_text("CONFIG_USER_NS n y\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invoke(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(CHECKER),
                str(self.base),
                str(self.final),
                str(self.allowed),
                str(self.evidence),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_exact_user_namespace_delta_passes_and_records_full_diff(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CONFIG_USER_NS: n -> y", result.stdout)
        self.assertIn(
            "CONFIG_USER_NS\tn\ty",
            (self.evidence / "kernel-config-symbol-delta.tsv").read_text(
                encoding="utf-8"
            ),
        )
        full = (self.evidence / "kernel-config-full.diff").read_text(
            encoding="utf-8"
        )
        self.assertIn("-# CONFIG_USER_NS is not set", full)
        self.assertIn("+CONFIG_USER_NS=y", full)

    def test_unlisted_olddefconfig_change_fails(self) -> None:
        with self.final.open("a", encoding="utf-8") as port:
            port.write("CONFIG_UNEXPECTED=y\n")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFIG_UNEXPECTED", result.stderr)

    def test_wrong_transition_fails(self) -> None:
        self.allowed.write_text("CONFIG_USER_NS n m\n", encoding="utf-8")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from exact allowlist", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
