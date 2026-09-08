#!/usr/bin/env python3
"""Trusted minimal copier from reviewed runtime map to one private capsule.

This helper and run-two-boot.sh are the finite bootstrap trust boundary.  The
helper cannot cryptographically authenticate itself; the launcher pins and
copies its bytes before execution.  It does authenticate every subsequently
loaded campaign source byte against RUNTIME-SOURCE-MANIFEST.sha256, copies from
held descriptors with stable metadata, and executes only the retained copy.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys


EXPECTED_RUNTIME_MANIFEST_SHA256 = (
    "f47761038533f16216d069cef1e9fd4fa54dbcebfd357a18fb53e2eb77ec5cc6"
)
GUILE = "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile"
GUILE_SHA256 = "cef96854423238cab5ef9f4e5ddc1379b43eef40a4b26d73e814583479789888"
GCRYPT = "/gnu/store/yj7cgbs9d4qc93v93h63kpmdq0vm5k2i-guile-gcrypt-0.5.0"
GUIX_MODULES = "/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules"
PYTHON = "/gnu/store/c9ga6sl21sy1cbxdllvxkj6qlnk4yzbh-python-3.11.14/bin/python3.11"
PYTHON_SHA256 = "6628ece57f92247f650271282e1902e17f754b31296d6d9e13d56643385e536f"
MAX_SOURCE_BYTES = 4 * 1024 * 1024


class BootstrapError(RuntimeError):
    pass


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_file(path: str) -> str:
    result = hashlib.sha256()
    with open(path, "rb", buffering=0) as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_relative(raw: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        raise BootstrapError(f"unsafe runtime source path: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise BootstrapError(f"unsafe runtime source path: {raw!r}")
    if path.as_posix() != raw or any(ord(character) < 0x20 for character in raw):
        raise BootstrapError(f"noncanonical runtime source path: {raw!r}")
    return raw


def stable_fields(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_uid,
        info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def require_source_directory(path: Path) -> None:
    info = path.lstat()
    if not (stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and
            stat.S_IMODE(info.st_mode) & 0o222 == 0):
        raise BootstrapError(f"source directory is not owned and immutable: {path}")


def open_source(path: Path) -> tuple[int, os.stat_result]:
    info = path.lstat()
    if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and
            info.st_nlink == 1 and stat.S_IMODE(info.st_mode) & 0o222 == 0 and
            info.st_size <= MAX_SOURCE_BYTES):
        raise BootstrapError(f"source is not immutable bounded single-link data: {path}")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    opened = os.fstat(fd)
    if stable_fields(info) != stable_fields(opened):
        os.close(fd)
        raise BootstrapError(f"source changed while opening: {path}")
    return fd, opened


def read_stable(fd: int, opened: os.stat_result, path: Path) -> bytes:
    chunks: list[bytes] = []
    observed = 0
    while True:
        block = os.read(fd, min(65536, MAX_SOURCE_BYTES + 1 - observed))
        if not block:
            break
        chunks.append(block)
        observed += len(block)
        if observed > MAX_SOURCE_BYTES:
            raise BootstrapError(f"source exceeded runtime bound: {path}")
    if stable_fields(opened) != stable_fields(os.fstat(fd)):
        raise BootstrapError(f"source changed while reading: {path}")
    return b"".join(chunks)


def parse_manifest(data: bytes) -> list[tuple[str, str]]:
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise BootstrapError("runtime source manifest is not UTF-8") from error
    entries: list[tuple[str, str]] = []
    prior: str | None = None
    for line in lines:
        if len(line) < 67 or line[64:66] != "  ":
            raise BootstrapError("runtime source manifest has malformed framing")
        expected, relative = line[:64], safe_relative(line[66:])
        if (len(expected) != 64 or
                any(character not in "0123456789abcdef" for character in expected)):
            raise BootstrapError("runtime source manifest has malformed SHA-256")
        if prior is not None and prior >= relative:
            raise BootstrapError("runtime source manifest is not uniquely sorted")
        entries.append((relative, expected))
        prior = relative
    if not entries:
        raise BootstrapError("runtime source manifest is empty")
    return entries


def ensure_source_parents(source_root: Path, relative: str) -> None:
    require_source_directory(source_root)
    current = source_root
    for part in PurePosixPath(relative).parts[:-1]:
        current /= part
        require_source_directory(current)


def copy_entry(source_root: Path, destination_root: Path,
               relative: str, expected: str) -> None:
    ensure_source_parents(source_root, relative)
    source_path = source_root / relative
    fd, opened = open_source(source_path)
    try:
        data = read_stable(fd, opened, source_path)
    finally:
        os.close(fd)
    if digest_bytes(data) != expected:
        raise BootstrapError(f"runtime source authentication failed: {relative}")
    destination = destination_root / relative
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output = os.open(destination,
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC |
                     os.O_NOFOLLOW,
                     0o600)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(output, data[offset:])
        os.fsync(output)
        os.fchmod(output, 0o400)
        copied = os.fstat(output)
    finally:
        os.close(output)
    if not (stat.S_ISREG(copied.st_mode) and copied.st_nlink == 1 and
            stat.S_IMODE(copied.st_mode) == 0o400 and copied.st_size == len(data) and
            digest_file(str(destination)) == expected):
        raise BootstrapError(f"retained runtime source differs: {relative}")


def write_retained_manifest(destination_root: Path, data: bytes) -> str:
    path = destination_root / "SOURCE-MANIFEST.sha256"
    fd = os.open(path,
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC |
                 os.O_NOFOLLOW,
                 0o600)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.fchmod(fd, 0o400)
    finally:
        os.close(fd)
    return digest_bytes(data)


def seal_private_directories(root: Path) -> None:
    directories = [root, *(path for path in root.rglob("*") if path.is_dir())]
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise BootstrapError(f"retained source has a linked directory: {directory}")
        # The accepted run-root guardian owns this private tree.  Mode 0700 is
        # intentional so that guardian cleanup also works after owner SIGKILL;
        # regular source bytes remain mode 0400 and hash-pinned.
        directory.chmod(0o700)


def assert_inventory(root: Path, entries: list[tuple[str, str]]) -> None:
    observed: list[str] = []
    for path in root.rglob("*"):
        info = path.lstat()
        if stat.S_ISREG(info.st_mode):
            observed.append(path.relative_to(root).as_posix())
        elif not stat.S_ISDIR(info.st_mode):
            raise BootstrapError(f"retained source has special entry: {path}")
    expected = sorted([relative for relative, _ in entries] +
                      ["SOURCE-MANIFEST.sha256"])
    if sorted(observed) != expected:
        raise BootstrapError("retained runtime inventory differs from reviewed map")


def require_private_root(path: Path) -> None:
    if not (path.is_absolute() and str(path).startswith("/tmp/opencode/") and
            path.resolve() == path):
        raise BootstrapError("bootstrap root must be canonical under /tmp/opencode")
    info = path.lstat()
    if not (stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and
            stat.S_IMODE(info.st_mode) == 0o700):
        raise BootstrapError("bootstrap root must be owned mode 0700")


def close_unrelated_descriptors() -> None:
    try:
        names = os.listdir("/proc/self/fd")
    except OSError:
        maximum = os.sysconf("SC_OPEN_MAX")
        os.closerange(3, int(maximum))
        return
    for name in names:
        if name.isdigit() and int(name) > 2:
            try:
                os.close(int(name))
            except OSError:
                pass


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--bootstrap-root", required=True)
    parser.add_argument("--test-before-exec-ready-fd", type=int)
    parser.add_argument("--test-before-exec-continue-fd", type=int)
    parser.add_argument("campaign", nargs=argparse.REMAINDER)
    result = parser.parse_args(argv)
    if result.campaign[:1] == ["--"]:
        result.campaign = result.campaign[1:]
    return result


def run(arguments: argparse.Namespace) -> None:
    source_root = Path(arguments.source_root)
    bootstrap_root = Path(arguments.bootstrap_root)
    require_private_root(bootstrap_root)
    if not (source_root.is_absolute() and source_root.resolve() == source_root):
        raise BootstrapError("caller source root is not canonical")
    require_source_directory(source_root)
    for name, expected in ((GUILE, GUILE_SHA256), (PYTHON, PYTHON_SHA256)):
        info = os.lstat(name)
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
                stat.S_IMODE(info.st_mode) & 0o222 == 0 and
                digest_file(name) == expected):
            raise BootstrapError(f"pinned bootstrap interpreter differs: {name}")
    for name, label in ((GCRYPT, "Guile-gcrypt"),
                        (GUIX_MODULES, "Guix module")):
        closure_info = os.lstat(name)
        if not (stat.S_ISDIR(closure_info.st_mode) and
                closure_info.st_uid == 0 and
                stat.S_IMODE(closure_info.st_mode) & 0o222 == 0):
            raise BootstrapError(f"pinned {label} closure differs")

    map_path = source_root / "RUNTIME-SOURCE-MANIFEST.sha256"
    map_fd, map_opened = open_source(map_path)
    try:
        map_data = read_stable(map_fd, map_opened, map_path)
    finally:
        os.close(map_fd)
    if digest_bytes(map_data) != EXPECTED_RUNTIME_MANIFEST_SHA256:
        raise BootstrapError("runtime source map is not the reviewed bootstrap map")
    entries = parse_manifest(map_data)

    destination = bootstrap_root / "source"
    destination.mkdir(mode=0o700)
    for relative, expected in entries:
        copy_entry(source_root, destination, relative, expected)
    retained_manifest = write_retained_manifest(destination, map_data)
    assert_inventory(destination, entries)
    seal_private_directories(destination)

    ready_fd = arguments.test_before_exec_ready_fd
    continue_fd = arguments.test_before_exec_continue_fd
    if (ready_fd is None) != (continue_fd is None):
        raise BootstrapError("test-only mutation handshake requires both descriptors")
    if ready_fd is not None:
        os.write(ready_fd, b"retained-source-ready\n")
        os.close(ready_fd)
        if os.read(continue_fd, 1) != b"C":
            raise BootstrapError("test-only mutation handshake was not continued")
        os.close(continue_fd)

    for directory in ("home", "cache", "config", "data", "state", "tmp",
                      "runtime", "empty-path"):
        path = bootstrap_root / directory
        if not path.is_dir():
            path.mkdir(mode=0o700)
        path.chmod(0o700)

    environment = {
        "HOME": str(bootstrap_root / "home"),
        "XDG_CACHE_HOME": str(bootstrap_root / "cache"),
        "XDG_CONFIG_HOME": str(bootstrap_root / "config"),
        "XDG_DATA_HOME": str(bootstrap_root / "data"),
        "XDG_STATE_HOME": str(bootstrap_root / "state"),
        "XDG_RUNTIME_DIR": str(bootstrap_root / "runtime"),
        "TMPDIR": str(bootstrap_root / "tmp"),
        "PATH": str(bootstrap_root / "empty-path"),
        "LANG": "C",
        "LC_ALL": "C",
        "GUILE_AUTO_COMPILE": "0",
        "GUILE_LOAD_PATH": (
            f"{GCRYPT}/share/guile/site/3.0:"
            f"{GUIX_MODULES}/share/guile/site/3.0"
        ),
        "GUILE_LOAD_COMPILED_PATH": (
            f"{GCRYPT}/lib/guile/3.0/site-ccache:"
            f"{GUIX_MODULES}/lib/guile/3.0/site-ccache"
        ),
        "GUILE_EXTENSIONS_PATH": "",
    }
    entry = destination / "bootstrap-main.scm"
    command = [
        GUILE, "--no-auto-compile", "-L", str(destination / "modules"),
        str(entry), "--bootstrap-root", str(bootstrap_root),
        "--source-root", str(destination),
        "--source-manifest-sha256", retained_manifest,
        "--", *arguments.campaign,
    ]
    close_unrelated_descriptors()
    os.execve(GUILE, command, environment)


def main(argv: list[str]) -> int:
    try:
        run(parse_arguments(argv))
    except (BootstrapError, OSError) as error:
        print(f"TWO_BOOT_BOOTSTRAP_FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
