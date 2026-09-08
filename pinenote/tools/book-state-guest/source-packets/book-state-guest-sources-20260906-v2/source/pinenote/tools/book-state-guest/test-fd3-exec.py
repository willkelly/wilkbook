#!/usr/bin/env python3
"""Native exec tests for the real Guile FD-3 adapter; never invokes runsc."""

from __future__ import annotations

import fcntl
import json
import os
import signal
import socket
import stat
import subprocess
import sys
from pathlib import Path


TOOL = Path(__file__).resolve().parent
ADAPTER = TOOL / "runsc-fd3-exec.scm"
TIMEOUT = 10
CLOSE_HIGH = """
(let loop ((fd 3))
  (when (< fd 64)
    (catch 'system-error
      (lambda () (close-fdes fd))
      (lambda arguments #f))
    (loop (+ fd 1))))
"""


def actual_fds() -> list[int]:
    result = []
    for name in os.listdir("/proc/self/fd"):
        try:
            fd = int(name)
            fcntl.fcntl(fd, fcntl.F_GETFD)
        except (ValueError, OSError):
            continue
        result.append(fd)
    return sorted(result)


def identity(fd: int) -> list[int]:
    info = os.fstat(fd)
    return [stat.S_IFMT(info.st_mode), info.st_dev, info.st_ino, info.st_rdev]


def fd_link(fd: int) -> str:
    return os.readlink(f"/proc/self/fd/{fd}")


def fixture() -> int:
    fd0 = os.fstat(0)
    fd3 = os.fstat(3)
    fd0_socket = stat.S_ISSOCK(fd0.st_mode)
    fd0_eof = False
    if not fd0_socket:
        fd0_eof = os.read(0, 1) == b""
    report = {
        "fds": actual_fds(),
        "fd0": fd_link(0),
        "fd1": fd_link(1),
        "fd2": fd_link(2),
        "fd3": fd_link(3),
        "fd0_identity": identity(0),
        "fd1_identity": identity(1),
        "fd2_identity": identity(2),
        "fd3_identity": identity(3),
        "fd0_socket": fd0_socket,
        "fd1_socket": stat.S_ISSOCK(os.fstat(1).st_mode),
        "fd2_socket": stat.S_ISSOCK(os.fstat(2).st_mode),
        "fd3_socket": stat.S_ISSOCK(fd3.st_mode),
        "fd0_eof": fd0_eof,
        "same_0_3": identity(0) == identity(3),
        "cloexec": [
            bool(fcntl.fcntl(fd, fcntl.F_GETFD) & fcntl.FD_CLOEXEC)
            for fd in range(4)
        ],
    }
    payload = (json.dumps(report, sort_keys=True) + "\n").encode("utf-8")
    while payload:
        written = os.write(3, payload)
        payload = payload[written:]
    incoming = b""
    while not incoming.endswith(b"\n"):
        chunk = os.read(3, 128)
        if not chunk:
            raise RuntimeError("Book Session probe reached EOF")
        incoming += chunk
    if incoming != b"PING\n":
        raise RuntimeError(f"unexpected Book Session probe: {incoming!r}")
    os.write(3, b"PONG\n")
    os.write(1, b"FD3-TEST-STDOUT\n")
    os.write(2, b"FD3-TEST-STDERR\n")
    return 0


def scheme_body(precondition: str) -> str:
    return (
        "(begin "
        + precondition
        + " (runsc-fd3-exec-main (cdr (command-line))))"
    )


def process_identity(pid: int, fd: int) -> list[int] | None:
    try:
        info = os.stat(f"/proc/{pid}/fd/{fd}")
    except FileNotFoundError:
        return None
    return [stat.S_IFMT(info.st_mode), info.st_dev, info.st_ino, info.st_rdev]


def receive_line(peer: socket.socket) -> bytes:
    peer.settimeout(TIMEOUT)
    result = b""
    while not result.endswith(b"\n"):
        chunk = peer.recv(4096)
        if not chunk:
            raise RuntimeError("adapter fixture closed Book Session probe")
        result += chunk
    return result


