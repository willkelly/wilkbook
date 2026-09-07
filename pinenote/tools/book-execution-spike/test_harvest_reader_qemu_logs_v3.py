#!/usr/bin/env python3
"""Focused real-host lifetime tests for the v2 reader-QEMU log observer."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent
HARVESTER = HERE / "harvest_reader_qemu_logs_v3.py"
SUCCESS_LOOKING = (
    b"OUTER-READER-QEMU-STATUS=0; COORDINATOR-STATUS=0; "
    b"NATIVE-READER-LIFECYCLE=PASS; GUEST-READER-PROTOCOL=PASS; "
    b"CLEAN-POWER-DOWN=PASS\n"
)

FIXTURE = r'''#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("scenario")
parser.add_argument("--record-directory", required=True)
parser.add_argument("--run-base", required=True)
parser.add_argument("--timeout-seconds", required=True)
parser.add_argument("--term-grace-seconds", required=True)
args = parser.parse_args()
if args.timeout_seconds != "600" or args.term_grace_seconds != "5":
    raise SystemExit(2)

records = Path(args.record_directory)
(records / "launcher-started").write_text("yes\n", encoding="ascii")
root = Path(tempfile.mkdtemp(prefix="book-execution-qemu.", dir=args.run_base))
os.chmod(root, 0o700)
reader = root / "reader-ui"
reader.mkdir(mode=0o700)
paths = {
    root / "console.log": b"console-runtime-record\n",
    root / "qemu.stdout": b"coordinator-lifecycle\n",
    root / "qemu.stderr": b"coordinator-diagnostic\n",
    reader / "reader.log": b"paint-initial\n",
    reader / "qemu.stdout": b"qemu-stdout\n",
    reader / "qemu.stderr": b"qemu-stderr\n",
}

stopping = False
def stop(_number, _frame):
    global stopping
    stopping = True
for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, stop)

def pause(seconds):
    deadline = time.monotonic() + seconds
    while not stopping and time.monotonic() < deadline:
        time.sleep(0.01)

descendant = None
foreign = records / "foreign-reader-target"
preserve_root = False
try:
    for path, content in paths.items():
        if args.scenario == "missing" and path.name == "reader.log":
            continue
        if args.scenario == "symlink" and path.name == "reader.log":
            foreign.write_bytes(b"foreign-must-survive\n")
            path.symlink_to(foreign)
            continue
        with path.open("xb") as port:
            port.write(content)
        path.chmod(0o600)

    if args.scenario == "overflow-tree":
        descendant = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            close_fds=True,
            start_new_session=True,
        )
        (records / "descendant-pid").write_text(str(descendant.pid) + "\n")

    if args.scenario == "h1-detached-writer":
        append_fd = os.open(reader / "reader.log", os.O_WRONLY | os.O_APPEND)
        writer = (
            "import os,sys,time; "
            "fd=int(sys.argv[1]); marker=sys.argv[2]; "
            "time.sleep(1.0); os.write(fd,b'paint-late\\n'); "
            "open(marker,'x').write('late-write\\n'); os.close(fd)"
        )
        descendant = subprocess.Popen(
            [sys.executable, "-c", writer, str(append_fd), str(records / "late-write")],
            pass_fds=(append_fd,),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
        os.close(append_fd)
        (records / "descendant-pid").write_text(str(descendant.pid) + "\n")
        pause(0.20)
    elif args.scenario in ("h2-pipe-holder", "live-tree"):
        descendant = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            close_fds=True,
            start_new_session=True,
        )
        (records / "descendant-pid").write_text(str(descendant.pid) + "\n")
        pause(0.20 if args.scenario == "h2-pipe-holder" else 30.0)
    elif args.scenario == "replace":
        pause(0.20)
        target = root / "console.log"
        target.unlink()
        with target.open("xb") as port:
            port.write(b"replacement-must-not-be-harvested\n")
        target.chmod(0o600)
        pause(0.20)
    elif args.scenario in ("overflow", "overflow-tree"):
        pause(0.20)
        with (root / "console.log").open("ab") as port:
            port.write(b"x" * (4 * 1024 * 1024))
        pause(0.20)
    elif args.scenario == "foreign-root":
        pause(0.20)
        original = records / "original-run-root"
        root.rename(original)
        root.mkdir(mode=0o700)
        (root / "foreign-sentinel").write_bytes(b"preserve-foreign-root\n")
        preserve_root = True
        pause(30.0)
    else:
        pause(0.40)
finally:
    if not preserve_root:
        shutil.rmtree(root)
    original = records / "original-run-root"
    if original.exists():
        shutil.rmtree(original)

if args.scenario == "direct23":
    os.write(1, %r)
    raise SystemExit(23)
if args.scenario == "h2-pipe-holder":
    raise SystemExit(7)
if stopping:
    raise SystemExit(143)
raise SystemExit(0)
''' % SUCCESS_LOOKING


class HarvesterTests(unittest.TestCase):
    def make_case(self) -> tuple[tempfile.TemporaryDirectory[str], Path, Path, Path, Path]:
        temporary = tempfile.TemporaryDirectory(prefix="reader-harvest-v2-test.")
        self.addCleanup(temporary.cleanup)
        parent = Path(temporary.name)
        run_base = parent / "runs"
        records = parent / "records"
        run_base.mkdir(mode=0o700)
        records.mkdir(mode=0o700)
        fixture = parent / "fixture.py"
        fixture.write_text(FIXTURE, encoding="utf-8")
        fixture.chmod(0o500)
        return temporary, run_base, records, fixture, parent / "evidence"

    def command(
        self,
        scenario: str,
        run_base: Path,
        records: Path,
        fixture: Path,
        evidence: Path,
        deadline: float = 3.0,
    ) -> list[str]:
        return [
            sys.executable,
            str(HARVESTER),
            "--run-base",
            str(run_base),
            "--evidence-dir",
            str(evidence),
            "--deadline-seconds",
            str(deadline),
            "--",
            sys.executable,
            str(fixture),
            scenario,
            "--record-directory",
            str(records),
            "--run-base",
            str(run_base),
            "--timeout-seconds",
            "600",
            "--term-grace-seconds",
            "5",
        ]

    def invoke(
        self, scenario: str, deadline: float = 3.0
    ) -> tuple[subprocess.CompletedProcess[bytes], Path, Path, Path, float]:
        _temporary, run_base, records, fixture, evidence = self.make_case()
        started = time.monotonic()
        result = subprocess.run(
            self.command(scenario, run_base, records, fixture, evidence, deadline),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=max(5.0, deadline + 3.0),
        )
        return result, run_base, records, evidence, time.monotonic() - started

    def assert_pid_gone(self, path: Path) -> None:
        pid = int(path.read_text(encoding="ascii"))
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        self.fail(f"owned descendant leaked: {pid}")

    def test_success_unlink_after_all_writers_done(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("success")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(list(run_base.iterdir()), [])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=complete", manifest)
        self.assertIn("writer-completion=true", manifest)
        self.assertIn("adopted-owned-children-observed=0", manifest)
        self.assertIn("launcher-pipes-eof=true", manifest)
        self.assertIn("pre-mtime-ns=", manifest)
        self.assertEqual((evidence / "reader.log").read_bytes(), b"paint-initial\n")

    def test_h1_detached_unlinked_writer_fails_and_is_reaped(self) -> None:
        result, run_base, records, evidence, elapsed = self.invoke("h1-detached-writer")
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 2.5)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assert_pid_gone(records / "descendant-pid")
        self.assertFalse((records / "late-write").exists())
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("adopted-owned-children-observed=1", manifest)
        self.assertIn("owned descendant survived", manifest)
        if (evidence / "reader.log").exists():
            self.assertNotIn(b"paint-late", (evidence / "reader.log").read_bytes())

    def test_h2_exited_parent_pipe_holder_is_bounded_reaped_and_preserves_7(self) -> None:
        result, run_base, records, evidence, elapsed = self.invoke(
            "h2-pipe-holder", deadline=0.8
        )
        self.assertEqual(result.returncode, 7, result.stderr.decode(errors="replace"))
        self.assertLess(elapsed, 2.0)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assert_pid_gone(records / "descendant-pid")
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("launcher-status=7", manifest)
        self.assertIn("adopted-owned-children-observed=1", manifest)

    def test_short_absolute_deadline_cleans_live_private_tree(self) -> None:
        result, run_base, records, evidence, elapsed = self.invoke("live-tree", deadline=0.8)
        self.assertEqual(result.returncode, 143, result.stderr.decode(errors="replace"))
        self.assertLess(elapsed, 2.0)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assert_pid_gone(records / "descendant-pid")
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("absolute deadline required bounded cleanup", manifest)

    def assert_helper_signal_cleans_live_private_tree(self, number: int) -> None:
        _temporary, run_base, records, fixture, evidence = self.make_case()
        process = subprocess.Popen(
            self.command("live-tree", run_base, records, fixture, evidence, deadline=5.0),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        child_record = records / "descendant-pid"
        deadline = time.monotonic() + 2.0
        while not child_record.exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                break
            time.sleep(0.01)
        self.assertTrue(child_record.exists(), "fixture did not create its detached child")
        process.send_signal(number)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 143, stderr.decode(errors="replace"))
        self.assertEqual(stdout, b"")
        self.assertEqual(list(run_base.iterdir()), [])
        self.assert_pid_gone(child_record)
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn(f"harvest wrapper received signal {number}", manifest)

    def test_helper_term_cleans_live_private_tree(self) -> None:
        self.assert_helper_signal_cleans_live_private_tree(signal.SIGTERM)

    def test_helper_hup_cleans_live_private_tree(self) -> None:
        self.assert_helper_signal_cleans_live_private_tree(signal.SIGHUP)

    def test_direct_23_is_preserved_and_success_text_is_not_reemitted(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("direct23")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(list(run_base.iterdir()), [])
        self.assertEqual((evidence / "launcher.stdout").read_bytes(), SUCCESS_LOOKING)
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("launcher-status=23", manifest)

    def test_missing_required_file_fails_without_residue(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("log=reader.log state=missing-or-unstable", manifest)

    def test_replaced_file_fails_and_never_exports_replacement(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("replace")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        if (evidence / "console.log").exists():
            self.assertNotIn(
                b"replacement-must-not-be-harvested",
                (evidence / "console.log").read_bytes(),
            )
        self.assertIn(b"console.log pathname was replaced", result.stderr)

    def test_oversized_file_fails_without_partial_complete(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("overflow")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertNotIn("harvest-status=complete", manifest)
        self.assertIn(b"console.log exceeds its", result.stderr)

    def test_overflow_cleans_detached_private_tree(self) -> None:
        result, run_base, records, evidence, elapsed = self.invoke("overflow-tree")
        self.assertEqual(result.returncode, 143, result.stderr.decode(errors="replace"))
        self.assertLess(elapsed, 2.5)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assert_pid_gone(records / "descendant-pid")
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("console.log exceeds its", manifest)

    def test_symlink_source_rejected_and_foreign_target_preserved(self) -> None:
        result, run_base, records, evidence, _elapsed = self.invoke("symlink")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(run_base.iterdir()), [])
        self.assertEqual(
            (records / "foreign-reader-target").read_bytes(), b"foreign-must-survive\n"
        )
        self.assertFalse((evidence / "reader.log").exists())
        self.assertIn(b"reader.log is not a private single-link regular file", result.stderr)

    def test_foreign_replacement_root_is_preserved(self) -> None:
        result, run_base, _records, evidence, _elapsed = self.invoke("foreign-root")
        self.assertNotEqual(result.returncode, 0)
        roots = list(run_base.iterdir())
        self.assertEqual(len(roots), 1)
        self.assertEqual(
            (roots[0] / "foreign-sentinel").read_bytes(), b"preserve-foreign-root\n"
        )
        self.addCleanup(shutil.rmtree, roots[0])
        manifest = (evidence / "HARVEST.txt").read_text(encoding="utf-8")
        self.assertIn("harvest-status=failed", manifest)
        self.assertIn("run-root-removed=false", manifest)
        self.assertIn(b"run root pathname was replaced", result.stderr)

    def test_existing_evidence_is_exclusive_and_launcher_never_starts(self) -> None:
        _temporary, run_base, records, fixture, evidence = self.make_case()
        evidence.mkdir(mode=0o700)
        sentinel = evidence / "foreign"
        sentinel.write_bytes(b"preserve\n")
        result = subprocess.run(
            self.command("success", run_base, records, fixture, evidence),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((records / "launcher-started").exists())
        self.assertEqual(sentinel.read_bytes(), b"preserve\n")
        self.assertFalse((evidence / "HARVEST.txt").exists())

    def test_stable_reader_rejects_metadata_change_during_exact_read(self) -> None:
        specification = importlib.util.spec_from_file_location("harvester_v3", HARVESTER)
        assert specification is not None and specification.loader is not None
        module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = module
        specification.loader.exec_module(module)
        self.addCleanup(sys.modules.pop, specification.name, None)
        with tempfile.TemporaryDirectory(prefix="reader-harvest-metadata.") as temporary:
            path = Path(temporary) / "source.log"
            path.write_bytes(b"a" * (128 * 1024))
            path.chmod(0o600)
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.addCleanup(os.close, fd)
            info = os.fstat(fd)
            held = module.HeldLog(
                "reader.log", "reader", "reader.log", 128 * 1024, fd, info.st_dev, info.st_ino
            )
            real_pread = module.os.pread
            changed = False

            def changing_pread(source_fd: int, count: int, offset: int) -> bytes:
                nonlocal changed
                value = real_pread(source_fd, count, offset)
                if not changed:
                    changed = True
                    now = time.time_ns() + 1_000_000_000
                    os.utime(path, ns=(now, now))
                return value

            module.os.pread = changing_pread
            self.addCleanup(setattr, module.os, "pread", real_pread)
            with self.assertRaisesRegex(module.HarvestError, "metadata changed"):
                module.read_held_log_stable(held, time.monotonic() + 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
