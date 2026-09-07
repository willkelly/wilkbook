#!/usr/bin/env python3
"""Boundedly retain fixed reader-QEMU logs without weakening run-root cleanup.

This is an evidence observer, not a protocol or semantic checker.  It starts the
normal launcher supplied after ``--``, opens only the six fixed regular log files
read-only/CLOEXEC, and keeps those descriptors across the launcher's unlink of
its private run root.  It never opens the UI socket or records UI-channel bytes.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import errno
import hashlib
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time
from typing import BinaryIO


RUN_PREFIX = "book-execution-qemu."
POLL_SECONDS = 0.02
MAX_DEADLINE_SECONDS = 660.0
TERMINATION_GRACE_SECONDS = 20.0
MAX_LAUNCHER_STDOUT = 64 * 1024
MAX_LAUNCHER_STDERR = 24 * 1024 * 1024

# Mirrors disposable-qemu.scm's exact completed-console bound.
MAX_CONSOLE = (
    (4 + 12) * (8 * 1024 + 8 * 1024) * 5
    + 12 * 255 * 5
    + 2 * 1024 * 1024
)
MAX_READER_LOG = 128 * 1024
MAX_QEMU_CAPTURE = 4 * 1024 * 1024
MAX_OUTER_CAPTURE = 4 * 1024 * 1024

LOG_SPECS = (
    ("console.log", "root", "console.log", MAX_CONSOLE),
    ("coordinator.stdout", "root", "qemu.stdout", MAX_OUTER_CAPTURE),
    ("coordinator.stderr", "root", "qemu.stderr", MAX_OUTER_CAPTURE),
    ("reader.log", "reader", "reader.log", MAX_READER_LOG),
    ("qemu.stdout", "reader", "qemu.stdout", MAX_QEMU_CAPTURE),
    ("qemu.stderr", "reader", "qemu.stderr", MAX_QEMU_CAPTURE),
)


class HarvestError(RuntimeError):
    pass


@dataclass
class HeldLog:
    label: str
    parent_kind: str
    name: str
    limit: int
    fd: int
    device: int
    inode: int
    opened_size: int


@dataclass
class BoundedStream:
    label: str
    source: BinaryIO
    limit: int
    retained: bytearray
    observed: int = 0
    overflow: bool = False


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def secure_directory(path: Path, label: str) -> tuple[Path, int, os.stat_result]:
    canonical = Path(os.path.realpath(path))
    fd = os.open(canonical, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    info = os.fstat(fd)
    named = os.stat(canonical, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode) or identity(info) != identity(named):
        os.close(fd)
        raise HarvestError(f"{label} is not an identity-stable real directory")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise HarvestError(f"{label} must be caller-owned and private")
    return canonical, fd, info


def require_empty_directory(fd: int, label: str) -> None:
    entries = [entry for entry in os.listdir(fd) if entry not in (".", "..")]
    if entries:
        raise HarvestError(f"{label} must begin empty")


def option_values(command: list[str], name: str) -> list[str]:
    values: list[str] = []
    for index, value in enumerate(command):
        if value == name:
            if index + 1 >= len(command):
                raise HarvestError(f"launcher option lacks value: {name}")
            values.append(command[index + 1])
    return values


def validate_command(command: list[str], run_base: Path) -> None:
    if not command:
        raise HarvestError("missing launcher command after --")
    values = option_values(command, "--run-base")
    if len(values) != 1 or Path(os.path.realpath(values[0])) != run_base:
        raise HarvestError("launcher must contain the exact run base once")
    if option_values(command, "--timeout-seconds") != ["600"]:
        raise HarvestError("launcher must retain the exact 600-second QEMU deadline")
    if option_values(command, "--term-grace-seconds") != ["5"]:
        raise HarvestError("launcher must retain the exact five-second TERM/KILL grace")


def make_evidence_directory(path: Path, run_base: Path) -> tuple[Path, int]:
    if path.exists() or path.is_symlink():
        raise HarvestError(f"refusing existing evidence directory: {path}")
    parent, parent_fd, _ = secure_directory(path.parent, "evidence parent")
    try:
        canonical_candidate = parent / path.name
        if os.path.commonpath((str(canonical_candidate), str(run_base))) == str(run_base):
            raise HarvestError("evidence directory must be outside the run base")
        os.mkdir(path.name, 0o700, dir_fd=parent_fd)
        fd = os.open(
            path.name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
        return canonical_candidate, fd
    finally:
        os.close(parent_fd)


def write_evidence(directory_fd: int, name: str, content: bytes) -> None:
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
        0o600,
        dir_fd=directory_fd,
    )
    try:
        offset = 0
        while offset < len(content):
            written = os.write(fd, content[offset:])
            if written <= 0:
                raise HarvestError(f"short evidence write: {name}")
            offset += written
        os.fsync(fd)
        os.fchmod(fd, 0o400)
    finally:
        os.close(fd)


def append_stream(stream: BoundedStream, value: bytes) -> None:
    stream.observed += len(value)
    remaining = max(0, stream.limit - len(stream.retained))
    if remaining:
        stream.retained.extend(value[:remaining])
    if stream.observed > stream.limit:
        stream.overflow = True


def safe_stat(name: str, parent_fd: int) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def open_private_directory(name: str, parent_fd: int, label: str) -> tuple[int, os.stat_result] | None:
    info = safe_stat(name, parent_fd)
    if info is None:
        return None
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise HarvestError(f"{label} is not a caller-owned private directory")
    fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent_fd,
    )
    opened = os.fstat(fd)
    if identity(opened) != identity(info):
        os.close(fd)
        raise HarvestError(f"{label} changed while opening")
    return fd, opened


def open_log(
    label: str, parent_kind: str, name: str, limit: int, parent_fd: int
) -> HeldLog | None:
    info = safe_stat(name, parent_fd)
    if info is None:
        return None
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or info.st_mode & 0o077
    ):
        raise HarvestError(f"{label} is not a private single-link regular file")
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    opened = os.fstat(fd)
    if identity(opened) != identity(info):
        os.close(fd)
        raise HarvestError(f"{label} changed while opening")
    if opened.st_size > limit:
        os.close(fd)
        raise HarvestError(f"{label} exceeds its {limit}-byte harvest bound")
    return HeldLog(
        label, parent_kind, name, limit, fd, opened.st_dev, opened.st_ino, opened.st_size
    )


def read_held_log(log: HeldLog) -> bytes:
    info = os.fstat(log.fd)
    if info.st_size > log.limit:
        raise HarvestError(f"{log.label} exceeds its {log.limit}-byte harvest bound")
    os.lseek(log.fd, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    observed = 0
    while True:
        value = os.read(log.fd, min(64 * 1024, log.limit + 1 - observed))
        if not value:
            break
        chunks.append(value)
        observed += len(value)
        if observed > log.limit:
            raise HarvestError(f"{log.label} exceeds its {log.limit}-byte harvest bound")
    return b"".join(chunks)


def sanitized_error(error: str) -> str:
    return error.replace("\n", " ").replace("\r", " ")


def run(arguments: argparse.Namespace) -> int:
    run_base, base_fd, base_info = secure_directory(arguments.run_base, "run base")
    evidence_dir: Path | None = None
    evidence_fd: int | None = None
    root_fd: int | None = None
    reader_fd: int | None = None
    root_info: os.stat_result | None = None
    reader_info: os.stat_result | None = None
    root_name: str | None = None
    held: dict[str, HeldLog] = {}
    errors: list[str] = []
    process: subprocess.Popen[bytes] | None = None
    received_signal: int | None = None

    def note_signal(number: int, _frame: object) -> None:
        nonlocal received_signal
        if received_signal is None:
            received_signal = number

    old_handlers = {
        number: signal.signal(number, note_signal)
        for number in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
    }

    stdout_stream: BoundedStream | None = None
    stderr_stream: BoundedStream | None = None
    selector = selectors.DefaultSelector()
    try:
        require_empty_directory(base_fd, "run base")
        validate_command(arguments.command, run_base)
        evidence_dir, evidence_fd = make_evidence_directory(arguments.evidence_dir, run_base)
        process = subprocess.Popen(
            arguments.command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
        )
        assert process.stdout is not None and process.stderr is not None
        stdout_stream = BoundedStream(
            "launcher.stdout", process.stdout, MAX_LAUNCHER_STDOUT, bytearray()
        )
        stderr_stream = BoundedStream(
            "launcher.stderr", process.stderr, MAX_LAUNCHER_STDERR, bytearray()
        )
        for stream in (stdout_stream, stderr_stream):
            os.set_blocking(stream.source.fileno(), False)
            selector.register(stream.source, selectors.EVENT_READ, stream)

        deadline = time.monotonic() + arguments.deadline_seconds
        signal_sent = False
        overflow_termination_at: float | None = None
        while process.poll() is None or selector.get_map():
            now = time.monotonic()
            if received_signal is not None and process.poll() is None and not signal_sent:
                process.send_signal(received_signal)
                signal_sent = True
                overflow_termination_at = now
            if now >= deadline and process.poll() is None and not signal_sent:
                errors.append("harvest wrapper deadline expired")
                process.send_signal(signal.SIGTERM)
                signal_sent = True
                overflow_termination_at = now
            if (
                signal_sent
                and process.poll() is None
                and overflow_termination_at is not None
                and now - overflow_termination_at >= TERMINATION_GRACE_SECONDS
            ):
                process.kill()

            for key, _events in selector.select(POLL_SECONDS):
                stream: BoundedStream = key.data
                try:
                    value = os.read(stream.source.fileno(), 64 * 1024)
                except BlockingIOError:
                    continue
                if value:
                    append_stream(stream, value)
                    if stream.overflow and "launcher output exceeded bound" not in errors:
                        errors.append("launcher output exceeded bound")
                        if process.poll() is None and not signal_sent:
                            process.send_signal(signal.SIGTERM)
                            signal_sent = True
                            overflow_termination_at = now
                else:
                    selector.unregister(stream.source)
                    stream.source.close()

            current_base = os.stat(run_base, follow_symlinks=False)
            if identity(current_base) != identity(base_info):
                raise HarvestError("run base identity changed during harvest")

            names = [name for name in os.listdir(base_fd) if name.startswith(RUN_PREFIX)]
            if root_name is None:
                if len(names) > 1:
                    raise HarvestError("more than one reader-QEMU run root appeared")
                if names:
                    root_name = names[0]
                    opened = open_private_directory(root_name, base_fd, "run root")
                    if opened is None:
                        raise HarvestError("run root disappeared while opening")
                    root_fd, root_info = opened
            elif root_info is not None:
                current_root = safe_stat(root_name, base_fd)
                if current_root is not None and identity(current_root) != identity(root_info):
                    raise HarvestError("run root pathname was replaced")

            if root_fd is not None and reader_fd is None:
                opened_reader = open_private_directory("reader-ui", root_fd, "reader-ui")
                if opened_reader is not None:
                    reader_fd, reader_info = opened_reader
            if root_fd is not None and reader_fd is not None and reader_info is not None:
                current_reader = safe_stat("reader-ui", root_fd)
                if current_reader is not None and identity(current_reader) != identity(reader_info):
                    raise HarvestError("reader-ui pathname was replaced")

            parents = {"root": root_fd, "reader": reader_fd}
            for label, parent_kind, name, limit in LOG_SPECS:
                parent_fd = parents[parent_kind]
                if label not in held and parent_fd is not None:
                    opened_log = open_log(label, parent_kind, name, limit, parent_fd)
                    if opened_log is not None:
                        held[label] = opened_log
                if label in held:
                    log = held[label]
                    current = safe_stat(log.name, parents[log.parent_kind])
                    if current is not None and identity(current) != (log.device, log.inode):
                        raise HarvestError(f"{label} pathname was replaced")
                    if os.fstat(log.fd).st_size > log.limit:
                        raise HarvestError(
                            f"{label} exceeds its {log.limit}-byte harvest bound"
                        )

        child_status = process.wait()
        if process.stdout and not process.stdout.closed:
            process.stdout.close()
        if process.stderr and not process.stderr.closed:
            process.stderr.close()

        retained_logs: dict[str, bytes] = {}
        for label, _parent_kind, _name, _limit in LOG_SPECS:
            log = held.get(label)
            if log is None:
                if child_status == 0:
                    errors.append(f"required log was not opened: {label}")
                continue
            try:
                retained_logs[label] = read_held_log(log)
            except HarvestError as error:
                errors.append(str(error))

        roots_after = [name for name in os.listdir(base_fd) if name.startswith(RUN_PREFIX)]
        if roots_after:
            errors.append("run root remained after launcher completion")
        if stdout_stream and stdout_stream.overflow:
            errors.append("launcher.stdout exceeded its bound")
        if stderr_stream and stderr_stream.overflow:
            errors.append("launcher.stderr exceeded its bound")

        assert evidence_fd is not None
        launcher_stdout = bytes(stdout_stream.retained if stdout_stream else b"")
        launcher_stderr = bytes(stderr_stream.retained if stderr_stream else b"")
        write_evidence(evidence_fd, "launcher.stdout", launcher_stdout)
        write_evidence(evidence_fd, "launcher.stderr", launcher_stderr)
        for label, content in retained_logs.items():
            write_evidence(evidence_fd, label, content)

        complete = child_status == 0 and not errors and len(retained_logs) == len(LOG_SPECS)
        manifest = [
            "schema=1",
            "role=bounded-reader-qemu-log-harvest",
            f"harvest-status={'complete' if complete else 'failed'}",
            f"launcher-status={child_status}",
            f"launcher-stdout-observed={stdout_stream.observed if stdout_stream else 0}",
            f"launcher-stdout-retained={len(launcher_stdout)}",
            f"launcher-stdout-limit={MAX_LAUNCHER_STDOUT}",
            f"launcher-stderr-observed={stderr_stream.observed if stderr_stream else 0}",
            f"launcher-stderr-retained={len(launcher_stderr)}",
            f"launcher-stderr-limit={MAX_LAUNCHER_STDERR}",
            f"run-root-name={root_name or 'none'}",
            f"run-root-removed={'true' if not roots_after else 'false'}",
        ]
        for label, _parent_kind, _name, limit in LOG_SPECS:
            if label in retained_logs:
                log = held[label]
                content = retained_logs[label]
                manifest.append(
                    f"log={label} state=retained bytes={len(content)} limit={limit} "
                    f"source-device={log.device} source-inode={log.inode} "
                    f"sha256={sha256_bytes(content)}"
                )
            else:
                manifest.append(f"log={label} state=missing limit={limit}")
        manifest.extend(f"error={sanitized_error(error)}" for error in errors)
        write_evidence(evidence_fd, "HARVEST.txt", ("\n".join(manifest) + "\n").encode())
        os.fchmod(evidence_fd, 0o500)

        if complete:
            sys.stdout.buffer.write(launcher_stdout)
            sys.stdout.buffer.flush()
            if launcher_stderr:
                sys.stderr.buffer.write(launcher_stderr)
                sys.stderr.buffer.flush()
            return 0
        if launcher_stderr:
            sys.stderr.buffer.write(launcher_stderr)
        for error in errors:
            print(f"HARVEST: FAIL:{error}", file=sys.stderr)
        return child_status if child_status != 0 else 1
    finally:
        selector.close()
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=TERMINATION_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in held.values():
            try:
                os.close(log.fd)
            except OSError:
                pass
        for fd in (reader_fd, root_fd, evidence_fd, base_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        for number, handler in old_handlers.items():
            signal.signal(number, handler)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="bounded evidence wrapper for one disposable reader-QEMU run"
    )
    result.add_argument("--run-base", type=Path, required=True)
    result.add_argument("--evidence-dir", type=Path, required=True)
    result.add_argument(
        "--deadline-seconds", type=float, default=630.0,
        help="wrapper lifetime, greater than the fixed 600-second QEMU deadline",
    )
    result.add_argument("command", nargs=argparse.REMAINDER)
    return result


def main(argv: list[str]) -> int:
    arguments = parser().parse_args(argv)
    if arguments.command and arguments.command[0] == "--":
        arguments.command = arguments.command[1:]
    if not (600.0 < arguments.deadline_seconds <= MAX_DEADLINE_SECONDS):
        raise HarvestError(
            f"deadline must be > 600 and <= {MAX_DEADLINE_SECONDS} seconds"
        )
    return run(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (HarvestError, OSError) as error:
        print(f"HARVEST: FAIL:{error}", file=sys.stderr)
        raise SystemExit(1)
