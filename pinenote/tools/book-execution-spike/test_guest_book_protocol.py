#!/usr/bin/env python3
"""Host-only lifecycle tests for the actual-guest Book Protocol adapter."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROTOCOL_DIR = REPO / "pinenote/tools/book-protocol"
SESSION_DIR = REPO / "pinenote/tools/book-session"
INVOKE = HERE / "invoke-guest-book-protocol-test.scm"
GUILE_BOOK = HERE / "guest-protocol-book.scm"
PYTHON_BOOK = HERE / "guest_protocol_book.py"
sys.path.insert(0, str(HERE))
import test_oci_book_bundle  # noqa: E402


ACTUAL_GUEST_MARKERS = (
    "BOOKEXEC-PROTOCOL-SOURCE-PROVENANCE-PASS",
    "BOOKEXEC-PROTOCOL-SCHEMA-REJECTION-PASS",
    "BOOKEXEC-PROTOCOL-STALE-REJECTION-PASS",
    "BOOKEXEC-PROTOCOL-TRUNCATED-CLOSE-PASS",
    "BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS",
    "BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS",
    "BOOKEXEC-PROTOCOL-CGROUP-TEARDOWN-PASS",
    "BOOKEXEC-PROTOCOL-PASS",
)


def process_start_time(pid: int) -> str | None:
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return None
    close = text.rfind(")")
    fields = text[close + 2 :].split()
    return fields[19] if close >= 0 and len(fields) >= 20 else None


class GuestProtocolAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.bundle_fixture = test_oci_book_bundle.FixedProtocolBundleTests(
            "test_generator_has_no_cli_or_arbitrary_program_surface"
        )
        self.bundle_fixture.setUp()
        for name in (
            "top",
            "output",
            "guile_entry",
            "guile_protocol",
            "blocking",
            "python_entry",
            "python_protocol",
        ):
            setattr(self, name, getattr(self.bundle_fixture, name))
        for path in (
            self.guile_entry,
            self.guile_protocol,
            self.blocking,
            self.python_entry,
            self.python_protocol,
        ):
            path.chmod(0o644)
        self.guile_entry.write_bytes(GUILE_BOOK.read_bytes())
        self.guile_protocol.write_bytes((PROTOCOL_DIR / "book-protocol.scm").read_bytes())
        self.blocking.write_bytes(
            (PROTOCOL_DIR / "book-protocol/blocking-io.scm").read_bytes()
        )
        self.python_entry.write_bytes(PYTHON_BOOK.read_bytes())
        self.python_protocol.write_bytes((PROTOCOL_DIR / "book_protocol.py").read_bytes())
        for path in (
            self.guile_entry,
            self.guile_protocol,
            self.blocking,
            self.python_entry,
            self.python_protocol,
        ):
            path.chmod(0o444)
        self.guile_bundle = self.output / "guile"
        self.python_bundle = self.output / "python"
        for kind, bundle in (
            ("guile", self.guile_bundle),
            ("python", self.python_bundle),
        ):
            generated = self.bundle_fixture.invoke(kind, bundle)
            self.assertEqual(
                generated.returncode, 0, generated.stdout + generated.stderr
            )

    def tearDown(self) -> None:
        self.bundle_fixture.tearDown()

    def guile_command(self, *arguments: str) -> list[str]:
        return [
            "guile",
            "--no-auto-compile",
            "-L",
            str(PROTOCOL_DIR),
            "-L",
            str(SESSION_DIR),
            "-L",
            str(HERE),
            str(INVOKE),
            *arguments,
        ]

    def run_adapter(
        self, fake_runsc: Path, *, timeout: str = "10"
    ) -> subprocess.CompletedProcess[str]:
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        return subprocess.run(
            self.guile_command(
                "pair",
                str(self.guile_bundle),
                str(self.python_bundle),
                str(fake_runsc),
                timeout,
            ),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(15, int(float(timeout)) + 10),
            check=False,
        )

    def run_adapter_expression(self, expression: str) -> subprocess.CompletedProcess[str]:
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        return subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                str(PROTOCOL_DIR),
                "-L",
                str(SESSION_DIR),
                "-L",
                str(HERE),
                "-c",
                expression,
            ],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )

    def run_adapter_expression_in_private_namespaces(
        self, expression: str
    ) -> subprocess.CompletedProcess[str]:
        unshare = shutil.which("unshare")
        guile = shutil.which("guile")
        self.assertIsNotNone(unshare)
        self.assertIsNotNone(guile)
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
        }
        for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
            if name in os.environ:
                environment[name] = os.environ[name]
        return subprocess.run(
            [
                unshare,
                "--user",
                "--map-root-user",
                "--mount",
                "--net",
                "--propagation",
                "private",
                "--fork",
                guile,
                "--no-auto-compile",
                "-L",
                str(PROTOCOL_DIR),
                "-L",
                str(SESSION_DIR),
                "-L",
                str(HERE),
                "-c",
                expression,
            ],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )

    def require_private_mount_namespace(self) -> None:
        unshare = shutil.which("unshare")
        if unshare is None:
            self.skipTest("unshare is unavailable")
        probe = subprocess.run(
            [
                unshare,
                "--user",
                "--map-root-user",
                "--mount",
                "--net",
                "--propagation",
                "private",
                "--fork",
                "true",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        if probe.returncode != 0:
            self.skipTest(
                "unprivileged private user/mount/network namespaces are unavailable"
            )

    def make_fake_runsc(self, mode: str = "normal") -> Path:
        guile = shutil.which("guile")
        if guile is None:
            self.fail("Guile is required; use the pinned host-check target")
        fake = self.top / f"runsc-{mode}"
        fake.write_text(
            textwrap.dedent(
                f"""\
                #!{sys.executable}
                import fcntl
                import json
                import os
                from pathlib import Path
                import signal
                import socket
                import stat
                import sys
                import time

                MODE = {mode!r}
                args = sys.argv[1:]
                bundle_fields = [x for x in args if x.startswith('--bundle=')]
                if len(bundle_fields) != 1:
                    raise SystemExit('one bundle argument required')
                bundle = Path(bundle_fields[0].split('=', 1)[1])
                launch = json.loads((bundle / 'launch.json').read_text())
                if args != launch['argv'][1:]:
                    raise SystemExit('runsc arguments differ from generated fixed policy')
                if args[-3] != '--pass-fd=3:3':
                    raise SystemExit('exact FD mapping absent')

                open_fds = []
                for name in os.listdir('/proc/self/fd'):
                    try:
                        fd = int(name)
                        fcntl.fcntl(fd, fcntl.F_GETFD)
                    except (ValueError, OSError):
                        continue
                    open_fds.append(fd)
                if sorted(open_fds) != [0, 1, 2, 3]:
                    raise SystemExit(f'unexpected inherited FDs: {{sorted(open_fds)}}')
                if not stat.S_ISSOCK(os.fstat(3).st_mode):
                    raise SystemExit('FD 3 is not a socket')
                if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
                    raise SystemExit('FD 3 remained close-on-exec')
                probe = socket.socket(fileno=os.dup(3))
                try:
                    if probe.family != socket.AF_UNIX or probe.type != socket.SOCK_STREAM:
                        raise SystemExit('FD 3 is not a Unix stream socket')
                    probe.getpeername()
                finally:
                    probe.close()

                stat_text = Path(f'/proc/{{os.getpid()}}/stat').read_text()
                start = stat_text[stat_text.rfind(')') + 2:].split()[19]
                record = (bundle / 'runsc.pid').read_text().split()
                if record != [str(os.getpid()), start, str(os.getpgrp())]:
                    raise SystemExit('parent-owned process identity record mismatch')
                observation = {{
                    'args': args,
                    'fd3_cloexec': False,
                    'open_fds': sorted(open_fds),
                    'pid': os.getpid(),
                    'process_group': os.getpgrp(),
                    'start_time': start,
                }}
                (bundle / 'fake-observation.json').write_text(
                    json.dumps(observation, sort_keys=True) + '\\n'
                )

                if MODE == 'hang':
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    while True:
                        time.sleep(1)
                if MODE == 'spew':
                    os.write(2, b'x' * (4 * 1024 * 1024 + 4096))
                    raise SystemExit(0)
                if MODE == 'duplicate':
                    os.dup2(3, 9, inheritable=True)
                if MODE == 'leak':
                    leaked = os.open('/dev/null', os.O_RDONLY)
                    os.dup2(leaked, 9, inheritable=True)
                    os.close(leaked)

                kind = launch['fixtureKind']
                if MODE == 'crossed':
                    kind = 'guile'
                environment = {{
                    'BOOK_SESSION_FD': '3',
                    'GUILE_AUTO_COMPILE': '0',
                    'HOME': '/nonexistent',
                    'LANG': 'C.UTF-8',
                    'LC_ALL': 'C.UTF-8',
                    'PATH': '/run/current-system/profile/bin',
                    'PYTHONDONTWRITEBYTECODE': '1',
                    'PYTHONPATH': {str(PROTOCOL_DIR)!r},
                }}
                if {os.environ.get('GUILE_LOAD_PATH')!r}:
                    environment['GUILE_LOAD_PATH'] = {os.environ.get('GUILE_LOAD_PATH')!r}
                if {os.environ.get('GUILE_LOAD_COMPILED_PATH')!r}:
                    environment['GUILE_LOAD_COMPILED_PATH'] = (
                        {os.environ.get('GUILE_LOAD_COMPILED_PATH')!r}
                    )
                if kind == 'guile':
                    command = [
                        {guile!r}, '--no-auto-compile', '-L',
                        {str(PROTOCOL_DIR)!r}, {str(GUILE_BOOK)!r}
                    ]
                else:
                    command = [{sys.executable!r}, {str(PYTHON_BOOK)!r}]
                os.execve(command[0], command, environment)
                """
            ),
            encoding="utf-8",
        )
        fake.chmod(0o500)
        return fake

    def assert_no_actual_guest_markers(self, result: subprocess.CompletedProcess[str]) -> None:
        combined = result.stdout + result.stderr
        for bundle in (self.guile_bundle, self.python_bundle):
            for name in ("runsc.stdout", "runsc.stderr"):
                path = bundle / name
                if path.exists():
                    combined += path.read_text(encoding="utf-8", errors="replace")
        for marker in ACTUAL_GUEST_MARKERS:
            self.assertNotIn(marker, combined)

    def test_checked_source_and_profile_provenance(self) -> None:
        profile = Path(
            "/gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-"
            "wilkbook-book-execution-languages"
        )
        closure = Path(
            "/gnu/store/p05h2hdla9lrg10fynmy4qzwvxjy9zp0-"
            "wilkbook-book-execution-language-closure"
        )
        self.assertTrue(profile.is_dir())
        self.assertTrue(closure.is_file())
        arguments = [
            "provenance",
            str(profile),
            str(closure),
            str(HERE / "guest-smoke.scm"),
            str(HERE / "oci-bundle.scm"),
            str(HERE / "oci-book-bundle.scm"),
            str(HERE / "guest-book-protocol.scm"),
            "eb6a1af3713b4b58116c962ba39803310e18fa43ca0939ed5324fe9e456b6e5d",
            str(GUILE_BOOK),
            str(PYTHON_BOOK),
            str(PROTOCOL_DIR / "book-protocol.scm"),
            str(PROTOCOL_DIR / "book-protocol/blocking-io.scm"),
            str(PROTOCOL_DIR / "book_protocol.py"),
            str(SESSION_DIR / "book-session.scm"),
        ]
        environment = os.environ.copy()
        environment["GUILE_AUTO_COMPILE"] = "0"
        result = subprocess.run(
            self.guile_command(*arguments),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout,
            "BOOKEXEC-PROTOCOL-PROVENANCE-HOST-TEST=PASS\n",
        )
        self.assertEqual(result.stderr, "")
        self.assert_no_actual_guest_markers(result)

        arguments[7] = "0" * 64
        rejected = subprocess.run(
            self.guile_command(*arguments),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assert_no_actual_guest_markers(rejected)

    def test_guest_evidence_mode_requires_provenance(self) -> None:
        environment = os.environ.copy()
        environment["GUILE_AUTO_COMPILE"] = "0"
        result = subprocess.run(
            self.guile_command("unproven-guest-mode"),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout,
            "BOOKEXEC-PROTOCOL-UNPROVEN-GUEST-HOST-TEST=PASS\n",
        )
        self.assertEqual(result.stderr, "")
        self.assert_no_actual_guest_markers(result)

    def test_one_time_authority_rejections(self) -> None:
        environment = os.environ.copy()
        environment["GUILE_AUTO_COMPILE"] = "0"
        result = subprocess.run(
            self.guile_command("self-tests"),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout, "BOOKEXEC-PROTOCOL-AUTHORITY-HOST-TEST=PASS\n"
        )
        self.assertEqual(result.stderr, "")
        self.assert_no_actual_guest_markers(result)

    def test_two_real_native_books_through_strict_fake_boundary(self) -> None:
        result = self.run_adapter(self.make_fake_runsc())
        captured = ""
        for bundle in (self.guile_bundle, self.python_bundle):
            for name in ("runsc.stdout", "runsc.stderr"):
                path = bundle / name
                if path.exists():
                    captured += f"\n{path}:\n{path.read_text(errors='replace')}"
        self.assertEqual(
            result.returncode, 0, result.stdout + result.stderr + captured
        )
        self.assertEqual(result.stdout, "BOOKEXEC-PROTOCOL-FD-HOST-TEST=PASS\n")
        self.assertEqual(result.stderr, "")
        self.assert_no_actual_guest_markers(result)

        for bundle in (self.guile_bundle, self.python_bundle):
            observation = json.loads(
                (bundle / "fake-observation.json").read_text(encoding="utf-8")
            )
            self.assertEqual(observation["open_fds"], [0, 1, 2, 3])
            self.assertFalse(observation["fd3_cloexec"])
            self.assertIsNone(process_start_time(observation["pid"]))
            self.assertFalse((bundle / "runsc.pid").exists())
            self.assertFalse((bundle / "runsc-state").exists())
            self.assertLessEqual((bundle / "runsc.stdout").stat().st_size, 4 * 1024 * 1024)
            self.assertLessEqual((bundle / "runsc.stderr").stat().st_size, 4 * 1024 * 1024)

    def test_crossed_endpoint_cannot_pass(self) -> None:
        result = self.run_adapter(self.make_fake_runsc("crossed"), timeout="3")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actual_guest_markers(result)
        for bundle in (self.guile_bundle, self.python_bundle):
            self.assertFalse((bundle / "runsc.pid").exists())

    def test_application_rejects_duplicate_donated_socket(self) -> None:
        result = self.run_adapter(self.make_fake_runsc("duplicate"), timeout="3")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actual_guest_markers(result)
        self.assertFalse((self.guile_bundle / "runsc.pid").exists())

    def test_application_rejects_unrelated_non_cloexec_descriptor(self) -> None:
        result = self.run_adapter(self.make_fake_runsc("leak"), timeout="3")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actual_guest_markers(result)
        self.assertFalse((self.guile_bundle / "runsc.pid").exists())

    def test_whole_run_deadline_kills_exact_owned_group(self) -> None:
        result = self.run_adapter(self.make_fake_runsc("hang"), timeout="0.15")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actual_guest_markers(result)
        observation = json.loads(
            (self.guile_bundle / "fake-observation.json").read_text(encoding="utf-8")
        )
        self.assertIsNone(process_start_time(observation["pid"]))
        self.assertFalse((self.guile_bundle / "runsc.pid").exists())

    def test_capture_overflow_is_drained_and_fails(self) -> None:
        result = self.run_adapter(self.make_fake_runsc("spew"), timeout="3")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_actual_guest_markers(result)
        self.assertEqual(
            (self.guile_bundle / "runsc.stderr").stat().st_size,
            4 * 1024 * 1024,
        )
        self.assertFalse((self.guile_bundle / "runsc.pid").exists())

    def test_pinned_statefile_destroy_shape_is_accepted_only_after_unlink(self) -> None:
        """Model pinned StateFile.Destroy while its flock descriptor is open."""
        container_id = "state-destroy-model"
        state_root = self.guile_bundle / "runsc-state"
        state_path = state_root / f"{container_id}_sandbox:{container_id}.state"
        lock_path = state_root / f"{container_id}_sandbox:{container_id}.lock"
        state_path.write_text("pinned-state-model\n", encoding="ascii")
        lock_fd = os.open(lock_path, os.O_RDONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            state_path.unlink()
            lock_path.unlink()
            result = self.run_adapter_expression(
                f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
((module-ref (resolve-module '(guest-book-protocol))
             'assert-runtime-state-clean!)
 {json.dumps(str(self.guile_bundle))} {json.dumps(container_id)})
"""
            )
        finally:
            os.close(lock_fd)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(state_root.exists())

    def test_source_exact_runsc_state_residue_is_diagnosed_not_deleted(self) -> None:
        container_id = "state-residue-model"
        state_root = self.guile_bundle / "runsc-state"
        names = (
            f"{container_id}_sandbox:{container_id}.lock",
            f"{container_id}_sandbox:{container_id}.state",
        )
        for name in names:
            (state_root / name).write_text(f"model {name}\n", encoding="ascii")
        diagnostic = self.top / "runtime-state-diagnostic.log"
        result = self.run_adapter_expression(
            f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(diagnostic))}))
