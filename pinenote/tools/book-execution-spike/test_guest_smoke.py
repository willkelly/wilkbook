#!/usr/bin/env python3
"""Host-only policy tests for the Guile in-guest compatibility fixture."""

from __future__ import annotations

import json
import os
import pathlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
MODULE = HERE / "guest-smoke.scm"
CONSOLE_ASSERTIONS = HERE / "assert-guest-console.scm"
OCI_BUNDLE = HERE / "oci-bundle.scm"
SYSTEM = REPO / "pinenote/systems/pinenote-book-execution-spike.scm"
MAX_CAPTURE_BYTES = 4 * 1024 * 1024
DEBUG_STORE_BYTES = 4 * 1024 * 1024
PANIC_STORE_BYTES = 1 * 1024 * 1024


class GuestSmokePolicyTests(unittest.TestCase):
    def guile(
        self, expression: str, extra_environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                str(HERE),
                "-c",
                expression,
            ],
            cwd=REPO,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )

    def guile_in_private_mount_namespace(
        self, expression: str
    ) -> subprocess.CompletedProcess[str]:
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        guile = shutil.which("guile")
        self.assertIsNotNone(guile)
        return subprocess.run(
            [
                "/usr/bin/unshare",
                "--user",
                "--map-root-user",
                "--mount",
                "--pid",
                "--fork",
                "--net",
                guile,
                "--no-auto-compile",
                "-L",
                str(HERE),
                "-c",
                expression,
            ],
            cwd=REPO,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )

    def test_mount_and_interface_classifiers_fail_closed(self) -> None:
        root = "27 1 254:0 / / rw,relatime - ext4 /dev/vda1 rw"
        guix_store = (
            "31 27 254:0 /gnu/store /gnu/store ro,noatime "
            "- ext4 /dev/vda1 rw"
        )
        safe_mounts = [
            root,
            guix_store,
            "32 27 0:5 / /proc rw,nosuid,nodev,noexec - proc proc rw",
            "33 27 0:21 / /sys rw,nosuid,nodev,noexec - sysfs sysfs rw",
            "34 27 0:24 / /sys/fs/cgroup rw,nosuid,nodev,noexec "
            "- cgroup2 cgroup2 rw",
        ]
        forbidden_mounts = [
            "40 27 0:40 / /mnt/books ro - 9p hostshare ro,trans=virtio",
            "41 27 0:41 / /innocent ro - virtiofs hostshare ro",
            "42 27 0:42 / /srv ro - nfs server:/exports ro",
            "43 27 0:43 / /opt ro - nfs4 server:/exports ro",
            "44 27 0:44 / /gnu/store ro - squashfs host-store ro",
            "45 27 254:0 /gnu/store /gnu/store rw,noatime "
            "- ext4 /dev/vda1 rw",
            "46 27 254:0 /host/gnu/store /gnu/store ro,noatime "
            "- ext4 /dev/vda1 rw",
            "47 27 254:1 /gnu/store /gnu/store ro,noatime "
            "- ext4 /dev/vdb1 rw",
            "48 27 254:0 /gnu/store /gnu/store/subtree ro,noatime "
            "- ext4 /dev/vda1 rw",
            "49 27 254:0 /data /data ro - ext4 /dev/vda1 rw",
            "not valid mountinfo",
        ]
        result = self.guile(
            f"""
(use-modules (guest-smoke) (json))
(scm->json
 (vector
  (network-interface-set-safe? '("lo"))
  (network-interface-set-safe? '("eth0" "lo"))
  (list->vector
   (map (lambda (line)
          (forbidden-host-mount? line {json.dumps(root)}))
        (list {' '.join(json.dumps(line) for line in safe_mounts)})))
  (list->vector
   (map (lambda (line)
          (forbidden-host-mount? line {json.dumps(root)}))
        (list {' '.join(json.dumps(line) for line in forbidden_mounts)}))))
 (current-output-port) #:unicode #t)
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [
                True,
                False,
                [False] * len(safe_mounts),
                [True] * len(forbidden_mounts),
            ],
        )

    def mount_boundary_failure(self, mountinfo: str) -> str:
        result = self.guile(
            f"""
(use-modules (guest-smoke))
(catch 'book-execution-guest-smoke-error
  (lambda ()
    (assert-mount-boundaries {json.dumps(mountinfo)})
    (exit 90))
  (lambda (key message)
    (display message)))
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_mount_failure_diagnostic_is_bounded_escaped_and_names_root(self) -> None:
        root = "27 1 254:0 / / rw,relatime - ext4 /dev/vda1 rw"
        escaped = (
            root
            + "\n"
            + "40 27 0:40 / /mnt/\x1bhost ro - 9p hostshare ro,trans=virtio"
        )
        message = self.mount_boundary_failure(escaped)
        self.assertIn("reason=host-share-filesystem", message)
        self.assertIn("root-device=254:0 root-type=ext4", message)
        self.assertIn(r"/mnt/\x1bhost", message)
        self.assertNotIn("\x1b", message)

        tail = "MOUNTINFO-TAIL-MUST-NOT-APPEAR"
        long_mount = (
            root
            + "\n"
            + "41 27 0:41 / /data/"
            + "a" * 4096
            + tail
            + " ro - ext4 /dev/vdc1 ro"
        )
        message = self.mount_boundary_failure(long_mount)
        self.assertIn("reason=data-mount", message)
        self.assertIn("[truncated source-bytes=", message)
        self.assertNotIn(tail, message)
        self.assertLess(len(message.encode("utf-8")), 2300)

    def test_runtime_diagnostics_are_bounded_escaped_and_fail_soft(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-runtime-diagnostic-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            console = root / "console.log"
            long_log = root / "long.log"
            long_log.write_bytes(
                b"HEAD-SENTINEL\n"
                + b"A" * 9000
                + b"MIDDLE-MUST-BE-ELIDED"
                + b"B" * 9000
                + b"\nBOOKEXEC-PYTHON-SYSTRAP-PASS"
                + b"\nBOOKEXEC-SMOKE-PASS"
                + b"\nGUEST-ASSERTIONS=PASS"
                + b"\nTAIL-SENTINEL\x1b"
            )
            nonregular = root / "not-a-file"
            nonregular.mkdir()
            missing = root / "missing.log"
            unreadable = root / "unreadable.log"
            unreadable.write_text("must not be exposed\n", encoding="ascii")
            unreadable.chmod(0)

            result = self.guile(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(emit-bounded-file-diagnostic "long" {json.dumps(str(long_log))})
(emit-bounded-file-diagnostic "nonregular" {json.dumps(str(nonregular))})
(emit-bounded-file-diagnostic "missing" {json.dumps(str(missing))})
(emit-bounded-file-diagnostic "unreadable" {json.dumps(str(unreadable))})
(force-output console)
(close-port console)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed = console.read_text(encoding="utf-8")
            self.assertIn("BOOKEXEC-DIAGNOSTIC-HEAD bytes=8192", observed)
            self.assertIn("BOOKEXEC-DIAGNOSTIC-TAIL bytes=8192", observed)
            self.assertIn("BOOKEXEC-DIAGNOSTIC-ELIDED bytes=", observed)
            self.assertIn("HEAD-SENTINEL\\n", observed)
            self.assertIn("TAIL-SENTINEL\\x1b", observed)
            self.assertNotIn("MIDDLE-MUST-BE-ELIDED", observed)
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC label=nonregular state=non-regular",
                observed,
            )
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC label=missing state=missing", observed
            )
            for forged in (
                "BOOKEXEC-PYTHON-SYSTRAP-PASS",
                "BOOKEXEC-SMOKE-PASS",
                "GUEST-ASSERTIONS=PASS",
            ):
                self.assertNotIn(forged, observed.splitlines())
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC label=unreadable state=unavailable",
                observed,
            )
            self.assertNotIn("must not be exposed", observed)
            self.assertLess(len(observed.encode("utf-8")), 70000)

    def test_runsc_debug_directory_absence_errors_and_file_limit(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-debug-directory-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            console = root / "console.log"
            missing = root / "missing"
            nondirectory = root / "ordinary-file"
            nondirectory.write_text("not a directory\n", encoding="ascii")
            logs = root / "logs"
            logs.mkdir(mode=0o700)
            panic_logs = root / "panic-logs"
            panic_logs.mkdir(mode=0o700)
            (logs / "00-nonregular").mkdir()
            for index in range(14):
                (logs / f"{index + 1:02d}.log").write_text(
                    f"log-{index + 1}\n", encoding="ascii"
                )
            for index in range(3):
                (panic_logs / f"{index + 1:02d}.log").write_text(
                    f"panic-{index + 1}\n", encoding="ascii"
                )

            result = self.guile(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(emit-runsc-debug-diagnostics {json.dumps(str(missing))})
(emit-runsc-debug-diagnostics {json.dumps(str(nondirectory))})
(emit-runsc-debug-diagnostics {json.dumps(str(logs))})
((module-ref module 'emit-runsc-panic-diagnostics)
 {json.dumps(str(panic_logs))})
(force-output console)
(close-port console)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed = console.read_text(encoding="utf-8")
            self.assertIn("label=runsc-debug state=missing", observed)
            self.assertIn("label=runsc-debug state=non-directory", observed)
            self.assertIn(
                "label=runsc-debug entries=15 emitted=10 limit=10", observed
            )
            self.assertIn(
                "label=runsc-panic entries=3 emitted=2 limit=2", observed
            )
            self.assertIn("label=runsc-debug-0 state=non-regular", observed)
            self.assertIn("log-9\\n", observed)
            self.assertNotIn("log-10\\n", observed)
            self.assertNotIn("log-14\\n", observed)
            self.assertIn("panic-2\\n", observed)
            self.assertNotIn("panic-3\\n", observed)

    def test_capture_limit_does_not_restrict_inherited_memory_file_truncate(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-capture-fsize-scope-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            script = root / "truncate-memory-file.py"
            backing = root / "systrap-memory"
            stdout = root / "stdout"
            stderr = root / "stderr"
            requested_size = 8 * 1024 * 1024
            script.write_text(
                "import json, resource, sys\n"
                f"requested = {requested_size}\n"
                "with open(sys.argv[1], 'w+b') as stream:\n"
                "    stream.truncate(requested)\n"
                "soft, hard = resource.getrlimit(resource.RLIMIT_FSIZE)\n"
                "print(json.dumps({'soft': soft, 'hard': hard, "
                "'size': requested}, sort_keys=True))\n",
                encoding="utf-8",
            )
            script.chmod(0o500)
            result = self.guile(
                f"""
(use-modules (guest-smoke) (json))
(define module (resolve-module '(guest-smoke)))
(define outcome
  ((module-ref module 'run-command)
   (list {json.dumps(sys.executable)} {json.dumps(str(script))}
         {json.dumps(str(backing))})
   '("HOME=/nonexistent" "LANG=C" "LC_ALL=C")
   {json.dumps(str(root))} {json.dumps(str(stdout))}
   {json.dumps(str(stderr))}))
(scm->json ((module-ref module 'command-result-observation) outcome)
          (current-output-port) #:unicode #t)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            supervision = json.loads(result.stdout)
            child = json.loads(stdout.read_text(encoding="utf-8"))
            self.assertEqual(supervision["status"], 0)
            self.assertFalse(supervision["stdout_overflow"])
            self.assertFalse(supervision["stderr_overflow"])
            self.assertEqual(supervision["stdout_observed"], stdout.stat().st_size)
            self.assertEqual(child["size"], requested_size)
            self.assertNotEqual(child["soft"], MAX_CAPTURE_BYTES)
            self.assertEqual(backing.stat().st_size, requested_size)
            self.assertEqual(stderr.read_bytes(), b"")

    def test_oversized_output_is_drained_capped_and_reported(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-capture-overflow-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            script = root / "oversized-output.py"
            stdout = root / "stdout"
            stderr = root / "stderr"
            console = root / "console"
            emitted_bytes = MAX_CAPTURE_BYTES + 12345
            script.write_text(
                "import os\n"
                f"remaining = {emitted_bytes}\n"
                "chunk = b'X' * 65536\n"
                "while remaining:\n"
                "    piece = chunk[:min(len(chunk), remaining)]\n"
                "    offset = 0\n"
                "    while offset < len(piece):\n"
                "        offset += os.write(1, piece[offset:])\n"
                "    remaining -= len(piece)\n"
                "os.write(2, b'stderr-sentinel\\n')\n",
                encoding="utf-8",
            )
            script.chmod(0o500)
            result = self.guile(
                f"""
(use-modules (guest-smoke) (json))
(define module (resolve-module '(guest-smoke)))
(define outcome
  ((module-ref module 'run-command)
   (list {json.dumps(sys.executable)} {json.dumps(str(script))})
   '("HOME=/nonexistent" "LANG=C" "LC_ALL=C")
   {json.dumps(str(root))} {json.dumps(str(stdout))}
   {json.dumps(str(stderr))}))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
((module-ref module 'emit-capture-overflow-diagnostics) outcome)
(force-output console)
(close-port console)
(scm->json ((module-ref module 'command-result-observation) outcome)
          (current-output-port) #:unicode #t)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed = json.loads(result.stdout)
            self.assertEqual(observed["status"], 0)
            self.assertTrue(observed["stdout_overflow"])
            self.assertFalse(observed["stderr_overflow"])
            self.assertEqual(observed["stdout_observed"], emitted_bytes)
            self.assertEqual(observed["stderr_observed"], len(b"stderr-sentinel\n"))
            self.assertEqual(stdout.stat().st_size, MAX_CAPTURE_BYTES)
            self.assertEqual(stdout.read_bytes()[:1], b"X")
            self.assertEqual(stdout.read_bytes()[-1:], b"X")
            self.assertEqual(stderr.read_bytes(), b"stderr-sentinel\n")
            self.assertIn(
                f"stdout observed-bytes={emitted_bytes} "
                f"retained-bytes={MAX_CAPTURE_BYTES} limit-bytes={MAX_CAPTURE_BYTES}",
                observed["summary"],
            )
            self.assertEqual(
                console.read_text(encoding="utf-8"),
                "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW "
                f"stream=stdout observed-bytes={emitted_bytes} "
                f"retained-bytes={MAX_CAPTURE_BYTES} "
                f"limit-bytes={MAX_CAPTURE_BYTES}\n",
            )

    def test_run_bundle_overflow_is_failure_not_payload_pass(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-bundle-capture-overflow-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            run = bundle / "run.sh"
            emitted_bytes = MAX_CAPTURE_BYTES + 1
            run.write_text(
                f"#!{sys.executable}\n"
                "import os\n"
                f"remaining = {emitted_bytes}\n"
                "chunk = b'Y' * 65536\n"
                "while remaining:\n"
                "    piece = chunk[:min(len(chunk), remaining)]\n"
                "    offset = 0\n"
                "    while offset < len(piece):\n"
                "        offset += os.write(1, piece[offset:])\n"
                "    remaining -= len(piece)\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            console = root / "console"
            result = self.guile(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(module-set! module 'diagnostic-store-setup! (lambda (bundle) '()))
(module-set! module 'diagnostic-store-cleanup!
             (lambda (stores bundle) #t))
(define status
  (catch 'book-execution-guest-smoke-error
    (lambda ()
      ((module-ref module 'run-bundle)
       {json.dumps(str(bundle))} "host-overflow-fixture" 'python 1
       "BOOKEXEC-PYTHON-SYSTRAP-PASS")
      0)
    (lambda (key message)
      (display message)
      1)))
(force-output console)
(close-port console)
(exit status)
"""
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("failed capture policy with status 0", result.stdout)
            observed = console.read_text(encoding="utf-8")
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-RUNSC-EXIT "
                "container=host-overflow-fixture status=0",
                observed,
            )
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW "
                f"stream=stdout observed-bytes={emitted_bytes} "
                f"retained-bytes={MAX_CAPTURE_BYTES} "
                f"limit-bytes={MAX_CAPTURE_BYTES}",
                observed,
            )
            self.assertEqual((bundle / "runsc.stdout").stat().st_size, MAX_CAPTURE_BYTES)
            self.assertNotIn("BOOKEXEC-PYTHON-SYSTRAP-PASS", observed.splitlines())

    def test_capture_supervisor_timeout_cleans_term_resistant_child(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-capture-cleanup-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            script = root / "term-resistant.py"
            pid_file = root / "child.pid"
            stdout = root / "stdout"
            stderr = root / "stderr"
            script.write_text(
                "import os, signal, sys, time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "with open(sys.argv[1], 'w', encoding='ascii') as stream:\n"
                "    stream.write(str(os.getpid()) + '\\n')\n"
                "    stream.flush()\n"
                "while True:\n"
                "    time.sleep(1)\n",
                encoding="utf-8",
            )
            script.chmod(0o500)
            started = time.monotonic()
            result = self.guile(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(module-set! module 'process-timeout-seconds 1.0)
(module-set! module 'process-term-grace-seconds 0.1)
(catch 'book-execution-guest-smoke-error
  (lambda ()
    ((module-ref module 'run-command)
     (list {json.dumps(sys.executable)} {json.dumps(str(script))}
           {json.dumps(str(pid_file))})
     '("HOME=/nonexistent" "LANG=C" "LC_ALL=C")
     {json.dumps(str(root))} {json.dumps(str(stdout))}
     {json.dumps(str(stderr))})
    (exit 90))
  (lambda (key message) (display message)))
"""
            )
            elapsed = time.monotonic() - started
            child_pid = int(pid_file.read_text(encoding="ascii"))
            try:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("guest command exceeded", result.stdout)
                self.assertLess(elapsed, 5)
                deadline = time.monotonic() + 2
                while pathlib.Path(f"/proc/{child_pid}").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(pathlib.Path(f"/proc/{child_pid}").exists())
                self.assertLessEqual(stdout.stat().st_size, MAX_CAPTURE_BYTES)
                self.assertLessEqual(stderr.stat().st_size, MAX_CAPTURE_BYTES)
            finally:
                if pathlib.Path(f"/proc/{child_pid}").exists():
                    os.kill(child_pid, signal.SIGKILL)

    def test_private_diagnostic_stores_normal_files_unmount_before_pass(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-diagnostic-store-normal-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            (bundle / "runsc-debug").mkdir(mode=0o700)
            (bundle / "runsc-panic").mkdir(mode=0o700)
            run = bundle / "run.sh"
            run.write_text(
                f"#!{sys.executable}\n"
                "from pathlib import Path\n"
                f"bundle = Path({str(bundle)!r})\n"
                "(bundle / 'runsc-debug' / 'runsc.log.normal.run.txt').write_text("
                "'normal-debug\\n', encoding='ascii')\n"
                "(bundle / 'runsc-panic' / 'runsc.panic.panic.log').write_text("
                "'LATE-PANIC-NORMAL\\n', encoding='ascii')\n"
                "print('BOOKEXEC-PAYLOAD-PYTHON book-bytes=1')\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            console = root / "console"
            result = self.guile_in_private_mount_namespace(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(module-set! module 'mount-program "/usr/bin/mount")
(module-set! module 'umount-program "/usr/bin/umount")
(when ((module-ref module 'ipv4-default-route?)
       ((module-ref module 'read-all) "/proc/net/route"))
  (error "private test network namespace has a default route"))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
((module-ref module 'run-bundle)
 {json.dumps(str(bundle))} "host-normal-diagnostic-store" 'python 1
 "BOOKEXEC-PYTHON-SYSTRAP-PASS")
(force-output console)
(close-port console)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed = console.read_text(encoding="utf-8")
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug entries=1 ", observed
            )
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic entries=1 ", observed
            )
            self.assertEqual(observed.count("overflow=#f"), 2)
            self.assertEqual(
                observed.splitlines()[-1], "BOOKEXEC-PYTHON-SYSTRAP-PASS"
            )
            self.assertFalse((bundle / "runsc-debug").exists())
            self.assertFalse((bundle / "runsc-panic").exists())
            self.assertNotIn(
                str(bundle), pathlib.Path("/proc/self/mountinfo").read_text()
            )
            self.assertEqual(
                (bundle / "runsc.stdout").read_text(encoding="ascii"),
                "BOOKEXEC-PAYLOAD-PYTHON book-bytes=1\n",
            )

    def test_private_diagnostic_store_flood_is_bounded_and_reserves_late_panic(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-diagnostic-store-flood-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            (bundle / "runsc-debug").mkdir(mode=0o700)
            (bundle / "runsc-panic").mkdir(mode=0o700)
            oracle = root / "oracle.json"
            debug_bytes = 64 * 1024
            panic_bytes = 16 * 1024
            debug_files = 3
            panic_files = 2
            run = bundle / "run.sh"
            run.write_text(
                f"#!{sys.executable}\n"
                "import errno, json, os\n"
                "from pathlib import Path\n"
                f"bundle = Path({str(bundle)!r})\n"
                f"oracle = Path({str(oracle)!r})\n"
                f"capacity = {debug_bytes}\n"
                "debug = bundle / 'runsc-debug'\n"
                "panic = bundle / 'runsc-panic'\n"
                "chunk = b'D' * 4096\n"
                "direct = debug / 'direct-over-limit.log'\n"
                "direct_enospc = False\n"
                "with direct.open('wb', buffering=0) as stream:\n"
                "    for _ in range((capacity * 2) // len(chunk)):\n"
                "        try:\n"
                "            stream.write(chunk)\n"
                "        except OSError as error:\n"
                "            if error.errno != errno.ENOSPC:\n"
                "                raise\n"
                "            direct_enospc = True\n"
                "            break\n"
                "direct_size = direct.stat().st_size\n"
                "direct_allocated = direct.stat().st_blocks * 512\n"
                "direct.unlink()\n"
                f"paths = [debug / f'aggregate-{{index}}.log' for index in range({debug_files})]\n"
                "for path in paths:\n"
                "    path.touch()\n"
                "debug_inode_enospc = False\n"
                "try:\n"
                "    (debug / 'one-too-many.log').touch()\n"
                "except OSError as error:\n"
                "    if error.errno != errno.ENOSPC:\n"
                "        raise\n"
                "    debug_inode_enospc = True\n"
                "fds = [os.open(path, os.O_WRONLY | os.O_APPEND) for path in paths[:2]]\n"
                "aggregate_enospc = False\n"
                "try:\n"
                "    for index in range((capacity * 3) // len(chunk)):\n"
                "        try:\n"
                "            os.write(fds[index % len(fds)], chunk)\n"
                "        except OSError as error:\n"
                "            if error.errno != errno.ENOSPC:\n"
                "                raise\n"
                "            aggregate_enospc = True\n"
                "            break\n"
                "finally:\n"
                "    for fd in fds:\n"
                "        os.close(fd)\n"
                "late_panic = b'LATE-PANIC-AFTER-DEBUG-FLOOD\\n'\n"
                "(panic / 'runsc.panic.panic.log').write_bytes(late_panic)\n"
                "(panic / 'second-panic.log').touch()\n"
                "panic_inode_enospc = False\n"
                "try:\n"
                "    (panic / 'one-too-many-panic.log').touch()\n"
                "except OSError as error:\n"
                "    if error.errno != errno.ENOSPC:\n"
                "        raise\n"
                "    panic_inode_enospc = True\n"
                "debug_stats = [path.stat() for path in debug.iterdir()]\n"
                "panic_stats = [path.stat() for path in panic.iterdir()]\n"
                "oracle.write_text(json.dumps({\n"
                "    'direct_enospc': direct_enospc,\n"
                "    'direct_size': direct_size,\n"
                "    'direct_allocated': direct_allocated,\n"
                "    'debug_inode_enospc': debug_inode_enospc,\n"
                "    'aggregate_enospc': aggregate_enospc,\n"
                "    'debug_entries': len(debug_stats),\n"
                "    'debug_source': sum(item.st_size for item in debug_stats),\n"
                "    'debug_allocated': sum(item.st_blocks * 512 for item in debug_stats),\n"
                "    'panic_inode_enospc': panic_inode_enospc,\n"
                "    'panic_entries': len(panic_stats),\n"
                "    'panic_source': sum(item.st_size for item in panic_stats),\n"
                "    'panic_allocated': sum(item.st_blocks * 512 for item in panic_stats),\n"
                "    'late_panic': late_panic.decode('ascii'),\n"
                "}, sort_keys=True), encoding='ascii')\n"
                "print('BOOKEXEC-PAYLOAD-PYTHON book-bytes=1')\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            console = root / "console"
            result = self.guile_in_private_mount_namespace(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(module-set! module 'mount-program "/usr/bin/mount")
(module-set! module 'umount-program "/usr/bin/umount")
(module-set! module 'debug-store-bytes {debug_bytes})
(module-set! module 'panic-store-bytes {panic_bytes})
(module-set! module 'max-direct-debug-log-files {debug_files})
(module-set! module 'max-panic-log-files {panic_files})
(when ((module-ref module 'ipv4-default-route?)
       ((module-ref module 'read-all) "/proc/net/route"))
  (error "private test network namespace has a default route"))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(catch 'book-execution-guest-smoke-error
  (lambda ()
    ((module-ref module 'run-bundle)
     {json.dumps(str(bundle))} "host-flood-diagnostic-store" 'python 1
     "BOOKEXEC-PYTHON-SYSTRAP-PASS")
    (exit 90))
  (lambda (key message)
    (display message)
    (newline)))
(force-output console)
(close-port console)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("exhausted a bounded diagnostic store", result.stdout)
            measured = json.loads(oracle.read_text(encoding="ascii"))
            self.assertTrue(measured["direct_enospc"])
            self.assertLessEqual(measured["direct_size"], debug_bytes)
            self.assertLessEqual(measured["direct_allocated"], debug_bytes)
            self.assertTrue(measured["debug_inode_enospc"])
            self.assertTrue(measured["aggregate_enospc"])
            self.assertEqual(measured["debug_entries"], debug_files)
            self.assertLessEqual(measured["debug_source"], debug_bytes)
            self.assertLessEqual(measured["debug_allocated"], debug_bytes)
            self.assertTrue(measured["panic_inode_enospc"])
            self.assertEqual(measured["panic_entries"], panic_files)
            self.assertLessEqual(measured["panic_source"], panic_bytes)
            self.assertLessEqual(measured["panic_allocated"], panic_bytes)
            self.assertEqual(
                measured["late_panic"], "LATE-PANIC-AFTER-DEBUG-FLOOD\n"
            )
            observed = console.read_text(encoding="utf-8")
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug entries=3 "
                "file-limit=3 source-bytes=65536 allocated-bytes=65536 "
                "capacity-bytes=65536",
                observed,
            )
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW label=runsc-debug", observed
            )
            self.assertIn(
                "BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW label=runsc-panic", observed
            )
            self.assertIn("LATE-PANIC-AFTER-DEBUG-FLOOD\\n", observed)
            self.assertNotIn("BOOKEXEC-PYTHON-SYSTRAP-PASS", observed.splitlines())
            self.assertFalse((bundle / "runsc-debug").exists())
            self.assertFalse((bundle / "runsc-panic").exists())
            self.assertNotIn(
                str(bundle), pathlib.Path("/proc/self/mountinfo").read_text()
            )

    def test_private_diagnostic_store_timeout_reaps_writer_and_unmounts(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-diagnostic-store-timeout-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            (bundle / "runsc-debug").mkdir(mode=0o700)
            (bundle / "runsc-panic").mkdir(mode=0o700)
            pid_file = root / "writer.pid"
            console = root / "console"
            debug_marker = "DEBUG-TIMEOUT-UNWIND-UNIQUE\n"
            panic_marker = "PANIC-TIMEOUT-UNWIND-UNIQUE\n"
            run = bundle / "run.sh"
            run.write_text(
                f"#!{sys.executable}\n"
                "import os, signal, time\n"
                "from pathlib import Path\n"
                f"bundle = Path({str(bundle)!r})\n"
                f"pid_file = Path({str(pid_file)!r})\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                f"(bundle / 'runsc-debug' / 'timeout-debug.log').write_text({debug_marker!r}, encoding='ascii')\n"
                f"(bundle / 'runsc-panic' / 'timeout-panic.log').write_text({panic_marker!r}, encoding='ascii')\n"
                "nspid = next(line for line in Path('/proc/self/status').read_text("
                "encoding='ascii').splitlines() if line.startswith('NSpid:'))\n"
                "host_pid = int(nspid.split()[1])\n"
                "pid_file.write_text(str(host_pid) + '\\n', encoding='ascii')\n"
                "while True:\n"
                "    time.sleep(1)\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            started = time.monotonic()
            result = self.guile_in_private_mount_namespace(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(module-set! module 'mount-program "/usr/bin/mount")
(module-set! module 'umount-program "/usr/bin/umount")
(module-set! module 'debug-store-bytes 65536)
(module-set! module 'panic-store-bytes 16384)
(module-set! module 'process-timeout-seconds 0.5)
(module-set! module 'process-term-grace-seconds 0.1)
(when ((module-ref module 'ipv4-default-route?)
       ((module-ref module 'read-all) "/proc/net/route"))
  (error "private test network namespace has a default route"))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(define caught
 (catch #t
  (lambda ()
    ((module-ref module 'run-bundle)
     {json.dumps(str(bundle))} "host-timeout-diagnostic-store" 'python 1
     "BOOKEXEC-PYTHON-SYSTRAP-PASS")
    '(unexpected-success))
  (lambda (key . arguments)
    ((module-ref module 'emit)
     (format #f "BOOKEXEC-TEST-ORIGINAL-ERROR ~s ~s" key arguments))
    (cons key arguments))))
(force-output console)
(close-port console)
(write caught)
(newline)
"""
            )
            elapsed = time.monotonic() - started
            writer_pid = int(pid_file.read_text(encoding="ascii"))
            try:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(
                    '(book-execution-guest-smoke-error '
                    '"guest command exceeded 0.5 second timeout")',
                    result.stdout,
                )
                self.assertLess(elapsed, 4)
                deadline = time.monotonic() + 2
                while (
                    pathlib.Path(f"/proc/{writer_pid}").exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertFalse(pathlib.Path(f"/proc/{writer_pid}").exists())
                self.assertFalse((bundle / "runsc-debug").exists())
                self.assertFalse((bundle / "runsc-panic").exists())
                self.assertNotIn(
                    str(bundle), pathlib.Path("/proc/self/mountinfo").read_text()
                )
                observed = console.read_text(encoding="utf-8")
                self.assertEqual(
                    observed.count(
                        "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug entries=1 "
                    ),
                    1,
                )
                self.assertEqual(
                    observed.count(
                        "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic entries=1 "
                    ),
                    1,
                )
                self.assertIn(
                    f"source-bytes={len(debug_marker)} "
                    "allocated-bytes=4096 capacity-bytes=65536",
                    observed,
                )
                self.assertIn(
                    f"source-bytes={len(panic_marker)} "
                    "allocated-bytes=4096 capacity-bytes=16384",
                    observed,
                )
                self.assertIn(f"| {debug_marker.rstrip()}\\n", observed)
                self.assertIn(f"| {panic_marker.rstrip()}\\n", observed)
                self.assertEqual(observed.count("overflow=#f"), 2)
                self.assertNotIn("BOOKEXEC-PYTHON-SYSTRAP-PASS", observed.splitlines())
                error_index = observed.index("BOOKEXEC-TEST-ORIGINAL-ERROR")
                self.assertLess(observed.index(debug_marker.rstrip()), error_index)
                self.assertLess(observed.index(panic_marker.rstrip()), error_index)
                self.assertLessEqual(
                    (bundle / "runsc.stdout").stat().st_size, MAX_CAPTURE_BYTES
                )
                self.assertLessEqual(
                    (bundle / "runsc.stderr").stat().st_size, MAX_CAPTURE_BYTES
                )
            finally:
                if pathlib.Path(f"/proc/{writer_pid}").exists():
                    os.kill(writer_pid, signal.SIGKILL)

    def test_private_diagnostic_store_final_capture_error_reaps_descendant_first(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-diagnostic-store-final-eof-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            (bundle / "runsc-debug").mkdir(mode=0o700)
            (bundle / "runsc-panic").mkdir(mode=0o700)
            pid_file = root / "descendant.pid"
            console = root / "console"
            debug_marker = "DEBUG-FINAL-EOF-UNIQUE\n"
            panic_marker = "PANIC-FINAL-EOF-UNIQUE\n"
            run = bundle / "run.sh"
            run.write_text(
                f"#!{sys.executable}\n"
                "import os, time\n"
                "from pathlib import Path\n"
                f"bundle = Path({str(bundle)!r})\n"
                f"pid_file = Path({str(pid_file)!r})\n"
                f"(bundle / 'runsc-debug' / 'final-eof-debug.log').write_text({debug_marker!r}, encoding='ascii')\n"
                f"(bundle / 'runsc-panic' / 'final-eof-panic.log').write_text({panic_marker!r}, encoding='ascii')\n"
                "child = os.fork()\n"
                "if child == 0:\n"
                "    nspid = next(line for line in Path('/proc/self/status').read_text(encoding='ascii').splitlines() if line.startswith('NSpid:'))\n"
                "    pid_file.write_text(str(int(nspid.split()[1])) + '\\n', encoding='ascii')\n"
                "    time.sleep(0.1)\n"
                "    os._exit(0)\n"
                "deadline = time.monotonic() + 1\n"
                "while not pid_file.exists() and time.monotonic() < deadline:\n"
                "    time.sleep(0.01)\n"
                "os.waitpid(child, 0)\n"
                "os._exit(0)\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            started = time.monotonic()
            result = self.guile_in_private_mount_namespace(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(module-set! module 'mount-program "/usr/bin/mount")
(module-set! module 'umount-program "/usr/bin/umount")
(module-set! module 'debug-store-bytes 65536)
(module-set! module 'panic-store-bytes 16384)
(module-set! module 'process-timeout-seconds 2.0)
(module-set! module 'process-term-grace-seconds 0.2)
;; Force the real finalize-captures! deadline branch after the fixture leader
;; has reaped its same-group descendant.  No writer remains when run-bundle
;; observes either direct store.
(define original-pump (module-ref module 'pump-captures))
(define original-setup (module-ref module 'diagnostic-store-setup!))
(define original-cleanup (module-ref module 'diagnostic-store-cleanup!))
(module-set! module 'diagnostic-store-setup!
             (lambda (bundle)
               (let ((stores (original-setup bundle)))
                 (module-set! module 'pump-captures
                              (lambda (captures microseconds)
                                (usleep microseconds)))
                 stores)))
(module-set! module 'diagnostic-store-cleanup!
             (lambda (stores bundle)
               (module-set! module 'pump-captures original-pump)
               (original-cleanup stores bundle)))
;; Prove a subordinate debug-rendering error cannot replace the EOF failure or
;; suppress the independently reserved panic evidence.
(module-set! module 'emit-runsc-debug-diagnostics
             (lambda (directory)
               (throw 'fixture-debug-render-error directory)))
(when ((module-ref module 'ipv4-default-route?)
       ((module-ref module 'read-all) "/proc/net/route"))
  (error "private test network namespace has a default route"))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(define caught
 (catch #t
  (lambda ()
    ((module-ref module 'run-bundle)
     {json.dumps(str(bundle))} "host-final-eof-diagnostic-store" 'python 1
     "BOOKEXEC-PYTHON-SYSTRAP-PASS")
    '(unexpected-success))
  (lambda (key . arguments)
    ((module-ref module 'emit)
     (format #f "BOOKEXEC-TEST-ORIGINAL-ERROR ~s ~s" key arguments))
    (cons key arguments))))
(force-output console)
(close-port console)
(write caught)
(newline)
"""
            )
            elapsed = time.monotonic() - started
            self.assertTrue(pid_file.exists(), result.stdout + result.stderr)
            descendant_pid = int(pid_file.read_text(encoding="ascii"))
            try:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(
                    '(book-execution-guest-smoke-error '
                    '"capture pipe remained open after owned process-group cleanup")',
                    result.stdout,
                )
                self.assertLess(elapsed, 4)
                deadline = time.monotonic() + 2
                while (
                    pathlib.Path(f"/proc/{descendant_pid}").exists()
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.01)
                self.assertFalse(pathlib.Path(f"/proc/{descendant_pid}").exists())
                self.assertFalse((bundle / "runsc-debug").exists())
                self.assertFalse((bundle / "runsc-panic").exists())
                self.assertNotIn(
                    str(bundle), pathlib.Path("/proc/self/mountinfo").read_text()
                )
                observed = console.read_text(encoding="utf-8")
                self.assertEqual(
                    observed.count(
                        "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug entries=1 "
                    ),
                    1,
                )
                self.assertEqual(
                    observed.count(
                        "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic entries=1 "
                    ),
                    1,
                )
                self.assertIn(
                    f"source-bytes={len(debug_marker)} "
                    "allocated-bytes=4096 capacity-bytes=65536",
                    observed,
                )
                self.assertIn(
                    f"source-bytes={len(panic_marker)} "
                    "allocated-bytes=4096 capacity-bytes=16384",
                    observed,
                )
                self.assertIn("state=unavailable scope=runsc-debug-files", observed)
                self.assertIn(f"| {panic_marker.rstrip()}\\n", observed)
                self.assertEqual(observed.count("overflow=#f"), 2)
                self.assertNotIn("BOOKEXEC-PYTHON-SYSTRAP-PASS", observed.splitlines())
                error_index = observed.index("BOOKEXEC-TEST-ORIGINAL-ERROR")
                self.assertLess(
                    observed.index("state=unavailable scope=runsc-debug-files"),
                    error_index,
                )
                self.assertLess(observed.index(panic_marker.rstrip()), error_index)
            finally:
                if pathlib.Path(f"/proc/{descendant_pid}").exists():
                    os.kill(descendant_pid, signal.SIGKILL)

    def test_guile_payload_is_fixed_and_emits_computed_sentinel(self) -> None:
        result = self.guile(
            """
(use-modules (guest-smoke) (json))
(scm->json (guile-process-arguments) (current-output-port) #:unicode #t)
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = json.loads(result.stdout)
        self.assertEqual(argv[:3], ["/profile/bin/guile", "--no-auto-compile", "-c"])
        payload = argv[3]
        self.assertIn('call-with-input-file "/book/input"', payload)
        self.assertIn('call-with-output-file "/scratch/book-size"', payload)
        self.assertIn('inet-pton AF_INET "192.0.2.1"', payload)
        self.assertIn("BOOKEXEC-PAYLOAD-GUILE book-bytes=~a", payload)
        self.assertIn("(bytevector-length data)", payload)

    def invoke_run_bundle_fixture(
        self, output: str, language: str, expected_bytes: int
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory(prefix="wilkbook-payload-output-") as raw:
            root = pathlib.Path(raw)
            bundle = root / "bundle"
            bundle.mkdir(mode=0o700)
            run = bundle / "run.sh"
            run.write_text(
                f"#!{sys.executable}\nimport sys\nsys.stdout.write({output!r})\n",
                encoding="utf-8",
            )
            run.chmod(0o500)
            console = root / "console.log"
            result = self.guile(
                f"""
(use-modules (guest-smoke))
(define module (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(console))}))
(module-set! module 'console-port console)
(module-set! module 'diagnostic-store-setup! (lambda (bundle) '()))
(module-set! module 'diagnostic-store-cleanup!
             (lambda (stores bundle) #t))
(define status
  (catch 'book-execution-guest-smoke-error
    (lambda ()
      ((module-ref module 'run-bundle)
       {json.dumps(str(bundle))} "host-payload-fixture" '{language}
       {expected_bytes} "BOOKEXEC-{language.upper()}-SYSTRAP-PASS")
      0)
    (lambda arguments 1)))
(force-output console)
(close-port console)
(exit status)
"""
            )
            return result, console.read_text(encoding="utf-8")

    def test_run_bundle_requires_exact_distinct_payload_output_before_pass(self) -> None:
        count = 37
        python_output = f"BOOKEXEC-PAYLOAD-PYTHON book-bytes={count}\n"
        guile_output = f"BOOKEXEC-PAYLOAD-GUILE book-bytes={count}\n"
        failures = {
            "empty": "",
            "wrong-language": guile_output,
            "wrong-count": f"BOOKEXEC-PAYLOAD-PYTHON book-bytes={count + 1}\n",
            "duplicate": python_output + python_output,
        }
        for name, output in failures.items():
            with self.subTest(name=name):
                result, console = self.invoke_run_bundle_fixture(output, "python", count)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("BOOKEXEC-PYTHON-SYSTRAP-PASS", console)

        for language, output in (("python", python_output), ("guile", guile_output)):
            with self.subTest(language=language):
                result, console = self.invoke_run_bundle_fixture(output, language, count)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    console, f"BOOKEXEC-{language.upper()}-SYSTRAP-PASS\n"
                )

    def test_guile_process_rewrite_uses_pinned_json_emission(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wilkbook-guest-json-") as raw:
            bundle = pathlib.Path(raw)
            config = bundle / "config.json"
            config.write_text(
                json.dumps(
                    {
                        "ociVersion": "1.0.2",
                        "process": {
                            "args": ["/profile/bin/python3"],
                            "cwd": "/scratch",
                            "env": ["HOME=/scratch"],
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = self.guile(
                """
(use-modules (guest-smoke))
((module-ref (resolve-module '(guest-smoke)) 'select-guile-process)
 (getenv "WILKBOOK_TEST_BUNDLE"))
""",
                {"WILKBOOK_TEST_BUNDLE": str(bundle)},
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            rewritten = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(
                rewritten["process"]["args"][:3],
                ["/profile/bin/guile", "--no-auto-compile", "-c"],
            )
            self.assertIn("GUILE_AUTO_COMPILE=0", rewritten["process"]["env"])

    def test_fixture_is_fixed_systrap_userns_smoke_not_a_broker(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        oci_source = OCI_BUNDLE.read_text(encoding="utf-8")
        system = SYSTEM.read_text(encoding="utf-8")

        for marker in (
            "BOOKEXEC-KERNEL-IDENTITY-PASS",
            "BOOKEXEC-NETWORK-ABSENT-PASS",
            "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
            "BOOKEXEC-RUNSC-VERSION-PASS",
            "BOOKEXEC-PYTHON-SYSTRAP-PASS",
            "BOOKEXEC-GUILE-SYSTRAP-PASS",
            "BOOKEXEC-CGROUP-TEARDOWN-PASS",
            "BOOKEXEC-SMOKE-PASS",
            "BOOKEXEC-SMOKE-FAIL",
        ):
            self.assertIn(marker, source)

        self.assertIn('(define execution-profile "isolation-userns")', source)
        self.assertIn("runsc --version", source)
        self.assertIn("mark-inherited-fds-close-on-exec", source)
        self.assertNotIn("(setrlimit 'fsize", source)
        self.assertIn("size=~a,nr_inodes=~a,mode=0700", source)
        self.assertIn('"wilkbook-runsc-debug"', source)
        self.assertIn('"wilkbook-runsc-panic"', source)
        self.assertIn(
            '"--panic-log=" bundle "/runsc-panic/runsc.panic.%COMMAND%.log"',
            oci_source,
        )
        self.assertIn('(define debug-store-bytes (* 4 1024 1024))', source)
        self.assertIn('(define panic-store-bytes (* 1 1024 1024))', source)
        self.assertIn('(define max-direct-debug-log-files 10)', source)
        self.assertIn('(define max-panic-log-files 2)', source)
        self.assertIn("BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW", source)
        self.assertIn('("hard" . 1048576) ("soft" . 1048576)', oci_source)
        self.assertIn('("type" . "RLIMIT_FSIZE")', oci_source)
        self.assertNotIn("(book-protocol", source)
        self.assertNotIn("book-protocol.scm", source)
        self.assertNotIn("--directfs=true", source)
        self.assertNotIn("--network=host", source)

        self.assertIn("book-execution-guest-smoke-service-type", system)
        self.assertIn("kernel-config-delta=CONFIG_USER_NS:y-after-olddefconfig", system)
        self.assertIn('(define %book-execution-kernel-release "7.1.8")', system)
        self.assertIn("execution-profile=isolation-userns", system)
        self.assertIn("directfs=false", system)
        self.assertIn("network=none", system)
        self.assertIn("platform=systrap", system)
        self.assertIn("ignore-cgroups=false", system)
        self.assertIn("make-forkexec-constructor", system)
        self.assertIn("make-kill-destructor", system)
        self.assertIn("(respawn? #f)", system)
        self.assertIn(
            '(execl "/run/current-system/profile/sbin/halt" "halt")', system
        )
        self.assertNotIn("(one-shot? #t)", system)
        self.assertNotIn('(system* "/run/current-system/profile/sbin/halt")', system)
        self.assertLess(system.index("guest-smoke-main"), system.index("(execl"))
        self.assertNotIn("qemu-aarch64-smoke", system)

    def test_pinned_shepherd_marks_forkexec_service_running_before_child_shutdown(
        self,
    ) -> None:
        candidates = sorted(
            pathlib.Path("/gnu/store").glob("*-shepherd-1.0.9/bin/shepherd")
        )
        selected: tuple[pathlib.Path, pathlib.Path] | None = None
        for shepherd in candidates:
            try:
                version = subprocess.run(
                    [str(shepherd), "--version"],
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=3,
                )
            except OSError:
                continue
            if version.returncode == 0 and "1.0.9" in version.stdout:
                selected = shepherd, shepherd.with_name("herd")
                break
        self.assertIsNotNone(selected, "no cached host Shepherd 1.0.9")
        shepherd, herd = selected  # type: ignore[misc]

        with tempfile.TemporaryDirectory(
            prefix="bookexec-private-shepherd-", dir="/tmp/opencode"
        ) as raw:
            root = pathlib.Path(raw)
            root.chmod(0o700)
            socket = root / "socket"
            log = root / "shepherd.log"
            ready = root / "child-ready"
            release = root / "release-child"
            child_pid = root / "child.pid"
            launcher = root / "launcher"
            launcher.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                f"printf '%s\\n' $$ > {str(child_pid)!r}\n"
                f": > {str(ready)!r}\n"
                f"while [ ! -e {str(release)!r} ]; do sleep 0.01; done\n"
                f"exec {str(herd)!r} -s {str(socket)!r} stop root\n",
                encoding="utf-8",
            )
            launcher.chmod(0o500)
            config = root / "config.scm"
            config.write_text(
                "(use-modules (shepherd service))\n"
                "(register-services\n"
                " (service '(book-execution-guest-smoke)\n"
                "   #:respawn? #f\n"
                "   #:start (make-forkexec-constructor\n"
                f"            (list {json.dumps(str(launcher))})\n"
                "            #:file-creation-mask #o077)\n"
                "   #:stop (make-kill-destructor)))\n"
                "(start-in-the-background '(book-execution-guest-smoke))\n",
                encoding="utf-8",
            )
            process = subprocess.Popen(
                [
                    str(shepherd),
                    "-c",
                    str(config),
                    "-s",
                    str(socket),
                    "-l",
                    str(log),
                ],
                cwd=root,
                env={"HOME": str(root), "LANG": "C", "LC_ALL": "C"},
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if socket.exists() and ready.exists():
                        break
                    if process.poll() is not None:
                        self.fail(
                            "private Shepherd exited before child readiness: "
                            + (process.stderr.read() if process.stderr else "")
                        )
                    time.sleep(0.01)
                self.assertTrue(socket.exists() and ready.exists())
                status = subprocess.run(
                    [
                        str(herd),
                        "-s",
                        str(socket),
                        "status",
                        "book-execution-guest-smoke",
                    ],
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=3,
                )
                self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
                self.assertIn("It is running", status.stdout)
                self.assertIn("Will not be respawned", status.stdout)
                release.touch(mode=0o600)
                self.assertEqual(process.wait(timeout=8), 0)
                pid = int(child_pid.read_text(encoding="ascii"))
                self.assertFalse(pathlib.Path(f"/proc/{pid}").exists())
                lifecycle = log.read_text(encoding="utf-8")
                self.assertIn(
                    "Service book-execution-guest-smoke running with value",
                    lifecycle,
                )
                self.assertIn("Stopping service root", lifecycle)
                self.assertIn("Service book-execution-guest-smoke stopped", lifecycle)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
                if process.stderr:
                    process.stderr.close()

    def test_console_assertions_require_unique_ordered_markers_and_poweroff(self) -> None:
        markers = [
            "BOOKEXEC-KERNEL-IDENTITY-PASS",
            "BOOKEXEC-NETWORK-ABSENT-PASS",
            "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
            "BOOKEXEC-RUNSC-VERSION-PASS",
            "BOOKEXEC-PYTHON-SYSTRAP-PASS",
            "BOOKEXEC-GUILE-SYSTRAP-PASS",
            "BOOKEXEC-CGROUP-TEARDOWN-PASS",
            "BOOKEXEC-SMOKE-PASS",
        ]
        good = "boot noise\n" + "\r\n".join(markers) + "\r\nreboot: Power down\n"
        cases = {
            "good": (good, True),
            "missing": (good.replace(markers[4] + "\r\n", ""), False),
            "duplicate": (good.replace(markers[3], markers[3] + "\r\n" + markers[3]), False),
            "reordered": (
                good.replace(
                    markers[4] + "\r\n" + markers[5],
                    markers[5] + "\r\n" + markers[4],
                ),
                False,
            ),
            "guest-failure": (good + "BOOKEXEC-SMOKE-FAIL runtime\n", False),
            "panic": (good + "Kernel panic - not syncing\n", False),
            "no-poweroff": (good.replace("reboot: Power down\n", ""), False),
        }
        with tempfile.TemporaryDirectory(prefix="wilkbook-console-assert-") as raw:
            root = pathlib.Path(raw)
            for name, (contents, should_pass) in cases.items():
                log = root / f"{name}.log"
                log.write_text(contents, encoding="utf-8")
                result = subprocess.run(
                    ["guile", "--no-auto-compile", str(CONSOLE_ASSERTIONS), str(log)],
                    cwd=REPO,
                    env={
                        "GUILE_AUTO_COMPILE": "0",
                        "HOME": os.environ.get("HOME", "/nonexistent"),
                        "LANG": "C",
                        "LC_ALL": "C",
                        "PATH": os.environ["PATH"],
                    },
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=15,
                )
                self.assertEqual(
                    result.returncode == 0,
                    should_pass,
                    f"{name}: {result.stdout}{result.stderr}",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
