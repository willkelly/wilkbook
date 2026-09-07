#!/usr/bin/env python3
"""Retain six fixed reader-QEMU logs after proving owned writers are gone.

This Linux-only host observer is not a protocol or semantic checker.  It becomes
a child subreaper, launches one reviewed production entry in a private session,
and keeps read-only/CLOEXEC descriptors for six fixed logs across guardian
unlink.  A harvest can be complete only after the direct launcher is reaped,
no adopted descendant remains, both launcher pipes reach EOF, and each source
has stable pre/post metadata around an exact bounded read.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
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
PIPE_EOF_GRACE_SECONDS = 0.50
TERM_GRACE_SECONDS = 5.0
FINAL_REAP_SECONDS = 1.0
MIN_DEADLINE_SECONDS = 0.20
MAX_DEADLINE_SECONDS = 660.0
MAX_LAUNCHER_STDOUT = 64 * 1024
MAX_LAUNCHER_STDERR = 24 * 1024 * 1024
PR_SET_CHILD_SUBREAPER = 36

# Mirrors disposable-qemu.scm's exact completed-console bound.
MAX_CONSOLE = (
    (4 + 12) * (8 * 1024 + 8 * 1024) * 5
    + 12 * 255 * 5
    + 2 * 1024 * 1024
)
MAX_READER_LOG = 128 * 1024
MAX_QEMU_CAPTURE = 4 * 1024 * 1024
MAX_COORDINATOR_CAPTURE = 4 * 1024 * 1024

LOG_SPECS = (
    ("console.log", "root", "console.log", MAX_CONSOLE),
    ("coordinator.stdout", "root", "qemu.stdout", MAX_COORDINATOR_CAPTURE),
    ("coordinator.stderr", "root", "qemu.stderr", MAX_COORDINATOR_CAPTURE),
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


@dataclass
class RetainedLog:
    content: bytes
    size: int
    pre_mtime_ns: int
    post_mtime_ns: int
    pre_ctime_ns: int
    post_ctime_ns: int


@dataclass
class BoundedStream:
    label: str
    source: BinaryIO
    limit: int
    retained: bytearray
    observed: int = 0
    overflow: bool = False


@dataclass
class OwnedChild:
    pid: int
    start_time: int
    pidfd: int
    term_sent: bool = False
    kill_sent: bool = False


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def normalize_returncode(value: int) -> int:
    return 128 + (-value) if value < 0 else value


def wait_status(value: int) -> int:
    return os.waitstatus_to_exitcode(value)


def enable_child_subreaper() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = (
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    )
    prctl.restype = ctypes.c_int
    if prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise HarvestError(f"could not become child subreaper: {os.strerror(error)}")


def proc_details(pid: int) -> tuple[int, int] | None:
    """Return (parent PID, start time) from one bounded /proc stat record."""
    try:
        with open(f"/proc/{pid}/stat", "rb", buffering=0) as port:
            content = port.read(8193)
    except FileNotFoundError:
        return None
    if len(content) > 8192 or not content.endswith(b"\n"):
        raise HarvestError(f"invalid /proc stat record for owned PID {pid}")
    close = content.rfind(b")")
    if close < 0:
        raise HarvestError(f"malformed /proc stat record for owned PID {pid}")
    fields = content[close + 2 :].split()
    if len(fields) < 20:
        raise HarvestError(f"short /proc stat record for owned PID {pid}")
    try:
        # The suffix starts with field 3.  Parent PID is field 4 and process
        # start time is field 22.
        return int(fields[1]), int(fields[19])
    except ValueError as error:
        raise HarvestError(f"non-numeric /proc identity for owned PID {pid}") from error


def direct_child_pids() -> tuple[int, ...]:
    path = f"/proc/self/task/{os.getpid()}/children"
    try:
        with open(path, "r", encoding="ascii") as port:
            content = port.read(1024 * 1024 + 1)
    except OSError as error:
        raise HarvestError(f"cannot inspect exact subreaper children: {error}") from error
    if len(content) > 1024 * 1024:
        raise HarvestError("exact subreaper child list exceeds its bound")
    try:
        return tuple(int(value) for value in content.split())
    except ValueError as error:
        raise HarvestError("malformed exact subreaper child list") from error


def open_owned_child(pid: int) -> OwnedChild | None:
    before = proc_details(pid)
    if before is None or before[0] != os.getpid():
        return None
    try:
        pidfd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        return None
    except OSError as error:
        raise HarvestError(f"cannot open pidfd for owned PID {pid}: {error}") from error
    after = proc_details(pid)
    if after is None or after != before or after[0] != os.getpid():
        os.close(pidfd)
        return None
    return OwnedChild(pid=pid, start_time=before[1], pidfd=pidfd)


def discover_owned_children(
    direct_pid: int, children: dict[int, OwnedChild]
) -> list[OwnedChild]:
    discovered: list[OwnedChild] = []
    for pid in direct_child_pids():
        if pid == direct_pid or pid in children:
            continue
        child = open_owned_child(pid)
        if child is not None:
            children[pid] = child
            discovered.append(child)
    return discovered


def signal_pidfd(pidfd: int, number: int) -> None:
    try:
        signal.pidfd_send_signal(pidfd, number, None, 0)
    except ProcessLookupError:
        pass


def reap_owned_children(
    children: dict[int, OwnedChild], statuses: list[tuple[int, int, int]]
) -> None:
    for pid, child in list(children.items()):
        try:
            reaped, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError as error:
            raise HarvestError(
                f"identity-tracked owned PID {pid} ceased to be waitable"
            ) from error
        if reaped == pid:
            statuses.append((pid, child.start_time, wait_status(status)))
            os.close(child.pidfd)
            del children[pid]


def emergency_cleanup_owned_tree(
    process: subprocess.Popen[bytes],
    direct_pidfd: int | None,
    children: dict[int, OwnedChild],
    statuses: list[tuple[int, int, int]],
) -> None:
    """Boundedly clean only the direct child and descendants adopted here."""
    term_deadline = time.monotonic() + TERM_GRACE_SECONDS
    if process.poll() is None:
        if direct_pidfd is not None:
            signal_pidfd(direct_pidfd, signal.SIGTERM)
        else:
            process.send_signal(signal.SIGTERM)
    while time.monotonic() < term_deadline:
        for child in discover_owned_children(process.pid, children):
            signal_pidfd(child.pidfd, signal.SIGTERM)
            child.term_sent = True
        for child in children.values():
            if not child.term_sent:
                signal_pidfd(child.pidfd, signal.SIGTERM)
                child.term_sent = True
        reap_owned_children(children, statuses)
        if process.poll() is not None and not children:
            return
        time.sleep(POLL_SECONDS)

    if process.poll() is None:
        if direct_pidfd is not None:
            signal_pidfd(direct_pidfd, signal.SIGKILL)
        else:
            process.kill()
    kill_deadline = time.monotonic() + FINAL_REAP_SECONDS
    while time.monotonic() < kill_deadline:
        for child in discover_owned_children(process.pid, children):
            signal_pidfd(child.pidfd, signal.SIGKILL)
            child.kill_sent = True
        for child in children.values():
            if not child.kill_sent:
                signal_pidfd(child.pidfd, signal.SIGKILL)
                child.kill_sent = True
        reap_owned_children(children, statuses)
        if process.poll() is not None and not children:
            return
        time.sleep(POLL_SECONDS)


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
    if os.listdir(fd):
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


def open_private_directory(
    name: str, parent_fd: int, label: str
) -> tuple[int, os.stat_result] | None:
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
    return HeldLog(label, parent_kind, name, limit, fd, opened.st_dev, opened.st_ino)


def stable_metadata(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def read_held_log_stable(log: HeldLog, deadline: float) -> RetainedLog:
    before = os.fstat(log.fd)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or identity(before) != (log.device, log.inode)
    ):
        raise HarvestError(f"{log.label} source identity changed before export")
    if before.st_size > log.limit:
        raise HarvestError(f"{log.label} exceeds its {log.limit}-byte harvest bound")
    chunks: list[bytes] = []
    offset = 0
    while offset < before.st_size:
        if time.monotonic() >= deadline:
            raise HarvestError("absolute deadline expired during source export")
        value = os.pread(log.fd, min(64 * 1024, before.st_size - offset), offset)
        if not value:
            raise HarvestError(f"{log.label} yielded a short source read")
        chunks.append(value)
        offset += len(value)
    if os.pread(log.fd, 1, before.st_size):
        raise HarvestError(f"{log.label} grew during its exact source read")
    after = os.fstat(log.fd)
    if stable_metadata(before) != stable_metadata(after):
        raise HarvestError(f"{log.label} metadata changed during export")
    content = b"".join(chunks)
    if len(content) != before.st_size:
        raise HarvestError(f"{log.label} exact source byte count changed")
    return RetainedLog(
        content=content,
        size=before.st_size,
        pre_mtime_ns=before.st_mtime_ns,
        post_mtime_ns=after.st_mtime_ns,
        pre_ctime_ns=before.st_ctime_ns,
        post_ctime_ns=after.st_ctime_ns,
    )


def sanitized_error(error: str) -> str:
    return error.replace("\n", " ").replace("\r", " ")


def add_error(errors: list[str], message: str) -> None:
    if message not in errors:
        errors.append(message)


def close_selector_streams(selector: selectors.BaseSelector) -> None:
    for key in list(selector.get_map().values()):
        try:
            selector.unregister(key.fileobj)
        except Exception:
            pass
        try:
            key.fileobj.close()
        except Exception:
            pass


def pump_streams(selector: selectors.BaseSelector) -> list[BoundedStream]:
    changed: list[BoundedStream] = []
    for key, _events in selector.select(POLL_SECONDS):
        stream: BoundedStream = key.data
        try:
            value = os.read(stream.source.fileno(), 64 * 1024)
        except BlockingIOError:
            continue
        if value:
            append_stream(stream, value)
            changed.append(stream)
        else:
            selector.unregister(stream.source)
            stream.source.close()
    return changed


def run(arguments: argparse.Namespace) -> int:
    started = time.monotonic()
    hard_deadline = started + arguments.deadline_seconds
    cleanup_reserve = min(TERM_GRACE_SECONDS, arguments.deadline_seconds / 2)
    cleanup_trigger = hard_deadline - cleanup_reserve
    run_base, base_fd, base_info = secure_directory(arguments.run_base, "run base")
    evidence_fd: int | None = None
    root_fd: int | None = None
    reader_fd: int | None = None
    root_info: os.stat_result | None = None
    reader_info: os.stat_result | None = None
    root_name: str | None = None
    held: dict[str, HeldLog] = {}
    retained_logs: dict[str, RetainedLog] = {}
    errors: list[str] = []
    adopted_statuses: list[tuple[int, int, int]] = []
    adopted: dict[int, OwnedChild] = {}
    adopted_seen: set[tuple[int, int]] = set()
    process: subprocess.Popen[bytes] | None = None
    direct_pidfd: int | None = None
    direct_status: int | None = None
    direct_term_sent = False
    direct_kill_sent = False
    terminating = False
    kill_at = hard_deadline
    pipe_eof_deadline: float | None = None
    monitoring = True
    pipes_forced_closed = False
    received_signal: int | None = None

    def note_signal(number: int, _frame: object) -> None:
        nonlocal received_signal
        if received_signal is None:
            received_signal = number

    old_handlers = {
        number: signal.signal(number, note_signal)
        for number in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
    }
    old_sigchld = signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    stdout_stream: BoundedStream | None = None
    stderr_stream: BoundedStream | None = None
    selector = selectors.DefaultSelector()

    def request_termination(message: str, forwarded_signal: int = signal.SIGTERM) -> None:
        nonlocal terminating, kill_at, direct_term_sent
        add_error(errors, message)
        now = time.monotonic()
        if not terminating:
            terminating = True
            kill_at = min(now + TERM_GRACE_SECONDS, hard_deadline)
        if (
            process is not None
            and process.poll() is None
            and direct_pidfd is not None
            and not direct_term_sent
        ):
            signal_pidfd(direct_pidfd, forwarded_signal)
            direct_term_sent = True
        for child in adopted.values():
            if not child.term_sent:
                signal_pidfd(child.pidfd, signal.SIGTERM)
                child.term_sent = True

    def force_close_pipes() -> None:
        nonlocal pipes_forced_closed
        if selector.get_map():
            pipes_forced_closed = True
            close_selector_streams(selector)

    def record_received_signal() -> bool:
        if received_signal is None:
            return False
        add_error(errors, f"harvest wrapper received signal {received_signal}")
        return True

    try:
        require_empty_directory(base_fd, "run base")
        validate_command(arguments.command, run_base)
        _, evidence_fd = make_evidence_directory(arguments.evidence_dir, run_base)
        enable_child_subreaper()
        # Fail before launch if this Linux kernel cannot expose the helper's
        # exact direct-child relation.  No global /proc walk is ever used.
        if direct_child_pids():
            raise HarvestError("harvester had an unexpected child before launch")
        process = subprocess.Popen(
            arguments.command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            start_new_session=True,
        )
        direct_pidfd = os.pidfd_open(process.pid, 0)
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

        emergency_deadline = hard_deadline + FINAL_REAP_SECONDS
        while True:
            now = time.monotonic()
            polled = process.poll()
            if polled is not None and direct_status is None:
                direct_status = normalize_returncode(polled)

            try:
                newly_adopted = discover_owned_children(process.pid, adopted)
            except HarvestError as error:
                newly_adopted = []
                request_termination(str(error))
            for child in newly_adopted:
                adopted_seen.add((child.pid, child.start_time))
                request_termination(
                    "owned descendant survived outside the production launcher's reap"
                )
            reap_owned_children(adopted, adopted_statuses)

            if received_signal is not None:
                request_termination(
                    f"harvest wrapper received signal {received_signal}", received_signal
                )
            if now >= cleanup_trigger and direct_status is None and not terminating:
                request_termination("absolute deadline required bounded cleanup")

            for stream in pump_streams(selector):
                if stream.overflow:
                    request_termination(f"{stream.label} exceeded its bound")

            if monitoring:
                try:
                    current_base = os.stat(run_base, follow_symlinks=False)
                    if identity(current_base) != identity(base_info):
                        raise HarvestError("run base identity changed during harvest")
                    names = [
                        name for name in os.listdir(base_fd) if name.startswith(RUN_PREFIX)
                    ]
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
                        opened_reader = open_private_directory(
                            "reader-ui", root_fd, "reader-ui"
                        )
                        if opened_reader is not None:
                            reader_fd, reader_info = opened_reader
                    if reader_fd is not None and reader_info is not None and root_fd is not None:
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
                            parent = parents[log.parent_kind]
                            assert parent is not None
                            current = safe_stat(log.name, parent)
                            if current is not None and identity(current) != (
                                log.device,
                                log.inode,
                            ):
                                raise HarvestError(f"{label} pathname was replaced")
                            if os.fstat(log.fd).st_size > log.limit:
                                raise HarvestError(
                                    f"{label} exceeds its {log.limit}-byte harvest bound"
                                )
                except (HarvestError, OSError) as error:
                    monitoring = False
                    request_termination(str(error))

            if terminating:
                # The accepted outer gets the first TERM/HUP/INT and retains its
                # own five-second guarded-PGID cleanup.  Only after descendants
                # are reparented here are their identity-bound pidfds signalled.
                for child in adopted.values():
                    if not child.term_sent:
                        signal_pidfd(child.pidfd, signal.SIGTERM)
                        child.term_sent = True
                if now >= kill_at:
                    if direct_status is None and not direct_kill_sent:
                        assert direct_pidfd is not None
                        signal_pidfd(direct_pidfd, signal.SIGKILL)
                        direct_kill_sent = True
                    for child in adopted.values():
                        if not child.kill_sent:
                            signal_pidfd(child.pidfd, signal.SIGKILL)
                            child.kill_sent = True

            if direct_status is not None and not adopted:
                if selector.get_map():
                    if pipe_eof_deadline is None:
                        pipe_eof_deadline = min(
                            hard_deadline, time.monotonic() + PIPE_EOF_GRACE_SECONDS
                        )
                    elif time.monotonic() >= pipe_eof_deadline:
                        request_termination(
                            "launcher pipes did not reach EOF after owned children finished"
                        )
                        force_close_pipes()
                if not selector.get_map():
                    break

            if now >= hard_deadline:
                request_termination("absolute harvester deadline expired")
                if direct_status is None and not direct_kill_sent:
                    assert direct_pidfd is not None
                    signal_pidfd(direct_pidfd, signal.SIGKILL)
                    direct_kill_sent = True
                for child in adopted.values():
                    if not child.kill_sent:
                        signal_pidfd(child.pidfd, signal.SIGKILL)
                        child.kill_sent = True
                force_close_pipes()
            if now >= emergency_deadline:
                add_error(errors, "owned process cleanup exceeded final reap bound")
                force_close_pipes()
                break

        # Final nonblocking adoption/reap passes catch grandchildren reparented
        # when a just-killed adopted parent exits.  Only exact direct children of
        # this subreaper are ever signalled.
        final_deadline = time.monotonic() + FINAL_REAP_SECONDS
        while time.monotonic() < final_deadline:
            polled = process.poll()
            if polled is not None and direct_status is None:
                direct_status = normalize_returncode(polled)
            newly_adopted = discover_owned_children(process.pid, adopted)
            for child in newly_adopted:
                adopted_seen.add((child.pid, child.start_time))
                add_error(
                    errors, "owned descendant survived outside the production launcher's reap"
                )
            for child in adopted.values():
                if not child.kill_sent:
                    signal_pidfd(child.pidfd, signal.SIGKILL)
                    child.kill_sent = True
            reap_owned_children(adopted, adopted_statuses)
            if direct_status is not None and not adopted:
                break
            if direct_status is None and not direct_kill_sent:
                assert direct_pidfd is not None
                signal_pidfd(direct_pidfd, signal.SIGKILL)
                direct_kill_sent = True
            time.sleep(POLL_SECONDS)
        if direct_status is None:
            add_error(errors, "direct launcher was not reaped within the final bound")
        if adopted:
            add_error(errors, "adopted owned children were not reaped within the final bound")
        close_selector_streams(selector)
        record_received_signal()

        # Writer completion is established before any source read: the direct
        # launcher has been reaped and the subreaper has no adopted child.
        writer_completion = direct_status is not None and not adopted
        if not writer_completion:
            add_error(errors, "owned writer completion condition was not established")

        if writer_completion:
            export_deadline = hard_deadline
            for label, _parent_kind, _name, _limit in LOG_SPECS:
                log = held.get(label)
                if log is None:
                    if direct_status == 0:
                        add_error(errors, f"required log was not opened: {label}")
                    continue
                try:
                    retained_logs[label] = read_held_log_stable(log, export_deadline)
                except (HarvestError, OSError) as error:
                    add_error(errors, str(error))
                if record_received_signal():
                    break

        roots_after = [name for name in os.listdir(base_fd) if name.startswith(RUN_PREFIX)]
        if roots_after:
            add_error(errors, "run root remained after launcher completion")
        if stdout_stream and stdout_stream.overflow:
            add_error(errors, "launcher.stdout exceeded its bound")
        if stderr_stream and stderr_stream.overflow:
            add_error(errors, "launcher.stderr exceeded its bound")

        assert evidence_fd is not None
        launcher_stdout = bytes(stdout_stream.retained if stdout_stream else b"")
        launcher_stderr = bytes(stderr_stream.retained if stderr_stream else b"")
        write_evidence(evidence_fd, "launcher.stdout", launcher_stdout)
        record_received_signal()
        write_evidence(evidence_fd, "launcher.stderr", launcher_stderr)
        record_received_signal()
        for label, retained in retained_logs.items():
            write_evidence(evidence_fd, label, retained.content)
            if record_received_signal():
                break

        if time.monotonic() >= hard_deadline:
            add_error(errors, "absolute deadline expired before evidence publication")
        record_received_signal()
        complete = (
            direct_status == 0
            and writer_completion
            and not adopted_seen
            and received_signal is None
            and not errors
            and len(retained_logs) == len(LOG_SPECS)
        )
        manifest = [
            "schema=2",
            "role=bounded-reader-qemu-log-harvest",
            f"harvest-status={'complete' if complete else 'failed'}",
            f"launcher-status={direct_status if direct_status is not None else 'unreaped'}",
            "child-subreaper=true",
            "launcher-private-session=true",
            f"writer-completion={'true' if writer_completion else 'false'}",
            f"adopted-owned-children-observed={len(adopted_seen)}",
            f"adopted-owned-children-unreaped={len(adopted)}",
            f"launcher-pipes-eof={'false' if pipes_forced_closed else 'true'}",
            f"launcher-stdout-observed={stdout_stream.observed if stdout_stream else 0}",
            f"launcher-stdout-retained={len(launcher_stdout)}",
            f"launcher-stdout-limit={MAX_LAUNCHER_STDOUT}",
            f"launcher-stderr-observed={stderr_stream.observed if stderr_stream else 0}",
            f"launcher-stderr-retained={len(launcher_stderr)}",
            f"launcher-stderr-limit={MAX_LAUNCHER_STDERR}",
            f"run-root-name={root_name or 'none'}",
            f"run-root-removed={'true' if not roots_after else 'false'}",
        ]
        for pid, start_time_value in sorted(adopted_seen):
            manifest.append(
                f"adopted-owned-child=pid:{pid} start-time:{start_time_value}"
            )
        for pid, start_time_value, status in adopted_statuses:
            manifest.append(
                f"adopted-owned-child-reaped=pid:{pid} start-time:{start_time_value} status:{status}"
            )
        for label, _parent_kind, _name, limit in LOG_SPECS:
            retained = retained_logs.get(label)
            if retained is not None:
                log = held[label]
                manifest.append(
                    f"log={label} state=retained bytes={len(retained.content)} "
                    f"source-size={retained.size} limit={limit} "
                    f"source-device={log.device} source-inode={log.inode} "
                    f"pre-mtime-ns={retained.pre_mtime_ns} "
                    f"post-mtime-ns={retained.post_mtime_ns} "
                    f"pre-ctime-ns={retained.pre_ctime_ns} "
                    f"post-ctime-ns={retained.post_ctime_ns} "
                    f"sha256={sha256_bytes(retained.content)}"
                )
            else:
                manifest.append(f"log={label} state=missing-or-unstable limit={limit}")
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
        return direct_status if direct_status not in (None, 0) else 1
    finally:
        selector.close()
        if process is not None and (process.poll() is None or adopted):
            try:
                emergency_cleanup_owned_tree(
                    process, direct_pidfd, adopted, adopted_statuses
                )
            except (HarvestError, OSError):
                # Never replace an already selected direct status with cleanup
                # status.  The main path records expected cleanup failures;
                # this final guard exists only for unexpected Python unwinds.
                pass
        for child in adopted.values():
            try:
                signal_pidfd(child.pidfd, signal.SIGKILL)
            except OSError:
                pass
            try:
                os.close(child.pidfd)
            except OSError:
                pass
        if direct_pidfd is not None:
            try:
                os.close(direct_pidfd)
            except OSError:
                pass
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
        signal.signal(signal.SIGCHLD, old_sigchld)
        for number, handler in old_handlers.items():
            signal.signal(number, handler)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="bounded evidence wrapper for one disposable reader-QEMU run"
    )
    result.add_argument("--run-base", type=Path, required=True)
    result.add_argument("--evidence-dir", type=Path, required=True)
    result.add_argument(
        "--deadline-seconds",
        type=float,
        default=630.0,
        help="absolute helper lifetime including pipe drain and source export",
    )
    result.add_argument("command", nargs=argparse.REMAINDER)
    return result


def main(argv: list[str]) -> int:
    arguments = parser().parse_args(argv)
    if arguments.command and arguments.command[0] == "--":
        arguments.command = arguments.command[1:]
    if not (MIN_DEADLINE_SECONDS <= arguments.deadline_seconds <= MAX_DEADLINE_SECONDS):
        raise HarvestError(
            f"deadline must be >= {MIN_DEADLINE_SECONDS} and <= "
            f"{MAX_DEADLINE_SECONDS} seconds"
        )
    return run(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (HarvestError, OSError) as error:
        print(f"HARVEST: FAIL:{error}", file=sys.stderr)
        raise SystemExit(1)