def run_case(
    label: str,
    precondition: str | None,
    expected_stopped: list[int] | None,
    closed_outputs: tuple[int, ...] = (),
) -> dict[str, object]:
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    if precondition is None:
        command = [
            "guile",
            "--no-auto-compile",
            str(ADAPTER),
            "--directory",
            str(TOOL),
            "--",
            sys.executable,
            "-I",
            "-S",
            str(Path(__file__).resolve()),
            "--fixture",
        ]
    else:
        command = [
            "guile",
            "--no-auto-compile",
            "-l",
            str(ADAPTER),
            "-c",
            scheme_body(precondition),
            "--directory",
            str(TOOL),
            "--",
            sys.executable,
            "-I",
            "-S",
            str(Path(__file__).resolve()),
            "--fixture",
        ]
    environment = {
        "GUILE_AUTO_COMPILE": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.environ["PATH"],
    }
    process = subprocess.Popen(
        command,
        stdin=child,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        close_fds=True,
        env=environment,
    )
    child.close()
    try:
        pid, status = os.waitpid(process.pid, os.WUNTRACED)
        if not (
            pid == process.pid
            and os.WIFSTOPPED(status)
            and os.WSTOPSIG(status) == signal.SIGSTOP
        ):
            raise RuntimeError(f"{label}: adapter did not stop: {status}")
        stopped = sorted(int(name) for name in os.listdir(f"/proc/{pid}/fd"))
        if expected_stopped is not None and stopped != expected_stopped:
            raise RuntimeError(
                f"{label}: stopped descriptor precondition {stopped} != {expected_stopped}"
            )
        stopped_outputs = {fd: process_identity(pid, fd) for fd in (1, 2)}
        os.kill(pid, signal.SIGCONT)
        report = json.loads(receive_line(parent))
        parent.sendall(b"PING\n")
        if receive_line(parent) != b"PONG\n":
            raise RuntimeError(f"{label}: FD 3 did not return PONG")
        stdout, stderr = process.communicate(timeout=TIMEOUT)
        if process.returncode != 0:
            raise RuntimeError(
                f"{label}: exit={process.returncode} stdout={stdout!r} stderr={stderr!r}"
            )
        if report["fds"] != [0, 1, 2, 3]:
            raise RuntimeError(f"{label}: exec roster is {report['fds']!r}")
        if not report["fd3_socket"] or report["fd0_socket"] or report["same_0_3"]:
            raise RuntimeError(f"{label}: Book Session is not FD-3-only: {report!r}")
        if not report["fd0_eof"] or report["cloexec"] != [False] * 4:
            raise RuntimeError(f"{label}: stdin/CLOEXEC normalization failed: {report!r}")
        if report["fd1_socket"] or report["fd2_socket"]:
            raise RuntimeError(f"{label}: socket capability leaked through output stdio")
        for fd in (1, 2):
            if fd in closed_outputs:
                if not str(report[f"fd{fd}"]).endswith("/dev/null"):
                    raise RuntimeError(f"{label}: closed FD {fd} was not normalized")
            elif report[f"fd{fd}_identity"] != stopped_outputs[fd]:
                raise RuntimeError(f"{label}: bounded output FD {fd} was overwritten")
        expected_stdout = b"" if 1 in closed_outputs else b"FD3-TEST-STDOUT\n"
        expected_stderr = b"" if 2 in closed_outputs else b"FD3-TEST-STDERR\n"
        if stdout != expected_stdout or stderr != expected_stderr:
            raise RuntimeError(
                f"{label}: output capture changed: stdout={stdout!r} stderr={stderr!r}"
            )
        print(
            f"PASS: {label}: stopped={stopped} exec={report['fds']} "
            f"fd0={report['fd0']} fd3={report['fd3']}"
        )
        return report
    finally:
        parent.close()
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate(timeout=TIMEOUT)


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--fixture":
        raise SystemExit(fixture())
    if len(sys.argv) != 1:
        raise RuntimeError("test-fd3-exec.py accepts no arguments")

    run_case("production-direct-helper", None, None)
    reviewer = run_case(
        "BSG-1-reviewer-fd3-free-negative",
        CLOSE_HIGH,
        [0, 1, 2],
    )
    if not str(reviewer["fd0"]).endswith("/dev/null"):
        raise RuntimeError("reviewer counterexample did not end with /dev/null on FD 0")
    run_case(
        "fd3-initially-occupied",
        CLOSE_HIGH
        + " (let ((fd (open-fdes \"/dev/null\" O_RDONLY)))"
        + " (unless (= fd 3) (error \"FD 3 occupation precondition failed\" fd)))",
        [0, 1, 2, 3],
    )
    run_case(
        "book-source-already-fd3-stdin-open",
        CLOSE_HIGH
        + " (dup2 0 3)"
        + " (let ((fd (open-fdes \"/dev/null\" O_RDONLY)))"
        + " (dup2 fd 0) (close-fdes fd))",
        [0, 1, 2, 3],
    )
    run_case(
        "book-source-already-fd3-stdin-closed",
        CLOSE_HIGH + " (dup2 0 3) (close-fdes 0)",
        [1, 2, 3],
    )
    run_case(
        "duplicate-book-aliases-closed",
        CLOSE_HIGH + " (dup2 0 3) (dup2 0 4)",
        [0, 1, 2, 3, 4],
    )
    run_case(
        "closed-stdout-normalized-without-stderr-overwrite",
        CLOSE_HIGH + " (close-fdes 1)",
        [0, 2],
        (1,),
    )
    run_case(
        "closed-stderr-normalized-without-stdout-overwrite",
        CLOSE_HIGH + " (close-fdes 2)",
        [0, 1],
        (2,),
    )
    print("PASS: FD 3 is the sole Book Session capability across native exec")


if __name__ == "__main__":
    main()
