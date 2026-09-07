#!/usr/bin/env python3
"""Host-only outer-envelope tests using fake QEMU executables."""

from __future__ import annotations

import hashlib
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent
RUNNER = HERE / "run-disposable-qemu.scm"
GUEST_SMOKE = HERE / "guest-smoke.scm"
# Exercise the real Guix output shape, not only HASH-test-system: the latter
# masked a runner regexp that rejected the built image before QEMU could start.
SYSTEM = "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
GUEST_MARKERS = (
    "BOOKEXEC-KERNEL-IDENTITY-PASS",
    "BOOKEXEC-NETWORK-ABSENT-PASS",
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
    "BOOKEXEC-RUNSC-VERSION-PASS",
    "BOOKEXEC-PYTHON-SYSTRAP-PASS",
    "BOOKEXEC-GUILE-SYSTRAP-PASS",
    "BOOKEXEC-CGROUP-TEARDOWN-PASS",
    "BOOKEXEC-SMOKE-PASS",
)
VALID_CONSOLE = "boot noise\n" + "\n".join(GUEST_MARKERS) + "\nreboot: Power down\n"


def scheme_kib_constant(source: str, name: str) -> int:
    match = re.search(rf"\(define {re.escape(name)} \(\* (\d+) 1024\)\)", source)
    if match is None:
        raise AssertionError(f"missing fixed Scheme KiB constant: {name}")
    return int(match.group(1)) * 1024


GUEST_SOURCE = GUEST_SMOKE.read_text(encoding="utf-8")
GUEST_DIAGNOSTIC_HEAD_BYTES = scheme_kib_constant(
    GUEST_SOURCE, "diagnostic-head-bytes"
)
GUEST_DIAGNOSTIC_TAIL_BYTES = scheme_kib_constant(
    GUEST_SOURCE, "diagnostic-tail-bytes"
)
GUEST_DEBUG_LOG_FILE_LIMIT_MATCH = re.search(
    r"\(define max-debug-log-files (\d+)\)", GUEST_SOURCE
)
if GUEST_DEBUG_LOG_FILE_LIMIT_MATCH is None:
    raise AssertionError("missing guest max-debug-log-files")
GUEST_DEBUG_LOG_FILE_LIMIT = int(GUEST_DEBUG_LOG_FILE_LIMIT_MATCH.group(1))
GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT_MATCH = re.search(
    r"\(define max-direct-debug-log-files (\d+)\)", GUEST_SOURCE
)
GUEST_PANIC_LOG_FILE_LIMIT_MATCH = re.search(
    r"\(define max-panic-log-files (\d+)\)", GUEST_SOURCE
)
if (
    GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT_MATCH is None
    or GUEST_PANIC_LOG_FILE_LIMIT_MATCH is None
):
    raise AssertionError("missing split guest debug/panic file limits")
GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT = int(
    GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT_MATCH.group(1)
)
GUEST_PANIC_LOG_FILE_LIMIT = int(GUEST_PANIC_LOG_FILE_LIMIT_MATCH.group(1))
GUEST_FIXED_DIAGNOSTIC_CALLS = (
    '(emit-bounded-file-diagnostic "runsc-stdout" stdout)',
    '(emit-bounded-file-diagnostic "runsc-support-stderr" stderr)',
    '(emit-bounded-file-diagnostic "kernel-dmesg" stdout)',
    '(emit-bounded-file-diagnostic "kernel-dmesg-stderr" stderr)',
)
GUEST_DIAGNOSTIC_ESCAPE_EXPANSION = 5
GUEST_DEBUG_FILENAME_MAX_BYTES = 255
MAX_GUEST_DIAGNOSTIC_DATA_BYTES = (
    (len(GUEST_FIXED_DIAGNOSTIC_CALLS) + GUEST_DEBUG_LOG_FILE_LIMIT)
    * (GUEST_DIAGNOSTIC_HEAD_BYTES + GUEST_DIAGNOSTIC_TAIL_BYTES)
    * GUEST_DIAGNOSTIC_ESCAPE_EXPANSION
    + GUEST_DEBUG_LOG_FILE_LIMIT
    * GUEST_DEBUG_FILENAME_MAX_BYTES
    * GUEST_DIAGNOSTIC_ESCAPE_EXPANSION
)
CONSOLE_FRAMING_AND_BOOT_HEADROOM = 2 * 1024 * 1024
MAX_RETAINED_CONSOLE_BYTES = (
    MAX_GUEST_DIAGNOSTIC_DATA_BYTES + CONSOLE_FRAMING_AND_BOOT_HEADROOM
)
MAX_RETAINED_CONSOLE_ESCAPED_CONTENT_BYTES = (
    MAX_RETAINED_CONSOLE_BYTES * GUEST_DIAGNOSTIC_ESCAPE_EXPANSION
)
PR_SET_CHILD_SUBREAPER = 36
PR_GET_CHILD_SUBREAPER = 37
LIBC = ctypes.CDLL(None, use_errno=True)


