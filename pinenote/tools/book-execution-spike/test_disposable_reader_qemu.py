#!/usr/bin/env python3
"""Host-only reader outer tests with fake coordinator/QEMU/reader children."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import textwrap
import time
import unittest


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
TEST_RUNNER = HERE / "invoke-disposable-reader-qemu-test.scm"
PRODUCTION_RUNNER = HERE / "run-disposable-reader-qemu.scm"
sys.path.insert(0, str(HERE))
import test_disposable_qemu as outer_test  # noqa: E402


DEBUG_STORE = (
    "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-debug entries=1 file-limit=10 "
    "source-bytes=1 allocated-bytes=4096 capacity-bytes=4194304 "
    "invalid-entry=#f byte-exhausted=#f inode-exhausted=#f overflow=#f"
)
PANIC_STORE = (
    "BOOKEXEC-DIAGNOSTIC-STORE label=runsc-panic entries=0 file-limit=2 "
    "source-bytes=0 allocated-bytes=0 capacity-bytes=1048576 "
    "invalid-entry=#f byte-exhausted=#f inode-exhausted=#f overflow=#f"
)
VALID_READER_CONSOLE = "\n".join(
    [
        "Linux boot noise",
        "BOOKEXEC-READER-PROTOCOL-SOURCE-PROVENANCE-PASS",
        "BOOKEXEC-KERNEL-IDENTITY-PASS",
        "BOOKEXEC-NETWORK-ABSENT-PASS",
        "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
        "BOOKEXEC-RUNSC-VERSION-PASS",
        "BOOKEXEC-READER-PROTOCOL-SCHEMA-REJECTION-PASS",
        "BOOKEXEC-READER-PROTOCOL-STALE-REJECTION-PASS",
        "BOOKEXEC-READER-PROTOCOL-TRUNCATED-CLOSE-PASS",
        DEBUG_STORE,
        PANIC_STORE,
        "BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS",
        DEBUG_STORE,
        PANIC_STORE,
        "BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS",
        "BOOKEXEC-READER-PROTOCOL-CGROUP-TEARDOWN-PASS",
        "BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS",
        "BOOKEXEC-READER-PROTOCOL-PASS",
        "reboot: Power down",
        "",
    ]
)
COORDINATOR_SUCCESS = (
    "BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass\n"
)
JOINED_SUCCESS = (
    "OUTER-READER-QEMU-STATUS=0; COORDINATOR-STATUS=0; "
    "NATIVE-READER-LIFECYCLE=PASS; GUEST-READER-PROTOCOL=PASS; "
    "CLEAN-POWER-DOWN=PASS\n"
)
COORDINATOR_RELATIVES = (
    "qemu-coordinator.scm",
    "fixture/bookinteractionprobe.koplugin/_meta.lua",
    "fixture/bookinteractionprobe.koplugin/main.lua",
    "fixture/bookinteractionprobe.koplugin/private_channel.lua",
    "fixture/bookinteractionprobe.koplugin/ui_audit.lua",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_identity(path: Path) -> tuple[int, int]:
    pid, start_time = path.read_text(encoding="ascii").split()
    return int(pid), int(start_time)


class DisposableReaderQemuTests(unittest.TestCase):
    def setUp(self) -> None:
        self.outer = outer_test.DisposableQemuFixture()
        self.outer.setUp()
        self.tracker = self.outer.top / "reader-outer-identities"
        self.tracker.mkdir(mode=0o700)
        self.coordinator = self._make_fake_coordinator()
        self.koreader = self._make_fake_koreader_package()
        self.qemu = self._make_fake_qemu("normal", VALID_READER_CONSOLE)

    def tearDown(self) -> None:
        self.outer.tearDown()

    def _write_executable(self, path: Path, body: str) -> None:
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def _make_fake_koreader_package(self) -> Path:
        package = self.outer.top / (
            "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-koreader-bin-2026.03"
        )
        package.mkdir(mode=0o700)
        return package

    def _make_fake_coordinator(self) -> Path:
        root = self.outer.top / "fake-reader-coordinator"
        plugin = root / "fixture/bookinteractionprobe.koplugin"
        plugin.mkdir(parents=True, mode=0o700)
        coordinator_record = self.tracker / "coordinator.identity"
        source = textwrap.dedent(
            f"""\
            (use-modules (ice-9 textual-ports)
                         (srfi srfi-1)
                         (srfi srfi-13))

            (define (start-time pid)
              (let* ((text (call-with-input-file
                            (format #f "/proc/~a/stat" pid) get-string-all))
                     (fields (string-tokenize
                               (substring text (+ 2 (string-rindex text #\\)))))))
                (list-ref fields 19)))

            (define (option name arguments)
              (let ((tail (member name arguments string=?)))
                (unless (and tail (pair? (cdr tail)))
                  (error "missing fake coordinator option" name))
                (cadr tail)))

            (define arguments (cdr (command-line)))
            (define separator (member "--" arguments string=?))
            (unless (and separator (pair? (cdr separator)))
              (error "missing fake coordinator QEMU vector"))
            (call-with-output-file {json.dumps(str(coordinator_record))}
              (lambda (port)
                (format port "~a ~a~%" (getpid) (start-time (getpid)))))
            (define status
              (apply system* (option "--qemu" arguments) (cdr separator)))
            (if (zero? status)
                (begin
                  (display {json.dumps(COORDINATOR_SUCCESS)})
                  (exit 0))
                (exit 1))
            """
        )
        coordinator = root / "qemu-coordinator.scm"
        coordinator.write_text(source, encoding="utf-8")
        for relative in COORDINATOR_RELATIVES[1:]:
            path = root / relative
            path.write_text(f"-- fixed fake fixture: {path.name}\n", encoding="utf-8")
        self._write_fake_roster(root)
        return coordinator

    def _write_fake_roster(self, root: Path) -> None:
        entries = "\n".join(
            f"  ({json.dumps(relative)} . {json.dumps(sha256(root / relative))})"
            for relative in COORDINATOR_RELATIVES
        )
        self.roster = self.outer.top / "fake-coordinator-roster.scm"
        self.roster.write_text(f"(\n{entries}\n)\n", encoding="ascii")
        self.roster.chmod(0o400)

    def _make_fake_qemu(self, mode: str, console: str) -> Path:
        qemu = self.outer.top / f"qemu-reader-{mode}"
        qemu_record = self.tracker / "qemu.identity"
        reader_record = self.tracker / "reader.identity"
        tree_record = self.tracker / "private-tree.json"
        premature_removal = self.tracker / "premature-removal"
        body = textwrap.dedent(
            f"""\
            import json
            import os
            from pathlib import Path
            import signal
            import socket
            import stat
            import sys
            import time

            MODE = {mode!r}
            CONSOLE = {console!r}
            QEMU_RECORD = Path({str(qemu_record)!r})
            READER_RECORD = Path({str(reader_record)!r})
            TREE_RECORD = Path({str(tree_record)!r})
            PREMATURE_REMOVAL = Path({str(premature_removal)!r})
            COORDINATOR_SUCCESS = {COORDINATOR_SUCCESS!r}

            def identity(pid):
                text = Path(f'/proc/{{pid}}/stat').read_text(encoding='ascii')
                return pid, int(text[text.rfind(')') + 2:].split()[19])

            def write_identity(path, pid):
                current = identity(pid)
                path.write_text(f'{{current[0]}} {{current[1]}}\\n', encoding='ascii')
                return current

            chardevs = [
                sys.argv[index + 1]
                for index, value in enumerate(sys.argv[:-1])
                if value == '-chardev'
            ]
            console_spec = next(value for value in chardevs if 'id=console0' in value)
            ui_spec = next(value for value in chardevs if 'id=bookui0' in value)
            console_fields = dict(
                field.split('=', 1) for field in console_spec.split(',') if '=' in field
            )
            ui_fields = dict(
                field.split('=', 1) for field in ui_spec.split(',') if '=' in field
            )
            run_root = Path(ui_fields['path']).parent
            reader_root = run_root / 'reader-ui'
            reader_root.mkdir(mode=0o700)
            for name, content in (
                ('fixture-book.txt', 'fake book\\n'),
                ('qemu.stdout', 'fake captured qemu stdout\\n'),
                ('qemu.stderr', ''),
                ('reader.log', 'fake bounded native reader log\\n'),
            ):
                target = reader_root / name
                target.write_text(content, encoding='utf-8')
                target.chmod(0o600)

            qemu_identity = write_identity(QEMU_RECORD, os.getpid())
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(ui_fields['path'])
            listener.listen(1)
            Path(console_fields['logfile']).write_text(CONSOLE, encoding='utf-8')

            def require_tree_while_alive():
                if not Path(ui_fields['path']).exists() or not reader_root.is_dir():
                    PREMATURE_REMOVAL.write_text(
                        f'pid={{os.getpid()}} observed private tree removal\\n',
                        encoding='ascii',
                    )

            reader_pid = os.fork()
            if reader_pid == 0:
                write_identity(READER_RECORD, os.getpid())
                if MODE == 'hang':
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    while True:
                        require_tree_while_alive()
                        time.sleep(0.01)
                time.sleep(0.1)
                os._exit(0)

            deadline = time.monotonic() + 2
            while not READER_RECORD.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not READER_RECORD.exists():
                raise SystemExit('fake reader identity was not recorded')
            reader_identity = tuple(
                int(value) for value in READER_RECORD.read_text(encoding='ascii').split()
            )
            for name, value in (('qemu.pid', qemu_identity), ('reader.pid', reader_identity)):
                target = reader_root / name
                target.write_text(json.dumps({{'pid': value[0], 'start-time': value[1]}}) + '\\n')
                target.chmod(0o600)
            socket_info = os.lstat(ui_fields['path'])
            TREE_RECORD.write_text(
                json.dumps({{
                    'socket-is-socket': stat.S_ISSOCK(socket_info.st_mode),
                    'socket-device': socket_info.st_dev,
                    'socket-inode': socket_info.st_ino,
                    'reader-ui-files': sorted(path.name for path in reader_root.iterdir()),
                }}) + '\\n',
                encoding='utf-8',
            )

            if MODE == 'replace':
                owned = run_root.with_name(run_root.name + '.owned')
                os.rename(run_root, owned)
                run_root.mkdir(mode=0o700)
                (run_root / 'foreign-sentinel').write_text('preserve\\n', encoding='ascii')
                (run_root / 'console.log').write_text(CONSOLE, encoding='utf-8')
                (run_root / 'qemu.stdout').write_text(
                    COORDINATOR_SUCCESS, encoding='ascii'
                )
                (run_root / 'qemu.stderr').write_text('', encoding='ascii')

            if MODE == 'hang':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True:
                    require_tree_while_alive()
                    time.sleep(0.01)

            os.waitpid(reader_pid, 0)
            listener.close()  # Deliberately leave the actual socket node behind.
            if MODE == 'failure':
                raise SystemExit(7)
            """
        )
        self._write_executable(qemu, body)
        return qemu

    def command(self, *, timeout: str = "10") -> list[str]:
        return [
            "guile",
            "--no-auto-compile",
            "-L",
            str(HERE),
            str(TEST_RUNNER),
            str(self.roster),
            "--coordinator",
            str(self.coordinator),
            "--koreader-package",
            str(self.koreader),
            "--guile",
            shutil.which("guile") or "guile",
            "--boot-bundle",
            str(self.outer.bundle),
            "--baseline",
            str(self.outer.baseline),
            "--kernel-sha256",
            self.outer.kernel_sha256,
            "--initrd-sha256",
            self.outer.initrd_sha256,
            "--config-sha256",
            self.outer.config_sha256,
            "--baseline-sha256",
            self.outer.baseline_sha256,
            "--dedicated-baseline",
            "--qemu",
            str(self.qemu),
            "--qemu-img",
            str(self.outer.qemu_img),
            "--cp",
            shutil.which("cp") or "/bin/cp",
            "--sha256sum",
            shutil.which("sha256sum") or "/bin/sha256sum",
            "--run-base",
            str(self.outer.run_base),
            "--timeout-seconds",
            timeout,
            "--term-grace-seconds",
            "0.2",
        ]

    def invoke(self, *, timeout: str = "10") -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["GUILE_AUTO_COMPILE"] = "0"
        return subprocess.run(
            self.command(timeout=timeout),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(15, int(float(timeout)) + 10),
            check=False,
        )

    def invoke_production_with_fake_package(self) -> subprocess.CompletedProcess[str]:
        command = self.command()
        command[4] = str(PRODUCTION_RUNNER)
        del command[5]
        environment = dict(os.environ)
        environment["GUILE_AUTO_COMPILE"] = "0"
        return subprocess.run(
            command,
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )

    def wait_for_records(self) -> dict[str, tuple[int, int]]:
        paths = {
            name: self.tracker / f"{name}.identity"
            for name in ("coordinator", "qemu", "reader")
        }
        tree_record = self.tracker / "private-tree.json"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if tree_record.exists() and all(path.exists() for path in paths.values()):
                return {name: read_identity(path) for name, path in paths.items()}
            time.sleep(0.02)
        self.fail(f"fake child/tree evidence did not appear: {paths}, {tree_record}")

    def assert_recorded_processes_gone(self) -> None:
        for path in self.tracker.glob("*.identity"):
            identity = read_identity(path)
            self.assertFalse(
                outer_test.identity_exists(identity),
                f"recorded identity survived cleanup: {path.name}: {identity}",
            )

    def assert_actual_private_tree_was_created(self) -> None:
        evidence = json.loads(
            (self.tracker / "private-tree.json").read_text(encoding="utf-8")
        )
        self.assertIs(evidence["socket-is-socket"], True)
        self.assertGreater(evidence["socket-device"], 0)
        self.assertGreater(evidence["socket-inode"], 0)
        self.assertEqual(
            evidence["reader-ui-files"],
            [
                "fixture-book.txt",
                "qemu.pid",
                "qemu.stderr",
                "qemu.stdout",
                "reader.log",
                "reader.pid",
            ],
        )

    def assert_no_writer_observed_premature_removal(self) -> None:
        self.assertFalse((self.tracker / "premature-removal").exists())

    def test_actual_socket_tree_is_removed_after_joined_success(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, JOINED_SUCCESS)
        self.assertEqual(result.stderr, "")
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        self.assert_recorded_processes_gone()
        self.outer.assert_no_run_residue()

    def test_child_failure_removes_actual_socket_tree_and_emits_no_pass(self) -> None:
        self.qemu = self._make_fake_qemu("failure", VALID_READER_CONSOLE)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("QEMU exited with status 1", result.stderr)
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        self.assert_recorded_processes_gone()
        self.outer.assert_no_run_residue()

    def test_guest_failure_cannot_be_masked_by_coordinator_success(self) -> None:
        invalid = VALID_READER_CONSOLE.replace(
            "BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS\n", ""
        )
        self.qemu = self._make_fake_qemu("guest-failure", invalid)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("joined reader/QEMU assertions failed", result.stderr)
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        self.assert_recorded_processes_gone()
        self.outer.assert_no_run_residue()

    def test_coordinator_source_drift_fails_before_children(self) -> None:
        self.coordinator.write_text(
            self.coordinator.read_text(encoding="utf-8") + "\n; drift\n",
            encoding="utf-8",
        )
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("reader coordinator source identity mismatch", result.stderr)
        self.assertEqual(list(self.tracker.glob("*.identity")), [])
        self.outer.assert_no_run_residue()

    def test_production_entry_rejects_noncanonical_koreader_output(self) -> None:
        result = self.invoke_production_with_fake_package()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("exact pinned v2026.03 output", result.stderr)
        self.assertEqual(list(self.tracker.glob("*.identity")), [])
        self.outer.assert_no_run_residue()

    def test_timeout_reaps_term_resistant_group_and_removes_socket_tree(self) -> None:
        self.qemu = self._make_fake_qemu("hang", VALID_READER_CONSOLE)
        result = self.invoke(timeout="0.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("outer timeout", result.stderr)
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        self.assert_recorded_processes_gone()
        self.outer.assert_no_run_residue()

    def test_term_reaps_term_resistant_group_and_removes_socket_tree(self) -> None:
        self.qemu = self._make_fake_qemu("hang", VALID_READER_CONSOLE)
        process = subprocess.Popen(
            self.command(timeout="30"),
            cwd=REPO,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        identities = self.wait_for_records()
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stdout + stderr)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", stdout)
        self.assertIn("owned QEMU group cleaned", stderr)
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        for identity in identities.values():
            self.assertFalse(outer_test.identity_exists(identity))
        self.outer.assert_no_run_residue()

    def test_owner_sigkill_guardians_reap_exact_shared_group_and_root(self) -> None:
        self.qemu = self._make_fake_qemu("hang", VALID_READER_CONSOLE)
        previous_subreaper = outer_test.subreaper_state()
        process: subprocess.Popen[str] | None = None
        identities: dict[str, tuple[int, int]] = {}
        outer_test.set_subreaper(True)
        try:
            process = subprocess.Popen(
                self.command(timeout="30"),
                cwd=REPO,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=outer_test.ignore_sigchld,
            )
            identities.update(self.wait_for_records())
            coordinator_pid = identities["coordinator"][0]
            qemu_pid = identities["qemu"][0]
            reader_pid = identities["reader"][0]
            process_group = os.getpgid(coordinator_pid)
            self.assertEqual(process_group, coordinator_pid)
            self.assertEqual(os.getpgid(qemu_pid), process_group)
            self.assertEqual(os.getpgid(reader_pid), process_group)

            process_guardian_pid = int(
                next(
                    line.split()[1]
                    for line in Path(f"/proc/{coordinator_pid}/status")
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
            self.assertEqual(len(owner_children), 2)
            root_guardian_pid = next(
                pid for pid in owner_children if pid != process_guardian_pid
            )
            identities["process-guardian"] = outer_test.process_identity(
                process_guardian_pid
            )
            identities["root-guardian"] = outer_test.process_identity(root_guardian_pid)
            identities["owner"] = outer_test.process_identity(process.pid)

            outer_test.exact_kill(identities["owner"], signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, -signal.SIGKILL, stdout + stderr)
            self.assert_actual_private_tree_was_created()
            self.assert_no_writer_observed_premature_removal()

            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                outer_test.reap_exact_nonblocking(identities["process-guardian"])
                outer_test.reap_exact_nonblocking(identities["root-guardian"])
                if (
                    all(
                        not outer_test.identity_exists(identity)
                        for identity in identities.values()
                    )
                    and not list(self.outer.run_base.iterdir())
                ):
                    break
                time.sleep(0.02)
            for label, identity in identities.items():
                self.assertFalse(
                    outer_test.identity_exists(identity),
                    f"{label} survived owner loss: {identity}",
                )
            self.outer.assert_no_run_residue()
        finally:
            for identity in identities.values():
                try:
                    outer_test.exact_kill(identity, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            outer_test.set_subreaper(previous_subreaper)

    def test_replaced_root_is_preserved_and_cannot_report_success(self) -> None:
        self.qemu = self._make_fake_qemu("replace", VALID_READER_CONSOLE)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("refusing to clean replaced run directory", result.stderr)
        self.assertIn("foreign root preserved", result.stderr)
        roots = list(self.outer.run_base.iterdir())
        self.assertEqual(len(roots), 2, roots)
        foreign = next(path for path in roots if (path / "foreign-sentinel").is_file())
        owned = next(path for path in roots if path.name.endswith(".owned"))
        self.assertEqual((foreign / "foreign-sentinel").read_text(), "preserve\n")
        self.assertTrue(stat.S_ISSOCK((owned / "book-ui.sock").lstat().st_mode))
        self.assert_actual_private_tree_was_created()
        self.assert_no_writer_observed_premature_removal()
        self.assert_recorded_processes_gone()
        # Test-owned cleanup only, after proving neither guardian traversed the
        # replacement. Production code deliberately has no such fallback.
        shutil.rmtree(foreign)
        shutil.rmtree(owned)
        self.outer.assert_no_run_residue()


if __name__ == "__main__":
    unittest.main(verbosity=2)
