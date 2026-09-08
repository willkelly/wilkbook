#!/usr/bin/env python3
"""Focused host-only tests for the bounded reader-QEMU log observer."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


HERE = Path(__file__).resolve().parent
HARVESTER = HERE / "harvest_reader_qemu_logs.py"

FIXTURE = r'''#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shutil
import signal
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("scenario")
parser.add_argument("--run-base", required=True)
parser.add_argument("--timeout-seconds", required=True)
parser.add_argument("--term-grace-seconds", required=True)
args = parser.parse_args()

if args.timeout_seconds != "600" or args.term_grace_seconds != "5":
    raise SystemExit(2)

root = Path(tempfile.mkdtemp(prefix="book-execution-qemu.", dir=args.run_base))
os.chmod(root, 0o700)
reader = root / "reader-ui"
reader.mkdir(mode=0o700)
paths = {
    root / "console.log": b"console-runtime-record\n",
    root / "qemu.stdout": b"coordinator-lifecycle\n",
    root / "qemu.stderr": b"coordinator-diagnostic\n",
    reader / "reader.log": b"paintTo-topmost-exact\n",
    reader / "qemu.stdout": b"qemu-stdout\n",
    reader / "qemu.stderr": b"qemu-stderr\n",
}

stopping = False
def stop(_number, _frame):
    global stopping
    stopping = True

for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, stop)

try:
    for path, content in paths.items():
        if args.scenario == "missing" and path.name == "reader.log":
            continue
        with path.open("xb") as port:
            port.write(content)
        path.chmod(0o600)
    time.sleep(0.20)
    if args.scenario == "replace":
        target = root / "console.log"
        target.unlink()
        with target.open("xb") as port:
            port.write(b"replacement-must-not-be-harvested\n")
        target.chmod(0o600)
        time.sleep(0.20)
    elif args.scenario == "overflow":
        with (root / "console.log").open("ab") as port:
            port.write(b"x" * (4 * 1024 * 1024))
        time.sleep(0.20)
    else:
        time.sleep(0.20)
finally:
    shutil.rmtree(root)

if stopping:
    raise SystemExit(143)
raise SystemExit(0)
'''


class HarvesterTests(unittest.TestCase):
    def invoke(self, scenario: str) -> tuple[subprocess.CompletedProcess[bytes], Path, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="reader-harvest-test.")
        self.addCleanup(temporary.cleanup)
        parent = Path(temporary.name)
        run_base = parent / "runs"
        run_base.mkdir(mode=0o700)
        fixture = parent / "fixture.py"
        fixture.write_text(FIXTURE, encoding="utf-8")
        fixture.chmod(0o500)
        evidence = parent / "evidence"
        command = [
            sys.executable,
            str(HARVESTER),
            "--run-base",
            str(run_base),
            "--evidence-dir",
            str(evidence),
            "--",
            sys.executable,
            str(fixture),
            scenario,
            "--run-base",
            str(run_base),
            "--timeout-seconds",
            "600",
            "--term-grace-seconds",
            "5",
        ]
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True)
        return result, run_base, evidence

    def test_complete_harvest_survives_guardian_style_unlink(self) -> None:
        result, run_base, evidence = self.invoke("success")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(list(run_base.iterdir()), [])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=complete", manifest)
        self.assertIn("run-root-removed=true", manifest)
        self.assertEqual((evidence / "reader.log").read_bytes(), b"paintTo-topmost-exact\n")
        self.assertEqual(
            (evidence / "coordinator.stdout").read_bytes(), b"coordinator-lifecycle\n"
        )
        self.assertEqual((evidence / "qemu.stdout").read_bytes(), b"qemu-stdout\n")
        self.assertEqual(oct(evidence.stat().st_mode & 0o777), "0o500")
        for path in evidence.iterdir():
            self.assertEqual(oct(path.stat().st_mode & 0o777), "0o400")

    def test_missing_required_file_fails_without_residue(self) -> None:
        result, run_base, evidence = self.invoke("missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("log=reader.log state=missing", manifest)
        self.assertIn("error=required log was not opened: reader.log", manifest)

    def test_replaced_file_fails_and_never_exports_replacement(self) -> None:
        result, run_base, evidence = self.invoke("replace")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        if (evidence / "console.log").exists():
            self.assertNotIn(b"replacement-must-not-be-harvested", (evidence / "console.log").read_bytes())
        self.assertIn(b"console.log pathname was replaced", result.stderr)

    def test_oversized_file_fails_without_residue(self) -> None:
        result, run_base, evidence = self.invoke("overflow")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assertIn(b"console.log exceeds its", result.stderr)
        if (evidence / "console.log").exists():
            self.assertLessEqual((evidence / "console.log").stat().st_size, 4 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main(verbosity=2)