(module-set! smoke 'console-port console)
(catch 'book-execution-protocol-integration-error
  (lambda ()
    ((module-ref adapter 'assert-runtime-state-clean!)
     {json.dumps(str(self.guile_bundle))} {json.dumps(container_id)})
    (exit 90))
  (lambda (key message)
    ((module-ref adapter 'emit-runtime-state-diagnostics)
     {json.dumps(str(self.guile_bundle))} {json.dumps(container_id)})
    (force-output console)
    (close-port console)
    (display message)))
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout,
            f"runtime left state entries for {container_id}",
        )
        observed = diagnostic.read_text(encoding="ascii")
        self.assertIn(
            f"container={container_id} state=directory",
            observed,
        )
        self.assertIn("entries=2 emitted=2 limit=4", observed)
        self.assertEqual(
            observed.count("BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ENTRY"), 2
        )
        self.assertEqual(observed.count("type=regular"), 2)
        for name in names:
            self.assertIn(f"| {name}\n", observed)
            self.assertTrue((state_root / name).is_file())

    def test_runtime_state_residue_kinds_all_remain_fatal_and_preserved(self) -> None:
        container_id = "strict-state-model"
        cases = ("unknown", "directory", "symlink", "other-container")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix="wilkbook-state-residue-", dir="/tmp/opencode"
            ) as raw:
                bundle = Path(raw)
                state_root = bundle / "runsc-state"
                state_root.mkdir(mode=0o700)
                entry = state_root / {
                    "unknown": "unexpected.entry",
                    "directory": "nested",
                    "symlink": "link",
                    "other-container": "other_sandbox:other.state",
                }[case]
                if case == "directory":
                    entry.mkdir()
                elif case == "symlink":
                    entry.symlink_to("missing-target")
                else:
                    entry.write_text("residue\n", encoding="ascii")
                result = self.run_adapter_expression(
                    f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(catch 'book-execution-protocol-integration-error
  (lambda ()
    ((module-ref (resolve-module '(guest-book-protocol))
                 'assert-runtime-state-clean!)
     {json.dumps(str(bundle))} {json.dumps(container_id)})
    (exit 90))
  (lambda (key message) (display message)))
"""
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(
                    result.stdout,
                    f"runtime left state entries for {container_id}",
                )
                self.assertTrue(os.path.lexists(entry))
                self.assertTrue(state_root.is_dir())

    def test_runtime_state_diagnostics_are_capped_and_escape_names(self) -> None:
        container_id = "bounded-state-model"
        state_root = self.guile_bundle / "runsc-state"
        names = [f"entry-{index}" for index in range(5)]
        forged = "a-forged\nBOOKEXEC-PROTOCOL-PASS"
        for name in (*names, forged):
            (state_root / name).write_text("not-emitted\n", encoding="ascii")
        diagnostic = self.top / "bounded-runtime-state-diagnostic.log"
        result = self.run_adapter_expression(
            f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define smoke (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(diagnostic))}))
(module-set! smoke 'console-port console)
((module-ref (resolve-module '(guest-book-protocol))
             'emit-runtime-state-diagnostics)
 {json.dumps(str(self.guile_bundle))} {json.dumps(container_id)})
(close-port console)
"""
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        observed = diagnostic.read_text(encoding="ascii")
        self.assertIn("state=directory", observed)
        self.assertIn("entries=6 emitted=4 limit=4", observed)
        self.assertEqual(
            observed.count("BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ENTRY"), 4
        )
        self.assertIn("| a-forged\\n\n| BOOKEXEC-PROTOCOL-PASS\n", observed)
        self.assertNotIn("\nBOOKEXEC-PROTOCOL-PASS\n", observed)
        for name in names[:3]:
            self.assertIn(f"| {name}\n", observed)
        self.assertNotIn("| entry-3\n", observed)
        self.assertNotIn("| entry-4\n", observed)
        self.assertNotIn("not-emitted", observed)
        for name in (*names, forged):
            self.assertTrue((state_root / name).is_file())

    def test_owned_null_netns_mount_is_verified_and_nonlazy_unmounted(self) -> None:
        self.require_private_mount_namespace()
        mount = shutil.which("mount")
        umount = shutil.which("umount")
        unshare = shutil.which("unshare")
        self.assertIsNotNone(mount)
        self.assertIsNotNone(umount)
        self.assertIsNotNone(unshare)
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-null-netns-positive-", dir="/tmp/opencode"
        ) as raw:
            bundle = Path(raw)
            state_root = bundle / "runsc-state"
            state_root.mkdir(mode=0o700)
            diagnostic = bundle / "state-cleanup.log"
            container_id = "proper-null-netns-model"
            result = self.run_adapter_expression_in_private_namespaces(
                f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(define console (open-output-file {json.dumps(str(diagnostic))}))
(module-set! smoke 'console-port console)
(module-set! smoke 'umount-program {json.dumps(umount)})
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
(unless (zero? (system* {json.dumps(unshare)} "--net"
                        {json.dumps(mount)} "-n" "--bind" "/proc/self/ns/net"
                        {json.dumps(str(state_root / 'null-netns'))}))
  (error "private namespace bind mount failed"))
((module-ref adapter 'emit-runtime-state-diagnostics)
 {json.dumps(str(bundle))} {json.dumps(container_id)})
((module-ref adapter 'cleanup-owned-runtime-state!) owner
 {json.dumps(container_id)})
(close-port console)
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(state_root.exists())
            observed = diagnostic.read_text(encoding="ascii")
            self.assertIn("entries=1 emitted=1 limit=4", observed)
            self.assertIn("mounts=1 mounts-emitted=1 mount-limit=2", observed)
            self.assertIn(" - nsfs nsfs rw", observed)
            self.assertIn("mount=nsfs namespace=net", observed)
            self.assertIn("action=nonlazy-unmount", observed)
            self.assertNotIn("BOOKEXEC-PROTOCOL-PASS", observed)

    def test_owned_null_netns_cleanup_rejects_root_self_bind_before_pin_action(
        self,
    ) -> None:
        """An unchanged-inode root mount is fatal and preserved before cleanup."""
        self.require_private_mount_namespace()
        mount = shutil.which("mount")
        umount = shutil.which("umount")
        unshare = shutil.which("unshare")
        self.assertIsNotNone(mount)
        self.assertIsNotNone(umount)
        self.assertIsNotNone(unshare)
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-null-netns-root-bind-", dir="/tmp/opencode"
        ) as raw:
            bundle = Path(raw)
            state_root = bundle / "runsc-state"
            state_root.mkdir(mode=0o700)
            pin = state_root / "null-netns"
            diagnostic = bundle / "root-bind-diagnostic.log"
            container_id = "root-self-bind-model"
            result = self.run_adapter_expression_in_private_namespaces(
                f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(define mountinfo-at (module-ref adapter 'mountinfo-at))
(define root-identity (module-ref adapter 'owned-runtime-state-root-identity))
(define placeholder-identity
  (module-ref adapter 'owned-runtime-state-placeholder-identity))
(define private-root? (module-ref adapter 'private-runtime-state-root?))
(define owned-placeholder?
  (module-ref adapter 'owned-null-netns-placeholder?))
(define console (open-output-file {json.dumps(str(diagnostic))}))
(module-set! smoke 'console-port console)
(module-set! smoke 'umount-program {json.dumps(umount)})
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
(unless (zero? (system* {json.dumps(mount)} "-n" "--bind"
                        {json.dumps(str(state_root))}
                        {json.dumps(str(state_root))}))
  (error "state-root self-bind failed"))
(unless (zero? (system* {json.dumps(unshare)} "--net"
                        {json.dumps(mount)} "-n" "--bind" "/proc/self/ns/net"
                        {json.dumps(str(pin))}))
  (error "private namespace bind mount failed"))
((module-ref adapter 'emit-runtime-state-diagnostics)
 {json.dumps(str(bundle))} {json.dumps(container_id)})
(define rejected? #f)
(catch 'book-execution-protocol-integration-error
  (lambda ()
    ((module-ref adapter 'cleanup-owned-runtime-state!) owner
     {json.dumps(container_id)})
    (exit 90))
  (lambda (key message)
    (unless (string=? message
                      "runtime state root became mounted before pin cleanup for {container_id}")
      (error "unexpected rejection" message))
    (set! rejected? #t)))
(unless (and rejected?
             (= (length (mountinfo-at {json.dumps(str(state_root))})) 1)
             (= (length (mountinfo-at {json.dumps(str(pin))})) 1))
  (error "cleanup altered the rejected root or pin mount"))
(force-output console)
(close-port console)
;; The rejection has now been proved non-mutating.  Remove only the two mounts
;; created by this test, reveal and verify the original placeholder, then remove
;; the test-owned files so no namespace fixture residue survives.
(unless (zero? (system* {json.dumps(umount)} "-n" {json.dumps(str(pin))}))
  (error "test pin unmount failed"))
(unless (owned-placeholder? (lstat {json.dumps(str(pin))})
                            (placeholder-identity owner))
  (error "original placeholder was not preserved by rejection"))
(unless (zero? (system* {json.dumps(umount)} "-n"
                        {json.dumps(str(state_root))}))
  (error "test root unmount failed"))
(unless (and (private-root? (lstat {json.dumps(str(state_root))})
                            (root-identity owner))
             (equal? ((module-ref adapter 'directory-entry-names)
                      {json.dumps(str(state_root))}) '("null-netns"))
             (owned-placeholder? (lstat {json.dumps(str(pin))})
                                 (placeholder-identity owner)))
  (error "owned state changed after test mount cleanup"))
(delete-file {json.dumps(str(pin))})
(rmdir {json.dumps(str(state_root))})
(display "REJECTED-PRESERVED: root-mount pin-mount placeholder\n")
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                result.stdout,
                "REJECTED-PRESERVED: root-mount pin-mount placeholder\n",
            )
            self.assertFalse(state_root.exists())
            observed = diagnostic.read_text(encoding="ascii")
            self.assertIn(
                "root-mounts=1 root-mounts-emitted=1 root-mount-limit=2",
                observed,
            )
            self.assertEqual(
                observed.count("BOOKEXEC-DIAGNOSTIC-RUNTIME-STATE-ROOT-MOUNT"),
                1,
            )
            self.assertRegex(observed, r"mount-id=\d+ parent-mount-id=\d+")
            self.assertIn("mounts=1 mounts-emitted=1 mount-limit=2", observed)
            self.assertNotIn("action=nonlazy-unmount", observed)
            self.assertNotIn("BOOKEXEC-PROTOCOL-PASS", observed)

    def test_owned_null_netns_cleanup_rechecks_root_before_placeholder_unlink(
        self,
    ) -> None:
        """A deterministic fixture mutation between observations is caught."""
        self.require_private_mount_namespace()
        mount = shutil.which("mount")
        umount = shutil.which("umount")
        unshare = shutil.which("unshare")
        self.assertIsNotNone(mount)
        self.assertIsNotNone(umount)
        self.assertIsNotNone(unshare)
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-null-netns-root-recheck-", dir="/tmp/opencode"
        ) as raw:
            bundle = Path(raw)
            state_root = bundle / "runsc-state"
            state_root.mkdir(mode=0o700)
            pin = state_root / "null-netns"
            diagnostic = bundle / "root-recheck-diagnostic.log"
            container_id = "root-recheck-model"
            result = self.run_adapter_expression_in_private_namespaces(
                f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(define original-mountinfo-at (module-ref adapter 'mountinfo-at))
(define original-run-fixed-utility (module-ref smoke 'run-fixed-utility))
(define placeholder-identity
  (module-ref adapter 'owned-runtime-state-placeholder-identity))
(define owned-placeholder?
  (module-ref adapter 'owned-null-netns-placeholder?))
(define console (open-output-file {json.dumps(str(diagnostic))}))
(module-set! smoke 'console-port console)
(module-set! smoke 'umount-program {json.dumps(umount)})
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
(unless (zero? (system* {json.dumps(unshare)} "--net"
                        {json.dumps(mount)} "-n" "--bind" "/proc/self/ns/net"
                        {json.dumps(str(pin))}))
  (error "private namespace bind mount failed"))
(define injected? #f)
(module-set!
 smoke 'run-fixed-utility
 (lambda (label argv directory)
   (let ((result (original-run-fixed-utility label argv directory)))
     (when (and (string=? label "unmount-null-netns") (not injected?))
      (unless (zero? (system* {json.dumps(mount)} "-n" "--bind"
                              {json.dumps(str(state_root))}
                              {json.dumps(str(state_root))}))
        (error "deterministic root-mount injection failed"))
       (set! injected? #t))
     result)))
(define rejected? #f)
(catch 'book-execution-protocol-integration-error
  (lambda ()
    ((module-ref adapter 'cleanup-owned-runtime-state!) owner
     {json.dumps(container_id)})
    (exit 90))
  (lambda (key message)
    (unless (string=? message
                      "runtime state root became mounted before placeholder removal for {container_id}")
      (error "unexpected rejection" message))
    (set! rejected? #t)))
(module-set! smoke 'run-fixed-utility original-run-fixed-utility)
(unless (and rejected? injected?
             (= (length (original-mountinfo-at
                         {json.dumps(str(state_root))})) 1)
             (null? (original-mountinfo-at {json.dumps(str(pin))}))
             (owned-placeholder? (lstat {json.dumps(str(pin))})
                                 (placeholder-identity owner)))
  (error "root recheck failed to preserve the revealed placeholder"))
(force-output console)
(close-port console)
;; The pin unmount was the reviewed operation.  Remove the fixture-injected
;; root mount and then the still-owned placeholder/root as test-only cleanup.
(unless (zero? (system* {json.dumps(umount)} "-n"
                        {json.dumps(str(state_root))}))
  (error "test root unmount failed"))
(delete-file {json.dumps(str(pin))})
(rmdir {json.dumps(str(state_root))})
(display "RECHECK-REJECTED-PRESERVED: root-mount placeholder\n")
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                result.stdout,
                "RECHECK-REJECTED-PRESERVED: root-mount placeholder\n",
            )
            self.assertFalse(state_root.exists())
            observed = diagnostic.read_text(encoding="ascii")
            self.assertIn("action=nonlazy-unmount", observed)
            self.assertNotIn("BOOKEXEC-PROTOCOL-PASS", observed)

    def test_owned_null_netns_cleanup_rejects_every_nonmount_residue(self) -> None:
        self.require_private_mount_namespace()
        container_id = "strict-owned-state-model"
        cases = {
            "unexpected": '(call-with-output-file "{extra}" (lambda (p) (display "x" p)))',
            "container-state": '(call-with-output-file "{state}" (lambda (p) (display "x" p)))',
            "container-lock": '(call-with-output-file "{lock}" (lambda (p) (display "x" p)))',
            "control-socket": """
(define residue-socket (socket AF_UNIX SOCK_STREAM 0))
(bind residue-socket AF_UNIX "{socket}")
(close-port residue-socket)
""",
            "symlink": '(delete-file "{pin}") (symlink "missing" "{pin}")',
            "wrong-type": '(delete-file "{pin}") (mkdir "{pin}" #o700)',
            "already-unmounted": "",
            "replaced-root": """
(rename-file "{root}" "{old_root}")
(mkdir "{root}" #o700)
(call-with-output-file "{pin}" (lambda (port) (display "replacement" port)))
(chmod "{pin}" #o444)
""",
        }
        for case, mutation_template in cases.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix="wilkbook-owned-state-negative-", dir="/tmp/opencode"
            ) as raw:
                bundle = Path(raw)
                state_root = bundle / "runsc-state"
                state_root.mkdir(mode=0o700)
                paths = {
                    "pin": state_root / "null-netns",
                    "root": state_root,
                    "old_root": bundle / "replaced-runsc-state",
                    "extra": state_root / "unexpected.entry",
                    "state": state_root
                    / f"{container_id}_sandbox:{container_id}.state",
                    "lock": state_root
                    / f"{container_id}_sandbox:{container_id}.lock",
                    "socket": state_root / f"runsc-{container_id}.sock",
                }
                mutation = mutation_template.format(
                    **{name: str(path) for name, path in paths.items()}
                )
                result = self.run_adapter_expression_in_private_namespaces(
                    f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
{mutation}
(catch 'book-execution-protocol-integration-error
  (lambda ()
    ((module-ref adapter 'cleanup-owned-runtime-state!) owner
     {json.dumps(container_id)})
    (exit 90))
  (lambda (key message) (format #t "REJECTED: ~a~%" message)))
"""
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stdout.startswith("REJECTED: "))
                self.assertNotIn("BOOKEXEC-PROTOCOL-PASS", result.stdout)
                self.assertTrue(state_root.is_dir())
                self.assertTrue(os.path.lexists(paths["pin"]))
                if case not in (
                    "symlink",
                    "wrong-type",
                    "already-unmounted",
                    "replaced-root",
                ):
                    mutated_path = {
                        "unexpected": paths["extra"],
                        "container-state": paths["state"],
                        "container-lock": paths["lock"],
                        "control-socket": paths["socket"],
                    }[case]
                    self.assertTrue(os.path.lexists(mutated_path))
                if case == "replaced-root":
                    self.assertTrue(paths["old_root"].is_dir())

    def test_owned_null_netns_cleanup_rejects_wrong_or_stacked_mount(self) -> None:
        self.require_private_mount_namespace()
        mount = shutil.which("mount")
        unshare = shutil.which("unshare")
        self.assertIsNotNone(mount)
        self.assertIsNotNone(unshare)
        container_id = "wrong-null-netns-mount-model"
        for case in (
            "wrong-namespace",
            "authority-netns",
            "stacked",
            "replaced-placeholder",
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                prefix="wilkbook-owned-mount-negative-", dir="/tmp/opencode"
            ) as raw:
                bundle = Path(raw)
                state_root = bundle / "runsc-state"
                state_root.mkdir(mode=0o700)
                pin = state_root / "null-netns"
                first_source = (
                    "/proc/self/ns/user"
                    if case == "wrong-namespace"
                    else "/proc/self/ns/net"
                )
                replace_placeholder = (
                    f'(delete-file {json.dumps(str(pin))}) '
                    f'(call-with-output-file {json.dumps(str(pin))} '
                    '(lambda (port) (display "replacement" port))) '
                    f'(chmod {json.dumps(str(pin))} #o444)'
                    if case == "replaced-placeholder"
                    else ""
                )
                second_mount = (
                    f'(unless (zero? (system* {json.dumps(unshare)} "--net" '
                    f'{json.dumps(mount)} "-n" "--bind" '
                    f'"/proc/self/ns/net" {json.dumps(str(pin))})) '
                    '(error "second bind mount failed"))'
                    if case == "stacked"
                    else ""
                )
                first_mount = (
                    f'(system* {json.dumps(mount)} "-n" "--bind" '
                    if case in ("wrong-namespace", "authority-netns")
                    else f'(system* {json.dumps(unshare)} "--net" '
                    f'{json.dumps(mount)} "-n" "--bind" '
                )
                result = self.run_adapter_expression_in_private_namespaces(
                    f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(module-set! smoke 'console-port (current-error-port))
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
{replace_placeholder}
(unless (zero? {first_mount}
                        {json.dumps(first_source)} {json.dumps(str(pin))}))
  (error "first bind mount failed"))
{second_mount}
(catch #t
  (lambda ()
    ((module-ref adapter 'cleanup-owned-runtime-state!) owner
     {json.dumps(container_id)})
    (exit 90))
  (lambda (key message) (format #t "REJECTED: ~a~%" message)))
"""
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(result.stdout.startswith("REJECTED: "))
                self.assertNotIn(
                    "BOOKEXEC-PROTOCOL-PASS", result.stdout + result.stderr
                )
                self.assertTrue(state_root.is_dir())
                self.assertTrue(pin.is_file())

    def test_owned_null_netns_cleanup_failure_cannot_pass(self) -> None:
        self.require_private_mount_namespace()
        mount = shutil.which("mount")
        false = shutil.which("false")
        unshare = shutil.which("unshare")
        self.assertIsNotNone(mount)
        self.assertIsNotNone(false)
        self.assertIsNotNone(unshare)
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-null-netns-umount-failure-", dir="/tmp/opencode"
        ) as raw:
            bundle = Path(raw)
            state_root = bundle / "runsc-state"
            state_root.mkdir(mode=0o700)
            pin = state_root / "null-netns"
            container_id = "null-netns-umount-failure-model"
            result = self.run_adapter_expression_in_private_namespaces(
                f"""
(primitive-load (search-path %load-path "guest-book-protocol.scm"))
(define adapter (resolve-module '(guest-book-protocol)))
(define smoke (resolve-module '(guest-smoke)))
(module-set! smoke 'console-port (current-error-port))
(module-set! smoke 'umount-program {json.dumps(false)})
(define owner
  ((module-ref adapter 'prepare-owned-runtime-state!)
   {json.dumps(str(bundle))} {json.dumps(container_id)}))
(unless (zero? (system* {json.dumps(unshare)} "--net"
                        {json.dumps(mount)} "-n" "--bind"
                        "/proc/self/ns/net" {json.dumps(str(pin))}))
  (error "private namespace bind mount failed"))
(catch #t
  (lambda ()
    ((module-ref adapter 'cleanup-owned-runtime-state!) owner
     {json.dumps(container_id)})
    (exit 90))
  (lambda (key message) (format #t "REJECTED: ~a~%" message)))
"""
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(result.stdout.startswith("REJECTED: "))
            self.assertNotIn("BOOKEXEC-PROTOCOL-PASS", result.stdout + result.stderr)
            self.assertIn("action=nonlazy-unmount", result.stderr)
            self.assertTrue(state_root.is_dir())
            self.assertTrue(pin.is_file())

    def test_launch_record_mutation_fails_before_fake_exec(self) -> None:
        launch_path = self.guile_bundle / "launch.json"
        launch = json.loads(launch_path.read_text())
        launch["argv"].remove("--host-uds=none")
        launch_path.write_text(json.dumps(launch), encoding="utf-8")
        result = self.run_adapter(self.make_fake_runsc(), timeout="3")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.guile_bundle / "fake-observation.json").exists())
        self.assert_no_actual_guest_markers(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
