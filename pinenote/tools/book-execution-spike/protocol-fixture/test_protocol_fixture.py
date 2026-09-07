#!/usr/bin/env python3
"""Host-only tests for the proposed runsc Book Protocol FD seam."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest


TOOL_DIR = Path(__file__).resolve().parent
REPO = TOOL_DIR.parents[3]
PROTOCOL_DIR = REPO / "pinenote/tools/book-protocol"
SESSION_DIR = REPO / "pinenote/tools/book-session"

FROZEN_INPUTS = {
    SESSION_DIR / "book-session.scm": (
        "f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668"
    ),
    PROTOCOL_DIR / "book-protocol.scm": (
        "91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44"
    ),
    PROTOCOL_DIR / "book-protocol/blocking-io.scm": (
        "543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd"
    ),
    PROTOCOL_DIR / "book_protocol.py": (
        "4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735"
    ),
}

RUNTIME_FLAGS = [
    "--platform=systrap",
    "--network=none",
    "--sidecar-usage-policy=strict",
    "--sidecar-release-enforcement-policy=always",
    "--ignore-cgroups=false",
    "--host-uds=none",
    "--host-fifo=none",
    "--character-device-policy=emulated-only",
    "--allow-suid=false",
    "--allow-flag-override=false",
    "--allow-rootfs-tar-annotation=false",
    "--overlay2=none",
    "--rootless=false",
    "--file-access=exclusive",
    "--file-access-mounts=exclusive",
    "--net-raw=false",
    "--allow-packet-socket-write=false",
    "--directfs=false",
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def process_start_time(pid: int) -> str | None:
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return None
    close = text.rfind(")")
    if close < 0:
        return None
    fields = text[close + 2 :].split()
    return fields[19] if len(fields) >= 20 else None


def make_fake_runsc(path: Path) -> None:
    source = f"""#!{sys.executable}
import fcntl
import json
import os
from pathlib import Path
import stat
import sys

args = sys.argv[1:]
bundle_fields = [value for value in args if value.startswith("--bundle=")]
if len(bundle_fields) != 1:
    raise SystemExit("expected exactly one bundle argument")
bundle = Path(bundle_fields[0].split("=", 1)[1])
config = json.loads((bundle / "fake-config.json").read_text(encoding="utf-8"))
if args != config["expected_args"]:
    raise SystemExit("runsc argument vector differed from fixed policy")

open_fds = []
for name in os.listdir("/proc/self/fd"):
    try:
        fd = int(name)
        fcntl.fcntl(fd, fcntl.F_GETFD)
    except (ValueError, OSError):
        continue
    open_fds.append(fd)
if sorted(open_fds) != [0, 1, 2, 3]:
    raise SystemExit(f"unexpected inherited descriptors: {{sorted(open_fds)}}")
if not stat.S_ISSOCK(os.fstat(3).st_mode):
    raise SystemExit("donated FD 3 is not a socket")
if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
    raise SystemExit("donated FD 3 remained close-on-exec")

process_stat = Path(f"/proc/{{os.getpid()}}/stat").read_text(encoding="ascii")
process_fields = process_stat[process_stat.rfind(")") + 2:].split()