def ignore_sigchld() -> None:
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)


def subreaper_state() -> bool:
    value = ctypes.c_int()
    if LIBC.prctl(PR_GET_CHILD_SUBREAPER, ctypes.byref(value), 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return bool(value.value)


def set_subreaper(enabled: bool) -> None:
    if LIBC.prctl(PR_SET_CHILD_SUBREAPER, int(enabled), 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def process_identity(pid: int) -> tuple[int, int]:
    stat_line = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    # Fields after the final ')' begin at proc(5) field 3; starttime is 22.
    start_time = int(stat_line[stat_line.rfind(")") + 2 :].split()[19])
    return pid, start_time


def identity_exists(identity: tuple[int, int]) -> bool:
    try:
        return process_identity(identity[0]) == identity
    except FileNotFoundError:
        return False


def exact_kill(identity: tuple[int, int], signal_number: int) -> None:
    if identity_exists(identity):
        os.kill(identity[0], signal_number)


def reap_exact_nonblocking(identity: tuple[int, int]) -> bool:
    try:
        waited, _ = os.waitpid(identity[0], os.WNOHANG)
    except ChildProcessError:
        return not identity_exists(identity)
    return waited == identity[0]


def owned_descendant_identities(
    root: tuple[int, int],
) -> list[tuple[int, int]]:
    """Snapshot descendants reached only through the exact owned process tree."""
    discovered: list[tuple[int, int]] = []
    queue = [root]
    while queue:
        parent = queue.pop(0)
        if not identity_exists(parent):
            continue
        try:
            children = Path(
                f"/proc/{parent[0]}/task/{parent[0]}/children"
            ).read_text(encoding="ascii").split()
        except FileNotFoundError:
            continue
        for raw_pid in children:
            try:
                child = process_identity(int(raw_pid))
            except FileNotFoundError:
                continue
            discovered.append(child)
            queue.append(child)
    return discovered


class DisposableQemuFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-disposable-qemu-test-", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)
        self.top.chmod(0o700)
        self.run_base = self.top / "runs"
        self.run_base.mkdir(mode=0o700)
        self.bundle = self.top / "boot-bundle"
        extlinux = self.bundle / "extlinux"
        extlinux.mkdir(parents=True, mode=0o700)
        self.kernel = extlinux / "Image"
        self.initrd = extlinux / "initrd.cpio.gz"
        self.config = extlinux / "extlinux.conf"
        self.kernel.write_bytes(b"fixed test kernel\n")
        self.initrd.write_bytes(b"fixed test initrd\n")
        self.config.write_text(
            "DEFAULT guix\n"
            "LABEL guix\n"
            "  KERNEL /Image\n"
            "  INITRD /initrd.cpio.gz\n"
            f"  APPEND root=PNGuixRoot gnu.system={SYSTEM} "
            f"gnu.load={SYSTEM}/boot rw console=tty0 "
            "console=ttyS2,1500000n8\n",
            encoding="utf-8",
        )
        for path in (self.kernel, self.initrd, self.config):
            path.chmod(0o444)
        self.kernel_sha256 = hashlib.sha256(self.kernel.read_bytes()).hexdigest()
        self.initrd_sha256 = hashlib.sha256(self.initrd.read_bytes()).hexdigest()
        self.config_sha256 = hashlib.sha256(self.config.read_bytes()).hexdigest()

        self.baseline = self.top / "dedicated-baseline.raw"
        self.baseline.write_bytes(b"fixed dedicated raw baseline\n" * 64)
        self.baseline.chmod(0o444)
        self.baseline_sha256 = hashlib.sha256(self.baseline.read_bytes()).hexdigest()

        self.img_record = self.top / "qemu-img-record.json"
        self.qemu_record = self.top / "qemu-record.json"
        self.parent_pid = self.top / "fake-qemu-parent.pid"
        self.child_pid = self.top / "fake-qemu-child.pid"
        self.qemu_img = self._make_qemu_img()
        self.qemu = self._make_qemu(mode="normal")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_executable(self, name: str, body: str) -> Path:
        path = self.top / name
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _make_qemu_img(self, *, fail: bool = False) -> Path:
        body = f"""import json, os, pathlib, stat, sys
record = pathlib.Path({str(self.img_record)!r})
record.write_text(json.dumps({{
    'argv': sys.argv,
    'cwd': os.getcwd(),
    'env': dict(os.environ),
    'sentinel_fd_open': pathlib.Path('/proc/self/fd/199').exists(),
}}), encoding='utf-8')
if {fail!r}:
    raise SystemExit(23)
pathlib.Path(sys.argv[-1]).write_bytes(b'QFI\\xfbFAKE')
"""
        return self._write_executable("qemu-img", body)

    def _make_qemu(
        self, *, mode: str, console: str | bytes = VALID_CONSOLE
    ) -> Path:
        console_bytes = console.encode("utf-8") if isinstance(console, str) else console
        body = f"""import json, os, pathlib, signal, subprocess, sys, time
record = pathlib.Path({str(self.qemu_record)!r})
parent_pid = pathlib.Path({str(self.parent_pid)!r})
child_pid = pathlib.Path({str(self.child_pid)!r})
if len(sys.argv) == 2 and sys.argv[1] == '--resistant-child':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child_pid.write_text(str(os.getpid()), encoding='ascii')
    while True:
        time.sleep(1)
inherited_fds = []
for name in os.listdir('/proc/self/fd'):
    fd = int(name)
    if fd > 2:
        try:
            os.readlink('/proc/self/fd/' + name)
        except FileNotFoundError:
            continue
        inherited_fds.append(fd)
probe = record.with_suffix('.umask')
fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
os.close(fd)
record.write_text(json.dumps({{
    'argv': sys.argv,
    'cwd': os.getcwd(),
    'env': dict(os.environ),
    'umask_mode': oct(probe.stat().st_mode & 0o777),
    'sentinel_fd_open': pathlib.Path('/proc/self/fd/199').exists(),
    'inherited_fds': inherited_fds,
}}), encoding='utf-8')
chardev = sys.argv[sys.argv.index('-chardev') + 1]
logfile = next(field.split('=', 1)[1] for field in chardev.split(',') if field.startswith('logfile='))
pathlib.Path(logfile).write_bytes({console_bytes!r})
print('VIRTCHK-FAKE-GUEST-ALL-GREEN')
print('fake guest login:', file=sys.stderr)
if {mode!r} in ('resistant', 'orphan-resistant'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, __file__, '--resistant-child'])
    parent_pid.write_text(str(os.getpid()), encoding='ascii')
if {mode!r} == 'resistant':
    while True:
        time.sleep(1)
if {mode!r} == 'nonzero':
    raise SystemExit(17)
"""
        return self._write_executable("qemu-system-aarch64", body)

    def command(self, *extra: str) -> list[str]:
        return [
            "guile",
            "--no-auto-compile",
            "-L",
            str(HERE),
            str(RUNNER),
            "--boot-bundle",
            str(self.bundle),
            "--baseline",
            str(self.baseline),
            "--kernel-sha256",
            self.kernel_sha256,
            "--initrd-sha256",
            self.initrd_sha256,
            "--config-sha256",
            self.config_sha256,
            "--baseline-sha256",
            self.baseline_sha256,
            "--dedicated-baseline",
            "--qemu",
            str(self.qemu),
            "--qemu-img",
            str(self.qemu_img),
            "--cp",
            shutil.which("cp") or "/bin/cp",
            "--sha256sum",
            shutil.which("sha256sum") or "/bin/sha256sum",
            "--run-base",
            str(self.run_base),
            *extra,
        ]

    @staticmethod
    def replace_option(command: list[str], option: str, value: str) -> None:
        command[command.index(option) + 1] = value

    def invoke(
        self,
        *extra: str,
        timeout: float = 10.0,
        inherit_sentinel: bool = False,
        ignored_sigchld: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(
            {
                "SSH_AUTH_SOCK": "/credential/agent.sock",
                "AWS_SECRET_ACCESS_KEY": "must-not-reach-qemu",
                "GVISOR_ENFORCE_RELEASE": "SKIP",
            }
        )
        pass_fds: tuple[int, ...] = ()
        sentinel_read = sentinel_write = None
        try:
            if inherit_sentinel:
                sentinel_read, sentinel_write = os.pipe()
                os.dup2(sentinel_read, 199, inheritable=True)
                pass_fds = (199,)
            return subprocess.run(
                self.command(*extra),
                cwd=HERE.parents[2],
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                pass_fds=pass_fds,
                preexec_fn=ignore_sigchld if ignored_sigchld else None,
            )
        finally:
            if inherit_sentinel:
                os.close(199)
                assert sentinel_read is not None and sentinel_write is not None
                if sentinel_read != 199:
                    os.close(sentinel_read)
                os.close(sentinel_write)

    def assert_no_run_residue(self) -> None:
        self.assertEqual(list(self.run_base.iterdir()), [])

    def assert_pid_gone(self, path: Path) -> None:
        pid = int(path.read_text(encoding="ascii"))
        deadline = time.monotonic() + 3.0
        while Path(f"/proc/{pid}").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(Path(f"/proc/{pid}").exists(), f"PID {pid} survived")

    def assert_qemu_diagnostics(self, result: subprocess.CompletedProcess[str]) -> None:
        for label in ("console.log", "qemu.stderr"):
            self.assertIn(
                f"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label={label}", result.stderr
            )
            self.assertIn(
                f"BOOKEXEC-QEMU-DIAGNOSTIC-END label={label}", result.stderr
            )


class DisposableQemuTests(DisposableQemuFixture):
    def test_full_console_budget_tracks_actual_v5_guest_emitters(self) -> None:
        literal_calls = re.findall(
            r'\(emit-bounded-file-diagnostic "([^"]+)"', GUEST_SOURCE
        )
        self.assertEqual(
            set(literal_calls),
            {
                "runsc-stdout",
                "runsc-support-stderr",
                "kernel-dmesg",
                "kernel-dmesg-stderr",
            },
        )
        self.assertEqual(len(literal_calls), len(GUEST_FIXED_DIAGNOSTIC_CALLS))
        for call in GUEST_FIXED_DIAGNOSTIC_CALLS:
            self.assertEqual(GUEST_SOURCE.count(call), 1, call)
        self.assertEqual(
            len(
                re.findall(
                    r"\(emit-bounded-file-diagnostic\s+"
                    r'\(format #f "~a-~a" file-label index\)',
                    GUEST_SOURCE,
                )
            ),
            1,
        )
        self.assertEqual(GUEST_DIAGNOSTIC_HEAD_BYTES, 8192)
        self.assertEqual(GUEST_DIAGNOSTIC_TAIL_BYTES, 8192)
        self.assertEqual(GUEST_DEBUG_LOG_FILE_LIMIT, 12)
        self.assertEqual(GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT, 10)
        self.assertEqual(GUEST_PANIC_LOG_FILE_LIMIT, 2)
        self.assertEqual(
            GUEST_DIRECT_DEBUG_LOG_FILE_LIMIT + GUEST_PANIC_LOG_FILE_LIMIT,
            GUEST_DEBUG_LOG_FILE_LIMIT,
        )
        self.assertEqual(GUEST_SOURCE.count("emit-runsc-debug-diagnostics"), 3)
        self.assertEqual(GUEST_SOURCE.count("emit-runsc-panic-diagnostics"), 2)
        self.assertEqual(MAX_GUEST_DIAGNOSTIC_DATA_BYTES, 1_326_020)

        expression = """
(use-modules (disposable-qemu))
(format #t "~a ~a ~a ~a~%"
        (@@ (disposable-qemu) max-guest-diagnostic-data-bytes)
        (@@ (disposable-qemu) console-framing-and-boot-headroom)
        (@@ (disposable-qemu) max-retained-console-bytes)
        (@@ (disposable-qemu) max-retained-console-escaped-content-bytes))
"""
        result = subprocess.run(
            ["guile", "--no-auto-compile", "-L", str(HERE), "-c", expression],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        observed = tuple(int(value) for value in result.stdout.split())
        self.assertEqual(
            observed,
            (
                MAX_GUEST_DIAGNOSTIC_DATA_BYTES,
                CONSOLE_FRAMING_AND_BOOT_HEADROOM,
                MAX_RETAINED_CONSOLE_BYTES,
                MAX_RETAINED_CONSOLE_ESCAPED_CONTENT_BYTES,
            ),
        )

    def test_append_parser_real_system_and_fail_closed_paths(self) -> None:
        parser = (
            '(use-modules (disposable-qemu)) '
            '(display ((@@ (disposable-qemu) read-fixed-append) '
            '(cadr (command-line))))'
        )
        original = self.config.read_text()
        named = SYSTEM.replace("-system", "-test-system")
        traversal = SYSTEM.replace("-system", "-foo/../bar-system")
        cases = (
            (original, True, ""),
            (original.replace(SYSTEM, named), True, ""),
            (original.replace("root=PNGuixRoot", "root=PNGuixRoot root=/dev/vda"),
             False, "exactly one root=PNGuixRoot"),
            (original.replace(SYSTEM, traversal), False, "canonical Guix"),
            (original.replace(f"gnu.load={SYSTEM}/boot", f"gnu.load={named}/boot"),
             False, "gnu.load must be"),
        )
        self.config.chmod(0o644)
        for text, accepted, diagnostic in cases:
            with self.subTest(append=text):
                self.config.write_text(text)
                result = subprocess.run(
                    ["guile", "--no-auto-compile", "-L", str(HERE),
                     "-c", parser, str(self.config)],
                    text=True, capture_output=True, timeout=5, check=False,
                )
                self.assertEqual(result.returncode == 0, accepted,
                                 result.stdout + result.stderr)
                if not accepted:
                    self.assertIn(diagnostic, result.stderr)
        self.assertFalse(self.qemu_record.exists())

    def test_exact_networkless_private_copy_overlay_and_environment(self) -> None:
        baseline_before = (
            self.baseline.stat().st_ino,
            self.baseline.stat().st_size,
            stat.S_IMODE(self.baseline.stat().st_mode),
            hashlib.sha256(self.baseline.read_bytes()).hexdigest(),
        )
        result = self.invoke(
            "--timeout-seconds",
            "2",
            "--term-grace-seconds",
            "0.2",
            inherit_sentinel=True,
            ignored_sigchld=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            "OUTER-QEMU-STATUS=0; GUEST-CHECKER-STATUS=0; GUEST-ASSERTIONS=PASS",
        )
        self.assertNotIn("VIRTCHK-FAKE-GUEST-ALL-GREEN", result.stdout + result.stderr)
        self.assertNotIn("login:", result.stdout + result.stderr)
        self.assertNotIn("BOOKEXEC-QEMU-DIAGNOSTIC", result.stderr)

        image = json.loads(self.img_record.read_text(encoding="utf-8"))
        qemu = json.loads(self.qemu_record.read_text(encoding="utf-8"))
        image_argv = image["argv"]
        argv = qemu["argv"]
        self.assertEqual(image_argv[1:8], ["create", "-q", "-f", "qcow2", "-F", "raw", "-b"])
        self.assertNotIn(str(self.baseline), image_argv)
        self.assertTrue(image_argv[8].endswith("/baseline.raw"))
        self.assertTrue(image_argv[9].endswith("/disk-overlay.qcow2"))

        self.assertIn("-no-user-config", argv)
        self.assertIn("-nodefaults", argv)
        nic = argv.index("-nic")
        self.assertEqual(argv[nic + 1], "none")
        accel = argv.index("-accel")
        self.assertEqual(argv[accel + 1], "tcg,thread=multi")
        monitor = argv.index("-monitor")
        self.assertEqual(argv[monitor + 1], "none")
        self.assertNotIn("-nographic", argv)
        self.assertNotIn("-net", argv)
        self.assertNotIn("-netdev", argv)
        self.assertNotIn("-virtfs", argv)
        self.assertNotIn("-fsdev", argv)
        self.assertNotIn("-qmp", argv)
        self.assertNotIn("-enable-kvm", argv)
        rendered = "\n".join(argv)
        self.assertNotIn(str(self.baseline), rendered)
        self.assertNotIn(str(self.bundle), rendered)
        self.assertNotIn("/dev/kvm", rendered)
        self.assertNotIn("/data", rendered)
        self.assertNotIn("ssh", rendered.lower())

        chardev = argv[argv.index("-chardev") + 1]
        self.assertIn("socket,id=console0", chardev)
        self.assertIn("/console.sock", chardev)
        self.assertIn("/console.log", chardev)
        run_root = Path(qemu["cwd"])
        self.assertEqual(run_root.parent, self.run_base)
        self.assertIn(str(run_root), chardev)
        self.assertTrue(argv[argv.index("-kernel") + 1].startswith(str(run_root)))
        self.assertTrue(argv[argv.index("-initrd") + 1].startswith(str(run_root)))
        self.assertEqual(
            argv[argv.index("-device") + 1], "virtio-blk-pci,drive=rootfs-overlay"
        )
        self.assertIn("root=PNGuixRoot", argv[argv.index("-append") + 1])
        self.assertIn("console=ttyAMA0", argv[argv.index("-append") + 1])
        self.assertNotIn("console=ttyS2", argv[argv.index("-append") + 1])

        expected_environment = {
            "HOME": str(run_root / "home"),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": str(self.qemu.parent),
            "TMPDIR": str(run_root / "tmp"),
            "XDG_CACHE_HOME": str(run_root / "xdg-cache"),
            "XDG_CONFIG_HOME": str(run_root / "xdg-config"),
            "XDG_RUNTIME_DIR": str(run_root / "xdg-runtime"),
        }
        self.assertEqual(qemu["env"], expected_environment)
        self.assertEqual(image["env"], expected_environment)
        self.assertFalse(qemu["sentinel_fd_open"])
        self.assertFalse(image["sentinel_fd_open"])
        self.assertEqual(qemu["inherited_fds"], [])
        self.assertEqual(qemu["umask_mode"], "0o600")
        baseline_after = (
            self.baseline.stat().st_ino,
            self.baseline.stat().st_size,
            stat.S_IMODE(self.baseline.stat().st_mode),
            hashlib.sha256(self.baseline.read_bytes()).hexdigest(),
        )
        self.assertEqual(baseline_after, baseline_before)
        self.assert_no_run_residue()

    def test_zero_exit_with_missing_guest_marker_fails_and_cleans(self) -> None:
        missing = VALID_CONSOLE.replace(GUEST_MARKERS[4] + "\n", "")
        self.qemu = self._make_qemu(mode="normal", console=missing)
        result = self.invoke("--timeout-seconds", "2", "--term-grace-seconds", "0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest console assertions failed", result.stderr)
        self.assertIn(GUEST_MARKERS[4], result.stderr)
        self.assert_qemu_diagnostics(result)
        self.assertIn("fake guest login:", result.stderr)
        self.assertNotIn("GUEST-ASSERTIONS=PASS", result.stdout)
        self.assert_no_run_residue()

    def test_zero_exit_with_bad_guest_marker_fails_and_cleans(self) -> None:
        bad = (
            VALID_CONSOLE + "\x1b[31mBOOKEXEC-SMOKE-FAIL injected\r\n"
        ).encode("utf-8") + b"\xff"
        self.qemu = self._make_qemu(mode="normal", console=bad)
        result = self.invoke("--timeout-seconds", "2", "--term-grace-seconds", "0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest console assertions failed", result.stderr)
        self.assertIn("BOOKEXEC-SMOKE-FAIL", result.stderr)
        self.assert_qemu_diagnostics(result)
        self.assertIn(r"\x1b[31mBOOKEXEC-SMOKE-FAIL injected\r\n", result.stderr)
        self.assertIn(r"\xff", result.stderr)
        self.assertNotIn("\x1b", result.stderr)
        self.assertNotIn("GUEST-ASSERTIONS=PASS", result.stdout)
        self.assert_no_run_residue()

    def test_parser_failure_retains_middle_of_max_v5_diagnostic_aggregate(
        self,
    ) -> None:
        evidence = [
            "V5-SELECTED-RUNSC-STDOUT",
            "V5-SELECTED-SUPPORT-PREWARMER-STDERR",
            "V5-SELECTED-RUNSC-RUN-DEBUG",
            "V5-SELECTED-SENTRY-BOOT-DEBUG",
            "V5-SELECTED-GOFER-DEBUG",
            *(f"V5-SELECTED-OTHER-DEBUG-{index}" for index in range(9)),
            "V5-SELECTED-DMESG-STDOUT",
            "V5-SELECTED-DMESG-STDERR",
        ]
        child_fatal = "BOOKEXEC-SMOKE-FAIL V5-PREWARMER-CHILD-FATAL-IN-MIDDLE"
        data = bytearray(b"D" * MAX_GUEST_DIAGNOSTIC_DATA_BYTES)
        for index, marker in enumerate(evidence):
            offset = ((index + 1) * len(data)) // (len(evidence) + 1)
            encoded = marker.encode("ascii")
            data[offset : offset + len(encoded)] = encoded
        middle = len(data) // 2
        fatal_bytes = child_fatal.encode("ascii")
        data[middle : middle + len(fatal_bytes)] = fatal_bytes
        self.assertGreater(middle, 64 * 1024)
        console = b"V5-BOOT-HEAD\n" + bytes(data) + b"\nV5-SHUTDOWN-TAIL\n"
        self.assertLess(len(console), MAX_RETAINED_CONSOLE_BYTES)

        self.qemu = self._make_qemu(mode="normal", console=console)
        result = self.invoke(
            "--timeout-seconds", "2", "--term-grace-seconds", "0.1", timeout=12
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest console assertions failed", result.stderr)
        self.assertIn("retention=full", result.stderr)
        self.assertIn("V5-BOOT-HEAD", result.stderr)
        self.assertIn(child_fatal, result.stderr)
        self.assertIn("V5-SHUTDOWN-TAIL", result.stderr)
        for marker in evidence:
            self.assertIn(marker, result.stderr)
        self.assertNotIn("GUEST-ASSERTIONS=PASS", result.stdout)
        self.assert_no_run_residue()

    def test_full_console_overflow_is_explicit_and_cannot_pass(self) -> None:
        console = (
            VALID_CONSOLE.encode("ascii")
            + b"O" * (MAX_RETAINED_CONSOLE_BYTES + 1)
        )
        self.qemu = self._make_qemu(mode="normal", console=console)
        result = self.invoke(
            "--timeout-seconds", "2", "--term-grace-seconds", "0.1", timeout=12
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE "
            "label=console.log state=overflow",
            result.stderr,
        )
        self.assertIn(
            f"limit-bytes={MAX_RETAINED_CONSOLE_BYTES}", result.stderr
        )
        self.assertIn("diagnostic evidence would be incomplete", result.stderr)
        self.assertNotIn(
            "BOOKEXEC-QEMU-DIAGNOSTIC-END label=console.log", result.stderr
        )
        self.assertNotIn("GUEST-ASSERTIONS=PASS", result.stdout)
        self.assert_no_run_residue()

    def test_timeout_kills_term_resistant_process_group_and_removes_run_root(self) -> None:
        timeout_console = (
            "TIMEOUT-CONSOLE-HEAD\n"
            + "A" * 40000
            + "\nTIMEOUT-CONSOLE-MIDDLE-MUST-BE-RETAINED\n"
            + "B" * 40000
            + "\nTIMEOUT-CONSOLE-TAIL\n"
        )
        self.qemu = self._make_qemu(mode="resistant", console=timeout_console)
        result = self.invoke(
            "--timeout-seconds", "0.3", "--term-grace-seconds", "0.1", timeout=8
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outer timeout", result.stderr)
        self.assert_qemu_diagnostics(result)
        self.assertIn("label=console.log source-bytes=", result.stderr)
        self.assertIn("retention=full", result.stderr)
        self.assertIn("TIMEOUT-CONSOLE-HEAD", result.stderr)
        self.assertIn("TIMEOUT-CONSOLE-TAIL", result.stderr)
        self.assertIn("TIMEOUT-CONSOLE-MIDDLE-MUST-BE-RETAINED", result.stderr)
        self.assertIn("fake guest login:", result.stderr)
        self.assertLess(len(result.stderr.encode("utf-8")), 160 * 1024)
        self.assert_pid_gone(self.parent_pid)
        self.assert_pid_gone(self.child_pid)
        self.assert_no_run_residue()

    def test_nonzero_qemu_emits_diagnostics_and_removes_run_root(self) -> None:
        self.qemu = self._make_qemu(
            mode="nonzero", console="NONZERO-CONSOLE-BOOT\nNONZERO-CONSOLE-END\n"
        )
        result = self.invoke(
            "--timeout-seconds", "2", "--term-grace-seconds", "0.1"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QEMU exited with status 17", result.stderr)
        self.assert_qemu_diagnostics(result)
        self.assertIn(r"NONZERO-CONSOLE-BOOT\n", result.stderr)
        self.assertIn(r"NONZERO-CONSOLE-END\n", result.stderr)
        self.assertIn("fake guest login:", result.stderr)
        self.assert_no_run_residue()

    def test_clean_parent_exit_still_kills_resistant_descendant(self) -> None:
        self.qemu = self._make_qemu(mode="orphan-resistant")
        result = self.invoke(
            "--timeout-seconds", "2", "--term-grace-seconds", "0.1", timeout=8
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_pid_gone(self.parent_pid)
        self.assert_pid_gone(self.child_pid)
        self.assert_no_run_residue()

    def test_signal_kills_term_resistant_process_group_and_removes_run_root(self) -> None:
        self.qemu = self._make_qemu(mode="resistant")
        process = subprocess.Popen(
            self.command("--timeout-seconds", "30", "--term-grace-seconds", "0.1"),
            cwd=HERE.parents[2],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5.0
        while not self.child_pid.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(self.child_pid.exists(), "fake QEMU child did not start")
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stdout + stderr)
        self.assertIn("owned QEMU group cleaned", stderr)
        self.assert_pid_gone(self.parent_pid)
        self.assert_pid_gone(self.child_pid)
        self.assert_no_run_residue()

    def test_owner_sigkill_guardians_reap_group_and_remove_run_root(self) -> None:
        self.qemu = self._make_qemu(mode="resistant")
        previous_subreaper = subreaper_state()
        process: subprocess.Popen[str] | None = None
        identities: dict[str, tuple[int, int]] = {}
        set_subreaper(True)
        try:
            process = subprocess.Popen(
                self.command(
                    "--timeout-seconds", "30", "--term-grace-seconds", "0.1"
                ),
                cwd=HERE.parents[2],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                preexec_fn=ignore_sigchld,
            )
            identities["owner"] = process_identity(process.pid)
            deadline = time.monotonic() + 5.0
            while not self.child_pid.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.child_pid.exists(), "resistant descendant did not start")

            qemu_pid = int(self.parent_pid.read_text(encoding="ascii"))
            child_pid = int(self.child_pid.read_text(encoding="ascii"))
            identities["qemu"] = process_identity(qemu_pid)
            identities["resistant-child"] = process_identity(child_pid)
            process_guardian_pid = int(
                next(
                    line.split()[1]
                    for line in Path(f"/proc/{qemu_pid}/status")
                    .read_text(encoding="ascii")
                    .splitlines()
                    if line.startswith("PPid:")
                )
            )

            owner_children = {
                int(value)
                for value in Path(
                    f"/proc/{process.pid}/task/{process.pid}/children"
                ).read_text(encoding="ascii").split()
            }
            self.assertIn(process_guardian_pid, owner_children)
            self.assertEqual(
                len(owner_children), 2, f"unexpected owner children: {owner_children}"
            )
            root_guardian_pid = next(
                pid for pid in owner_children if pid != process_guardian_pid
            )
            identities["process-guardian"] = process_identity(process_guardian_pid)
            identities["root-guardian"] = process_identity(root_guardian_pid)
            self.assertEqual(len(list(self.run_base.iterdir())), 1)
            qemu_record = json.loads(self.qemu_record.read_text(encoding="utf-8"))
            self.assertEqual(qemu_record["inherited_fds"], [])

            exact_kill(identities["owner"], signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, -signal.SIGKILL, stdout + stderr)

            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                reap_exact_nonblocking(identities["process-guardian"])
                reap_exact_nonblocking(identities["root-guardian"])
                if (
                    all(not identity_exists(identity) for identity in identities.values())
                    and not list(self.run_base.iterdir())
                ):
                    break
                time.sleep(0.02)
            for label, identity in identities.items():
                self.assertFalse(identity_exists(identity), f"{label} PID survived: {identity}")
            self.assert_no_run_residue()
        finally:
            # Failure cleanup is exact and identity-checked.  It never scans by
            # executable name or signals an unrelated process group.
            owner_identity = identities.get("owner")
            if owner_identity is not None:
                known_pids = {identity[0] for identity in identities.values()}
                for index, identity in enumerate(
                    owned_descendant_identities(owner_identity)
                ):
                    if identity[0] not in known_pids:
                        identities[f"failure-descendant-{index}"] = identity
                        known_pids.add(identity[0])
            for label in (
                "resistant-child",
                "qemu",
                "process-guardian",
                "root-guardian",
                "owner",
            ):
                identity = identities.get(label)
                if identity is not None:
                    try:
                        exact_kill(identity, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            for label, identity in identities.items():
                if label.startswith("failure-descendant-"):
                    try:
                        exact_kill(identity, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if process is not None and process.poll() is None:
                process.wait(timeout=3)
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                pending = False
                for identity in identities.values():
                    if identity_exists(identity):
                        pending = True
                        reap_exact_nonblocking(identity)
                if not pending:
                    break
                time.sleep(0.02)
            for run_root in list(self.run_base.iterdir()):
                shutil.rmtree(run_root)
            set_subreaper(previous_subreaper)

    def test_preparation_failure_cleans_private_run_root(self) -> None:
        self.qemu_img = self._make_qemu_img(fail=True)
        result = self.invoke("--timeout-seconds", "1", "--term-grace-seconds", "0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("qemu-img failed with status 23", result.stderr)
        self.assertFalse(self.qemu_record.exists())
        self.assert_no_run_residue()

    def test_mutable_alias_and_hash_inputs_are_rejected_before_qemu(self) -> None:
        self.baseline.chmod(0o644)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("write bits removed", result.stderr)
        self.baseline.chmod(0o444)

        alias = self.top / "baseline-alias.raw"
        alias.symlink_to(self.baseline)
        command = self.command()
        self.replace_option(command, "--baseline", str(alias))
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a symlink", result.stderr)

        bundle_alias = self.top / "boot-bundle-alias"
        bundle_alias.symlink_to(self.bundle, target_is_directory=True)
        command = self.command()
        self.replace_option(command, "--boot-bundle", str(bundle_alias))
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a symlink", result.stderr)

        hardlink = self.top / "baseline-hardlink.raw"
        os.link(self.baseline, hardlink)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hard-link aliases", result.stderr)
        hardlink.unlink()

        command = self.command()
        command.remove("--dedicated-baseline")
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("--dedicated-baseline", result.stderr)

        result = self.invoke("--timeout-seconds", "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        bad_hash_command = self.command()
        self.replace_option(bad_hash_command, "--baseline-sha256", "0" * 64)
        result = subprocess.run(
            bad_hash_command, text=True, capture_output=True, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assert_no_run_residue()

        replacement = self.top / "replacement-kernel"
        replacement.write_bytes(b"different fixed test kernel\n")
        replacement.chmod(0o444)
        self.qemu_record.unlink()
        self.kernel.rename(self.top / "old-kernel")
        replacement.rename(self.kernel)
        result = self.invoke("--timeout-seconds", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("kernel SHA-256 mismatch", result.stderr)
        self.assertFalse(self.qemu_record.exists())
        self.assert_no_run_residue()

        linked_run_base = self.top / "linked-runs"
        linked_run_base.symlink_to(self.run_base)
        result = self.invoke("--run-base", str(linked_run_base))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain a symlink", result.stderr)
        self.assert_no_run_residue()


if __name__ == "__main__":
    unittest.main(verbosity=2)
