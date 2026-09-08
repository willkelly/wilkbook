#!/usr/bin/env python3
"""Focused joined host test using the exact accepted native coordinator.

The outer and coordinator are production sources.  QEMU alone is a private
Unix-socket fixture; KOReader is the exact pinned package output.  No QEMU,
guest code, runsc, image, or ARM binary is executed.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap
import unittest


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
NATIVE = REPO / "pinenote/tools/book-interaction"
INVOKER = HERE / "run-disposable-reader-qemu.scm"
KOREADER = Path(
    "/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03"
)
COORDINATOR_RELATIVES = (
    "qemu-coordinator.scm",
    "fixture/bookinteractionprobe.koplugin/_meta.lua",
    "fixture/bookinteractionprobe.koplugin/main.lua",
    "fixture/bookinteractionprobe.koplugin/private_channel.lua",
    "fixture/bookinteractionprobe.koplugin/ui_audit.lua",
)
ACCEPTED_HASHES = {
    "qemu-coordinator.scm": (
        "ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde"
    ),
    "fixture/bookinteractionprobe.koplugin/_meta.lua": (
        "89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964"
    ),
    "fixture/bookinteractionprobe.koplugin/main.lua": (
        "8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125"
    ),
    "fixture/bookinteractionprobe.koplugin/private_channel.lua": (
        "4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832"
    ),
    "fixture/bookinteractionprobe.koplugin/ui_audit.lua": (
        "cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a"
    ),
}

sys.path.insert(0, str(HERE))
import test_disposable_qemu as outer_test  # noqa: E402
import test_disposable_reader_qemu as reader_test  # noqa: E402


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ActualCoordinatorJoinedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.outer = outer_test.DisposableQemuFixture()
        self.outer.setUp()
        self.tracker = self.outer.top / "actual-coordinator-evidence"
        self.tracker.mkdir(mode=0o700)
        self.native = self.outer.top / "accepted-native-copy"
        self._copy_accepted_native_sources()
        self._assert_normal_production_roster()

    def tearDown(self) -> None:
        self.outer.tearDown()

    def _copy_accepted_native_sources(self) -> None:
        copied = set(COORDINATOR_RELATIVES) | {
            "private-control.scm",
            "test-qemu-mode-guest.scm",
        }
        for relative in sorted(copied):
            source = NATIVE / relative
            destination = self.native / relative
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(source, destination)
            destination.chmod(0o400)
        for relative, expected in ACCEPTED_HASHES.items():
            self.assertEqual(sha256(self.native / relative), expected)
        self.assertEqual(
            sha256(self.native / "private-control.scm"),
            "1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d",
        )
        self.assertEqual(
            sha256(self.native / "test-qemu-mode-guest.scm"),
            "5e2918e2ce38f3d32058230f59f19364dbda71f2da77ca52d4008c242bf3ce74",
        )

    def _assert_normal_production_roster(self) -> None:
        entries = " ".join(
            f"({json.dumps(relative)} . {json.dumps(ACCEPTED_HASHES[relative])})"
            for relative in COORDINATOR_RELATIVES
        )
        expression = (
            "(use-modules (disposable-reader-qemu)) "
            "(define observed (module-ref "
            "(resolve-module '(disposable-reader-qemu)) "
            "'coordinator-source-sha256)) "
            f"(unless (equal? observed '({entries})) (exit 1)) "
            "(display \"PRODUCTION-COORDINATOR-ROSTER=PASS\\n\")"
        )
        environment = dict(os.environ)
        environment["GUILE_AUTO_COMPILE"] = "0"
        result = subprocess.run(
            ["guile", "--no-auto-compile", "-L", str(HERE), "-c", expression],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "PRODUCTION-COORDINATOR-ROSTER=PASS\n")

    def _make_mutated_coordinator(self) -> Path:
        root = self.outer.top / "mutated-native-copy"
        shutil.copytree(self.native, root)
        coordinator = root / "qemu-coordinator.scm"
        coordinator.chmod(0o600)
        coordinator.write_bytes(coordinator.read_bytes() + b"\n; mutation\n")
        coordinator.chmod(0o400)
        return coordinator

    def _make_unexpected_qemu(self) -> tuple[Path, Path]:
        sentinel = self.tracker / "unexpected-qemu-launch"
        executable = self.outer.top / "qemu-must-not-run"
        executable.write_text(
            f"#!{sys.executable}\n"
            "from pathlib import Path\n"
            f"Path({str(sentinel)!r}).write_text('launched\\n')\n"
            "raise SystemExit(91)\n",
            encoding="utf-8",
        )
        executable.chmod(0o700)
        return executable, sentinel

    def _make_fake_qemu(self, leave_inert_socket: bool) -> Path:
        path = self.outer.top / (
            "joined-qemu-leave-socket" if leave_inert_socket else "joined-qemu"
        )
        evidence = self.tracker / (
            "failure.json" if leave_inert_socket else "success.json"
        )
        body = textwrap.dedent(
            f"""\
            import json
            import os
            from pathlib import Path
            import socket
            import stat
            import sys
            import time

            EVIDENCE = Path({str(evidence)!r})
            GUEST = {str(self.native / 'test-qemu-mode-guest.scm')!r}
            LOAD_PATH = {str(self.native)!r}
            GUILE = {shutil.which('guile')!r}
            CONSOLE = {reader_test.VALID_READER_CONSOLE!r}
            LEAVE_INERT = {leave_inert_socket!r}

            wrapper_error = os.open(
                str(EVIDENCE.with_suffix('.wrapper.stderr')),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.dup2(wrapper_error, 2)
            os.close(wrapper_error)

            def identity(pid):
                text = Path(f'/proc/{{pid}}/stat').read_text(encoding='ascii')
                fields = text[text.rfind(')') + 2:].split()
                return {{'pid': pid, 'start-time': int(fields[19]),
                         'pgid': os.getpgid(pid)}}

            def option_spec(identifier):
                values = [
                    sys.argv[index + 1]
                    for index, item in enumerate(sys.argv[:-1])
                    if item == '-chardev'
                    and f'id={{identifier}}' in sys.argv[index + 1]
                ]
                if len(values) != 1:
                    raise SystemExit(f'expected one {{identifier}} chardev')
                return dict(
                    field.split('=', 1)
                    for field in values[0].split(',') if '=' in field
                )

            console = option_spec('console0')
            ui = option_spec('bookui0')
            socket_path = Path(ui['path'])
            run_root = socket_path.parent
            Path(console['logfile']).write_text(CONSOLE, encoding='utf-8')

            qemu_identity = identity(os.getpid())
            coordinator_identity = identity(os.getppid())
            child = os.fork()
            if child == 0:
                child_error = os.open(
                    str(EVIDENCE.with_suffix('.qemu.stderr')),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                )
                os.dup2(child_error, 2)
                os.close(child_error)
                os.execv(
                    GUILE,
                    [GUILE, '--no-auto-compile', '-L', LOAD_PATH,
                     GUEST, 'positive', *sys.argv[1:]],
                )

            child_status = None
            observation = None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                waited, status_value = os.waitpid(child, os.WNOHANG)
                if waited == child:
                    child_status = status_value
                qemu_record = run_root / 'reader-ui/qemu.pid'
                reader_record = run_root / 'reader-ui/reader.pid'
                if socket_path.exists() and qemu_record.exists() and reader_record.exists():
                    qemu_pid, qemu_start = map(
                        int, qemu_record.read_text(encoding='ascii').split()
                    )
                    reader_pid, reader_start = map(
                        int, reader_record.read_text(encoding='ascii').split()
                    )
                    socket_info = socket_path.lstat()
                    observation = {{
                        'coordinator': coordinator_identity,
                        'qemu': qemu_identity,
                        'qemu-record': {{'pid': qemu_pid, 'start-time': qemu_start}},
                        'reader': identity(reader_pid),
                        'reader-record': {{'pid': reader_pid,
                                          'start-time': reader_start}},
                        'socket-is-socket': stat.S_ISSOCK(socket_info.st_mode),
                        'socket-device': socket_info.st_dev,
                        'socket-inode': socket_info.st_ino,
                    }}
                if child_status is not None:
                    break
                time.sleep(0.005)
            if child_status is None:
                _, child_status = os.waitpid(child, 0)
            if observation is None:
                raise SystemExit('did not observe exact joined process/socket tree')

            code = os.waitstatus_to_exitcode(child_status)
            if code != 0:
                raise SystemExit(code)
            if LEAVE_INERT:
                deadline = time.monotonic() + 2
                while socket_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                if socket_path.exists():
                    raise SystemExit('fake guest did not retire its listener')
                inert = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                inert.bind(str(socket_path))
                inert_info = socket_path.lstat()
                observation['left-inert-socket'] = {{
                    'is-socket': stat.S_ISSOCK(inert_info.st_mode),
                    'device': inert_info.st_dev,
                    'inode': inert_info.st_ino,
                }}
                inert.close()
            EVIDENCE.write_text(json.dumps(observation, sort_keys=True) + '\\n')
            raise SystemExit(19 if LEAVE_INERT else 0)
            """
        )
        path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
        path.chmod(0o700)
        return path

    def _command(self, fake_qemu: Path, coordinator: Path | None = None) -> list[str]:
        return [
            "guile",
            "--no-auto-compile",
            "-L",
            str(HERE),
            str(INVOKER),
            "--coordinator",
            str(coordinator or self.native / "qemu-coordinator.scm"),
            "--koreader-package",
            str(KOREADER),
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
            str(fake_qemu),
            "--qemu-img",
            str(self.outer.qemu_img),
            "--cp",
            shutil.which("cp") or "/bin/cp",
            "--sha256sum",
            shutil.which("sha256sum") or "/bin/sha256sum",
            "--run-base",
            str(self.outer.run_base),
            "--timeout-seconds",
            "20",
            "--term-grace-seconds",
            "0.2",
        ]

    def _invoke(
        self, fake_qemu: Path, coordinator: Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["GUILE_AUTO_COMPILE"] = "0"
        return subprocess.run(
            self._command(fake_qemu, coordinator),
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )

    def _assert_tree_evidence(self, label: str) -> dict[str, object]:
        evidence = json.loads((self.tracker / f"{label}.json").read_text())
        self.assertIs(evidence["socket-is-socket"], True)
        self.assertGreater(evidence["socket-device"], 0)
        self.assertGreater(evidence["socket-inode"], 0)
        identities = [evidence[name] for name in ("coordinator", "qemu", "reader")]
        self.assertEqual(len({item["pgid"] for item in identities}), 1)
        self.assertEqual(evidence["qemu-record"], {
            key: evidence["qemu"][key] for key in ("pid", "start-time")
        })
        self.assertEqual(evidence["reader-record"], {
            key: evidence["reader"][key] for key in ("pid", "start-time")
        })
        for item in identities:
            self.assertFalse(
                outer_test.identity_exists((item["pid"], item["start-time"])),
                f"joined process identity survived: {{item}}",
            )
        self.outer.assert_no_run_residue()
        return evidence

    def test_actual_coordinator_connection_and_joined_success(self) -> None:
        result = self._invoke(self._make_fake_qemu(False))
        child_error = self.tracker / "success.qemu.stderr"
        wrapper_error = self.tracker / "success.wrapper.stderr"
        diagnostic = "".join(
            path.read_text()
            for path in (wrapper_error, child_error)
            if path.exists()
        )
        self.assertEqual(
            result.returncode, 0, result.stdout + result.stderr + diagnostic
        )
        self.assertEqual(result.stdout, reader_test.JOINED_SUCCESS)
        self.assertEqual(result.stderr, "")
        self._assert_tree_evidence("success")

    def test_mutated_coordinator_is_rejected_before_qemu_launch(self) -> None:
        fake_qemu, sentinel = self._make_unexpected_qemu()
        result = self._invoke(fake_qemu, self._make_mutated_coordinator())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OUTER-READER-QEMU-STATUS=0", result.stdout)
        self.assertIn("reader coordinator source identity mismatch", result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(list(self.tracker.iterdir()), [])
        self.outer.assert_no_run_residue()


if __name__ == "__main__":
    unittest.main(verbosity=2)
