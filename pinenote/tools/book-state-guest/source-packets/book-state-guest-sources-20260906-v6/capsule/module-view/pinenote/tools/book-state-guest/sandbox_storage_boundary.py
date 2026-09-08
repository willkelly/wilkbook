#!/usr/bin/env python3
"""Fixed in-sandbox boundary probe run before the unchanged Python Book."""

from __future__ import annotations

import errno
import fcntl
import os
import stat


STATE_ROOT = "/var/lib/wilkbook-book-state-demo"
STATE_SENTINEL = (
    "/var/lib/wilkbook-book-state-demo/.sandbox-boundary-sentinel-v1"
)
STATE_DATABASE = (
    "/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite"
)
PRIVATE_UI_DEVICE = "/dev/virtio-ports/org.wilkbook.book-interaction"
DENIED_ERRNOS = frozenset({errno.ENOENT, errno.EACCES, errno.EPERM})


def require_open_denied(label: str, path: str, flags: int) -> None:
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        if error.errno not in DENIED_ERRNOS:
            raise RuntimeError(
                f"sandbox storage boundary: {label} returned errno {error.errno}"
            ) from error
    else:
        os.close(descriptor)
        raise RuntimeError(
            f"sandbox storage boundary: {label} unexpectedly opened {path}"
        )


def require_stat_denied(label: str, path: str) -> None:
    try:
        os.stat(path)
    except OSError as error:
        if error.errno not in DENIED_ERRNOS:
            raise RuntimeError(
                f"sandbox storage boundary: {label} returned errno {error.errno}"
            ) from error
    else:
        raise RuntimeError(
            f"sandbox storage boundary: {label} unexpectedly saw {path}"
        )


def live_fd_records() -> list[tuple[int, int, int, str]]:
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
    return sorted(records)


require_stat_denied("state-root-stat", STATE_ROOT)
require_stat_denied("state-sentinel-stat", STATE_SENTINEL)
for probe_label, probe_path in (
    ("state-sentinel", STATE_SENTINEL),
    ("state-database", STATE_DATABASE),
    ("private-ui-device", PRIVATE_UI_DEVICE),
):
    require_open_denied(f"{probe_label}-read", probe_path, os.O_RDONLY)
    require_open_denied(f"{probe_label}-write", probe_path, os.O_WRONLY)

with open("/proc/self/mountinfo", "r", encoding="utf-8") as mountinfo_file:
    mountinfo = mountinfo_file.read()
for forbidden_path in (STATE_ROOT, PRIVATE_UI_DEVICE):
    if forbidden_path in mountinfo:
        raise RuntimeError(
            "sandbox storage boundary: authority path entered mountinfo: "
            f"{forbidden_path}"
        )

records = live_fd_records()
descriptors = [record[0] for record in records]
if not {0, 1, 2, 3} <= set(descriptors):
    raise RuntimeError(
        "sandbox storage boundary: a required descriptor is absent: "
        f"{descriptors!r}"
    )
if not stat.S_ISSOCK(os.fstat(3).st_mode):
    raise RuntimeError("sandbox storage boundary: FD 3 is not the Book Session socket")
if fcntl.fcntl(3, fcntl.F_GETFD) & fcntl.FD_CLOEXEC:
    raise RuntimeError("sandbox storage boundary: FD 3 remained close-on-exec")
if any(stat.S_ISSOCK(os.fstat(descriptor).st_mode) for descriptor in (0, 1, 2)):
    raise RuntimeError("sandbox storage boundary: a standard FD is an extra socket")
for descriptor, flags, mode, target in records:
    if descriptor <= 3:
        continue
    if not flags & fcntl.FD_CLOEXEC:
        raise RuntimeError(
            f"sandbox storage boundary: extra FD {descriptor} is not close-on-exec"
        )
    if stat.S_ISSOCK(mode):
        raise RuntimeError(
            f"sandbox storage boundary: extra FD {descriptor} is another socket"
        )
    if stat.S_ISCHR(mode):
        raise RuntimeError(
            f"sandbox storage boundary: extra FD {descriptor} is a character device"
        )
    if STATE_ROOT in target or PRIVATE_UI_DEVICE in target:
        raise RuntimeError(
            f"sandbox storage boundary: extra FD {descriptor} exposes {target}"
        )

print(
    "BOOK_STATE_SANDBOX_BOUNDARY: language=python result=pass "
    "storage-mount=absent storage-fd=absent ui-transport=absent "
    "book-session-fd=3",
    flush=True,
)