(bundle / "fake-observation.json").write_text(
    json.dumps({{"args": args, "open_fds": sorted(open_fds),
                "fd3_cloexec": False, "pid": os.getpid(),
                "start_time": process_fields[19]}}, sort_keys=True) + "\\n",
    encoding="utf-8",
)
environment = config["environment"]
os.execve(config["book_argv"][0], config["book_argv"], environment)
"""
    path.write_text(source, encoding="utf-8")
    path.chmod(0o500)


def book_environment(run_root: Path) -> dict[str, str]:
    environment = {
        "BOOK_SESSION_FD": "3",
        "GUILE_AUTO_COMPILE": "0",
        "HOME": str(run_root / "book-home"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PATH": "/run/current-system/profile/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "TMPDIR": str(run_root / "book-tmp"),
    }
    for name in ("GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH"):
        value = os.environ.get(name)
        if value is not None:
            environment[name] = value
    return environment


class ProtocolFixtureTests(unittest.TestCase):
    maxDiff = None

    def test_frozen_protocol_and_session_inputs(self) -> None:
        for path, expected in FROZEN_INPUTS.items():
            self.assertEqual(sha256(path), expected, path)

    def test_fixture_keeps_policy_and_transport_narrow(self) -> None:
        host = (TOOL_DIR / "protocol-host.scm").read_text(encoding="utf-8")
        guile_book = (TOOL_DIR / "fixture-book.scm").read_text(encoding="utf-8")
        python_book = (TOOL_DIR / "fixture_book.py").read_text(encoding="utf-8")
        self.assertIn('"--pass-fd=3:3"', host)
        self.assertIn('"--directfs=false"', host)
        self.assertIn('"--network=none"', host)
        self.assertNotIn('"--directfs=true"', host)
        self.assertNotIn("expire-request!", host)
        self.assertNotIn("call-with-new-thread", host)
        self.assertNotIn("make-thread", host)
        self.assertNotIn("RLIMIT_FSIZE", host)
        self.assertIn('(getenv "BOOK_SESSION_FD") "3"', guile_book)
        self.assertIn('os.environ.get("BOOK_SESSION_FD") != "3"', python_book)
        self.assertNotIn("print(", python_book)

    def test_two_native_books_through_strict_fake_runsc_boundary(self) -> None:
        guile = shutil.which("guile")
        if guile is None:
            self.fail("Guile is required; use the pinned Makefile check target")

        with tempfile.TemporaryDirectory(
            prefix="bookexec-protocol-fixture.", dir="/tmp/opencode"
        ) as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            run_root = root / "run"
            run_root.mkdir(mode=0o700)
            (root / "book-home").mkdir(mode=0o700)
            (root / "book-tmp").mkdir(mode=0o700)
            fake_runsc = root / "runsc"
            make_fake_runsc(fake_runsc)

            bundles: dict[str, Path] = {}
            book_env = book_environment(root)
            for language in ("guile", "python"):
                bundle = root / f"bundle-{language}"
                bundle.mkdir(mode=0o700)
                bundles[language] = bundle
                state_root = run_root / f"runsc-state-{language}"
                container_id = f"wilkbook-{language}-protocol-fixture"
                expected_args = [
                    f"--root={state_root}",
                    *RUNTIME_FLAGS,
                    "run",
                    "--pass-fd=3:3",
                    f"--bundle={bundle}",
                    container_id,
                ]
                if language == "guile":
                    book_argv = [
                        guile,
                        "--no-auto-compile",
                        "-L",
                        str(PROTOCOL_DIR),
                        str(TOOL_DIR / "fixture-book.scm"),
                    ]
                else:
                    book_argv = [sys.executable, str(TOOL_DIR / "fixture_book.py")]
                environment = dict(book_env)
                if language == "python":
                    environment["PYTHONPATH"] = str(PROTOCOL_DIR)
                config = {
                    "book_argv": book_argv,
                    "environment": environment,
                    "expected_args": expected_args,
                }
                (bundle / "fake-config.json").write_text(
                    json.dumps(config, ensure_ascii=False), encoding="utf-8"
                )

            environment = os.environ.copy()
            environment["GUILE_AUTO_COMPILE"] = "0"
            result = subprocess.run(
                [
                    guile,
                    "--no-auto-compile",
                    "-L",
                    str(PROTOCOL_DIR),
                    "-L",
                    str(SESSION_DIR),
                    str(TOOL_DIR / "protocol-host.scm"),
                    str(run_root),
                    str(fake_runsc),
                    str(bundles["guile"]),
                    str(bundles["python"]),
                ],
                cwd=REPO,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=25,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout,
                "BOOKEXEC-PROTOCOL-FIXTURE=PASS peers=2 transport=fd3\n",
            )
            self.assertEqual(result.stderr, "")

            for language, bundle in bundles.items():
                observation = json.loads(
                    (bundle / "fake-observation.json").read_text(encoding="utf-8")
                )
                self.assertEqual(observation["open_fds"], [0, 1, 2, 3])
                self.assertFalse(observation["fd3_cloexec"])
                self.assertNotEqual(
                    process_start_time(observation["pid"]),
                    observation["start_time"],
                    f"{language} fake-runsc process survived host acceptance",
                )
                self.assertEqual(
                    observation["args"],
                    json.loads(
                        (bundle / "fake-config.json").read_text(encoding="utf-8")
                    )["expected_args"],
                )
                self.assertFalse(
                    (run_root / f"runsc-{language}.pid").exists(),
                    f"{language} process identity record survived cleanup",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
