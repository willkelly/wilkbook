#!/usr/bin/env python3
"""Runs inside gVisor immediately before the fixed Python note.

The trusted database, UI socket, and every other authority descriptor must be
absent; FD 3 is the sole connected application capability.
"""

from __future__ import annotations

import errno
import fcntl
import os
import stat


STATE_ROOT = "/data/wilkbook/book-state"
STATE_DATABASE = "/data/wilkbook/book-state/book-state-v1.sqlite"
PRIVATE_UI_SOCKET = "/run/wilkbook-book-state/control.sock"
DENIED_ERRNOS = frozenset({errno.ENOENT, errno.EACCES, errno.EPERM})


def require_denied(label: str, operation) -> None:
    try:
        operation()
    except OSError as error:
        if error.errno not in DENIED_ERRNOS:
            raise RuntimeError(
                f"device sandbox storage boundary: {label} returned "
                f"errno {error.errno}"
            ) from error
    else:
        raise RuntimeError(
            f"device sandbox storage boundary: forbidden resource visible: {label}"
        )


for path in (STATE_ROOT, STATE_DATABASE, PRIVATE_UI_SOCKET):
    require_denied(path, lambda path=path: os.stat(path))

    def open_for_read(path=path) -> None:
        descriptor = os.open(path, os.O_RDONLY)
        os.close(descriptor)

    require_denied(path, open_for_read)

with open("/proc/self/mountinfo", "r", encoding="utf-8") as mountinfo_file:
    mountinfo = mountinfo_file.read()
for path in (STATE_ROOT, PRIVATE_UI_SOCKET):
    if path in mountinfo:
        raise RuntimeError(
            f"device sandbox storage boundary: authority path entered mountinfo: {path}"
        )

records: list[tuple[int, int, int, str]] = []
for name in os.listdir("/proc/self/fd"):
    try:
        descriptor = int(name)
        flags = fcntl.fcntl(descriptor, fcntl.F_GETFD)
        mode = os.fstat(descriptor).st_mode
        target = os.readlink(f"/proc/self/fd/{name}")
    except ValueError:
        continue
    except OSError as error:
        if error.errno == errno.EBADF:
            continue
        raise
    records.append((descriptor, flags, mode, target))

descriptors = {record[0] for record in records}
if not {0, 1, 2, 3} <= descriptors:
    raise RuntimeError("device sandbox storage boundary: required FD is absent")
if not stat.S_ISSOCK(os.fstat(3).st_mode):
    raise RuntimeError("device sandbox storage boundary: FD 3 is not a socket")
if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
    raise RuntimeError("device sandbox storage boundary: FD 3 remained close-on-exec")
if any(stat.S_ISSOCK(os.fstat(descriptor).st_mode) for descriptor in (0, 1, 2)):
    raise RuntimeError("device sandbox storage boundary: standard FD is a socket")
for descriptor, flags, mode, target in records:
    if descriptor <= 3:
        continue
    if not flags & fcntl.FD_CLOEXEC:
        raise RuntimeError(
            f"device sandbox storage boundary: extra FD {descriptor} is not CLOEXEC"
        )
    if stat.S_ISSOCK(mode) or stat.S_ISCHR(mode):
        raise RuntimeError(
            f"device sandbox storage boundary: extra FD {descriptor} is a capability"
        )
    if STATE_ROOT in target or PRIVATE_UI_SOCKET in target:
        raise RuntimeError(
            f"device sandbox storage boundary: extra FD exposes {target}"
        )

print(
    "BOOK_STATE_SANDBOX_BOUNDARY: language=python result=pass "
    "storage-mount=absent storage-fd=absent ui-transport=absent "
    "book-session-fd=3",
    flush=True,
)
