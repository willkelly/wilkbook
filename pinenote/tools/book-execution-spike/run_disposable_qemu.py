#!/usr/bin/env python3
"""Test-only Python reference for the disposable QEMU envelope.

This owns only the outer VM process and its private host artifacts.  It does
not log in, launch runsc, inspect guest output, or claim guest success.  The
trusted implementation is now Guile (`run-disposable-qemu.scm`); retain this
reviewed implementation only as a host-test oracle during the port.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Mapping, Sequence


DEFAULT_RUN_BASE = Path("/tmp/opencode")
DEFAULT_TIMEOUT_SECONDS = 600.0
DEFAULT_TERM_GRACE_SECONDS = 5.0
MAX_TIMEOUT_SECONDS = 1800.0
MAX_TERM_GRACE_SECONDS = 30.0
PREPARATION_TIMEOUT_SECONDS = 60.0
COPY_CHUNK_BYTES = 1024 * 1024
FICLONE = 0x40049409
SHA256 = re.compile(r"^[0-9a-f]{64}$")
STORE_SYSTEM = re.compile(r"^/gnu/store/[0-9a-z]{32}-.+-system$")


class RunnerError(RuntimeError):
    """A trusted input, preparation step, or owned process failed."""


class RunnerSignal(BaseException):
    """A termination signal received by the foreground owner."""

    def __init__(self, signum: int):
        self.signum = signum
        super().__init__(f"received signal {signum}")


@dataclass(frozen=True)
class BootInputs:
    bundle: Path
    kernel: Path
    initrd: Path
    config: Path
    append: str


def _lexical_absolute(raw: str, label: str) -> Path:
    if not raw.startswith("/"):
        raise RunnerError(f"{label} must be absolute: {raw!r}")
    if any(character in raw for character in ("\x00", "\n", "\r")):
        raise RunnerError(f"{label} contains a forbidden control character")
    if any(part in ("", ".", "..") for part in raw.split("/")[1:]):
        raise RunnerError(
            f"{label} must be lexical and traversal-free (no //, . or ..): {raw!r}"
        )
    return Path(raw)


def _canonical_existing(raw: str, label: str, *, allow_symlink: bool) -> Path:
    path = _lexical_absolute(raw, label)
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise RunnerError(f"{label} cannot be resolved safely: {raw}") from error
    if not allow_symlink and resolved != path:
        raise RunnerError(f"{label} must not contain a symlink: {raw}")
    return resolved


def _require_real_directory(path: Path, label: str) -> None:
    mode = path.lstat().st_mode
    if not stat.S_ISDIR(mode):
        raise RunnerError(f"{label} is not a real directory: {path}")


def _require_fixed_file(path: Path, label: str, *, unique_inode: bool) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise RunnerError(f"{label} is not a regular file: {path}")
    if info.st_mode & 0o222:
        raise RunnerError(
            f"{label} must have all write bits removed before use: {path}"
        )
    if unique_inode and info.st_nlink != 1:
        raise RunnerError(f"{label} must not have hard-link aliases: {path}")


def _extract_append(config: Path) -> str:
    if config.stat().st_size > 1024 * 1024:
        raise RunnerError("extlinux.conf exceeds the 1 MiB preparation limit")
    try:
        text = config.read_text(encoding="utf-8")
    except UnicodeError as error:
        raise RunnerError("extlinux.conf is not UTF-8") from error
    append_lines = []
    for line in text.splitlines():
        match = re.match(r"^\s*APPEND\s+(.+?)\s*$", line)
        if match:
            append_lines.append(match.group(1))
    if len(append_lines) != 1:
        raise RunnerError("extlinux.conf must contain exactly one APPEND line")

    tokens = append_lines[0].split()
    if tokens.count("root=PNGuixRoot") != 1:
        raise RunnerError("APPEND must contain exactly one root=PNGuixRoot")
    systems = [token.removeprefix("gnu.system=") for token in tokens
               if token.startswith("gnu.system=")]
    loads = [token.removeprefix("gnu.load=") for token in tokens
             if token.startswith("gnu.load=")]
    if len(systems) != 1 or not STORE_SYSTEM.fullmatch(systems[0]):
        raise RunnerError("APPEND must contain one canonical Guix gnu.system path")
    if loads != [systems[0] + "/boot"]:
        raise RunnerError("APPEND gnu.load must be the selected gnu.system /boot")
    if tokens.count("console=ttyS2,1500000n8") != 1:
        raise RunnerError("APPEND must contain the PineNote hardware console once")
    if "console=ttyAMA0" in tokens:
        raise RunnerError("APPEND already contains the QEMU console")

    transformed = []
    for token in tokens:
        if token == "console=tty0":
            continue
        if token == "console=ttyS2,1500000n8":
            transformed.append("console=ttyAMA0")
        else:
            transformed.append(token)
    return " ".join(transformed)


def validate_boot_bundle(raw: str) -> BootInputs:
    bundle = _canonical_existing(raw, "boot bundle", allow_symlink=False)
    _require_real_directory(bundle, "boot bundle")
    extlinux = bundle / "extlinux"
    if extlinux.resolve(strict=True) != extlinux:
        raise RunnerError(f"boot bundle extlinux path contains a symlink: {extlinux}")
    _require_real_directory(extlinux, "boot bundle extlinux directory")

    files = {
        "kernel": extlinux / "Image",
        "initrd": extlinux / "initrd.cpio.gz",
        "config": extlinux / "extlinux.conf",
    }
    for label, path in files.items():
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise RunnerError(f"boot bundle {label} is missing: {path}") from error
        if resolved != path:
            raise RunnerError(f"boot bundle {label} contains a symlink: {path}")
        _require_fixed_file(path, f"boot bundle {label}", unique_inode=True)

    return BootInputs(
        bundle=bundle,
        kernel=files["kernel"],
        initrd=files["initrd"],
        config=files["config"],
        append=_extract_append(files["config"]),
    )


def validate_baseline(raw: str, expected_sha256: str) -> Path:
    if not SHA256.fullmatch(expected_sha256):
        raise RunnerError("baseline SHA-256 must be 64 lowercase hexadecimal digits")
    baseline = _canonical_existing(raw, "baseline", allow_symlink=False)
    _require_fixed_file(baseline, "baseline", unique_inode=True)
    if baseline.stat().st_size == 0:
        raise RunnerError("baseline must not be empty")
    return baseline


def resolve_executable(raw: str | None, name: str) -> Path:
    candidate = raw or shutil.which(name)
    if not candidate:
        raise RunnerError(f"{name} not found; enter a cached 'guix shell qemu --' environment")
    executable = _canonical_existing(candidate, name, allow_symlink=True)
    if not stat.S_ISREG(executable.lstat().st_mode) or not os.access(executable, os.X_OK):
        raise RunnerError(f"{name} target is not executable: {executable}")
    return executable


def validate_run_base(raw: str) -> Path:
    run_base = _canonical_existing(raw, "run base", allow_symlink=False)
    _require_real_directory(run_base, "run base")
    if "," in str(run_base):
        raise RunnerError("run base must not contain ',' (QEMU chardev delimiter)")
    return run_base


def _copy_sparse(source_fd: int, destination_fd: int, size: int) -> None:
    def copy_range(start: int, end: int) -> None:
        offset = start
        while offset < end:
            data = os.pread(source_fd, min(COPY_CHUNK_BYTES, end - offset), offset)
            if not data:
                raise RunnerError("source became short while making private snapshot")
            written = 0
            while written < len(data):
                count = os.pwrite(destination_fd, data[written:], offset + written)
                if count <= 0:
                    raise RunnerError("short write while making private snapshot")
                written += count
            offset += len(data)

    try:
        position = 0
        while position < size:
            try:
                data_start = os.lseek(source_fd, position, os.SEEK_DATA)
            except OSError as error:
                if error.errno == errno.ENXIO:
                    break
                if error.errno in (errno.EINVAL, errno.ENOTSUP, errno.ENOSYS):
                    raise NotImplementedError from error
                raise
            hole_start = os.lseek(source_fd, data_start, os.SEEK_HOLE)
            copy_range(data_start, min(hole_start, size))
            position = hole_start
    except (AttributeError, NotImplementedError):
        os.ftruncate(destination_fd, 0)
        copy_range(0, size)
    os.ftruncate(destination_fd, size)


def private_snapshot(source: Path, destination: Path) -> str:
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    destination_fd = -1
    try:
        before = os.fstat(source_fd)
        current = source.lstat()
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise RunnerError(f"source identity changed before snapshot: {source}")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o400,
        )
        try:
            fcntl.ioctl(destination_fd, FICLONE, source_fd)
        except OSError as error:
            if error.errno not in (
                errno.EXDEV,
                errno.EINVAL,
                errno.ENOTTY,
                errno.EOPNOTSUPP,
            ):
                raise
            _copy_sparse(source_fd, destination_fd, before.st_size)
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        fields_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        fields_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if fields_before != fields_after:
            raise RunnerError(f"source changed while making private snapshot: {source}")
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        os.close(source_fd)

    os.chmod(destination, 0o400, follow_symlinks=False)
    digest = hashlib.sha256()
    with destination.open("rb") as port:
        while block := port.read(COPY_CHUNK_BYTES):
            digest.update(block)
    return digest.hexdigest()


def make_supervisor_environment(run_root: Path, executable: Path) -> dict[str, str]:
    environment = {
        "HOME": str(run_root / "home"),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": str(executable.parent),
        "TMPDIR": str(run_root / "tmp"),
        "XDG_CACHE_HOME": str(run_root / "xdg-cache"),
        "XDG_CONFIG_HOME": str(run_root / "xdg-config"),
        "XDG_RUNTIME_DIR": str(run_root / "xdg-runtime"),
    }
    for variable in ("home", "tmp", "xdg-cache", "xdg-config", "xdg-runtime"):
        (run_root / variable).mkdir(mode=0o700)
    return environment


def make_qemu_img_argv(qemu_img: Path, baseline: Path, overlay: Path) -> list[str]:
    return [
        str(qemu_img),
        "create",
        "-q",
        "-f",
        "qcow2",
        "-F",
        "raw",
        "-b",
        str(baseline),
        str(overlay),
    ]


def make_qemu_argv(
    qemu: Path,
    run_root: Path,
    kernel: Path,
    initrd: Path,
    append: str,
    overlay: Path,
) -> list[str]:
    console_socket = run_root / "console.sock"
    console_log = run_root / "console.log"
    overlay_file = json.dumps(
        {
            "driver": "file",
            "filename": str(overlay),
            "node-name": "rootfs-overlay-file",
            "read-only": False,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    overlay_format = json.dumps(
        {
            "driver": "qcow2",
            "file": "rootfs-overlay-file",
            "node-name": "rootfs-overlay",
            "read-only": False,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    return [
        str(qemu),
        "-no-user-config",
        "-nodefaults",
        "-M",
        "virt",
        "-accel",
        "tcg,thread=multi",
        "-cpu",
        "max",
        "-smp",
        "4",
        "-m",
        "2048",
        "-display",
        "none",
        "-no-reboot",
        "-nic",
        "none",
        "-monitor",
        "none",
        "-chardev",
        (
            "socket,id=console0,"
            f"path={console_socket},server=on,wait=off,"
            f"logfile={console_log},logappend=off"
        ),
        "-serial",
        "chardev:console0",
        "-kernel",
        str(kernel),
        "-initrd",
        str(initrd),
        "-append",
        append,
        "-blockdev",
        overlay_file,
        "-blockdev",
        overlay_format,
        "-device",
        "virtio-blk-pci,drive=rootfs-overlay",
    ]


def _group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_group_gone(process_group: int, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while _group_exists(process_group):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def terminate_owned_group(process: subprocess.Popen[bytes], grace: float) -> None:
    process_group = process.pid
    if _group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGTERM)
        except ProcessLookupError:
            pass
        _wait_group_gone(process_group, grace)
    if _group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=max(grace, 0.2))
    except subprocess.TimeoutExpired:
        pass
    if not _wait_group_gone(process_group, max(grace, 1.0)):
        raise RunnerError(f"owned process group {process_group} survived SIGKILL")


def run_owned_process(
    argv: Sequence[str],
    *,
    environment: Mapping[str, str],
    cwd: Path,
    stdout_path: Path,
    stderr_path: Path,
    timeout: float,
    term_grace: float,
) -> tuple[int, bool]:
    with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            cwd=cwd,
            env=dict(environment),
            start_new_session=True,
            close_fds=True,
        )
        timed_out = False
        try:
            try:
                return_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                return_code = 124
        finally:
            terminate_owned_group(process, term_grace)
    return return_code, timed_out


def _read_failure(path: Path) -> str:
    try:
        data = path.read_bytes()[:4096]
    except OSError:
        return ""
    return data.decode("utf-8", errors="replace").strip()


def _validate_limit(value: float, label: str, maximum: float) -> float:
    if not (value > 0.0 and value <= maximum):
        raise RunnerError(f"{label} must be > 0 and <= {maximum:g} seconds")
    return value


def _cleanup_run_root(run_root: Path, identity: tuple[int, int]) -> None:
    try:
        current = run_root.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != identity:
        raise RunnerError(f"refusing to clean replaced run directory: {run_root}")
    shutil.rmtree(run_root)


def run(args: argparse.Namespace) -> int:
    boot = validate_boot_bundle(args.boot_bundle)
    baseline = validate_baseline(args.baseline, args.baseline_sha256)
    run_base = validate_run_base(args.run_base)
    qemu = resolve_executable(args.qemu, "qemu-system-aarch64")
    qemu_img = resolve_executable(args.qemu_img, "qemu-img")
    if qemu == qemu_img:
        raise RunnerError("qemu-system-aarch64 and qemu-img must be distinct executables")
    timeout = _validate_limit(args.timeout_seconds, "timeout", MAX_TIMEOUT_SECONDS)
    term_grace = _validate_limit(
        args.term_grace_seconds, "TERM grace", MAX_TERM_GRACE_SECONDS
    )

    run_root = Path(tempfile.mkdtemp(prefix="book-execution-qemu.", dir=run_base))
    run_info = run_root.lstat()
    identity = (run_info.st_dev, run_info.st_ino)
    try:
        run_root.chmod(0o700)
        run_info = run_root.lstat()
        if not stat.S_ISDIR(run_info.st_mode) or stat.S_IMODE(run_info.st_mode) != 0o700:
            raise RunnerError(f"private run directory is not mode 0700: {run_root}")
        if run_info.st_uid != os.geteuid():
            raise RunnerError(f"private run directory has the wrong owner: {run_root}")

        private_boot = run_root / "boot"
        private_boot.mkdir(mode=0o700)
        private_kernel = private_boot / "Image"
        private_initrd = private_boot / "initrd.cpio.gz"
        private_config = private_boot / "extlinux.conf"
        private_snapshot(boot.kernel, private_kernel)
        private_snapshot(boot.initrd, private_initrd)
        private_snapshot(boot.config, private_config)
        private_append = _extract_append(private_config)
        if private_append != boot.append:
            raise RunnerError("boot configuration changed while making private copy")

        private_baseline = run_root / "baseline.raw"
        observed_sha256 = private_snapshot(baseline, private_baseline)
        if observed_sha256 != args.baseline_sha256:
            raise RunnerError(
                "private baseline SHA-256 mismatch: "
                f"expected {args.baseline_sha256}, got {observed_sha256}"
            )

        environment = make_supervisor_environment(run_root, qemu)
        overlay = run_root / "disk-overlay.qcow2"
        image_argv = make_qemu_img_argv(qemu_img, private_baseline, overlay)
        image_rc, image_timed_out = run_owned_process(
            image_argv,
            environment=environment,
            cwd=run_root,
            stdout_path=run_root / "qemu-img.stdout",
            stderr_path=run_root / "qemu-img.stderr",
            timeout=PREPARATION_TIMEOUT_SECONDS,
            term_grace=term_grace,
        )
        if image_timed_out:
            raise RunnerError("qemu-img exceeded its 60 second preparation timeout")
        if image_rc != 0:
            detail = _read_failure(run_root / "qemu-img.stderr")
            raise RunnerError(f"qemu-img failed with status {image_rc}: {detail}")
        if overlay.is_symlink() or not overlay.is_file():
            raise RunnerError("qemu-img did not create a regular private overlay")
        overlay.chmod(0o600)

        qemu_argv = make_qemu_argv(
            qemu,
            run_root,
            private_kernel,
            private_initrd,
            private_append,
            overlay,
        )
        qemu_rc, qemu_timed_out = run_owned_process(
            qemu_argv,
            environment=environment,
            cwd=run_root,
            stdout_path=run_root / "qemu.stdout",
            stderr_path=run_root / "qemu.stderr",
            timeout=timeout,
            term_grace=term_grace,
        )
        if qemu_timed_out:
            raise RunnerError(
                f"QEMU reached the {timeout:g} second outer timeout; "
                "guest status was not assessed"
            )
        if qemu_rc != 0:
            detail = _read_failure(run_root / "qemu.stderr")
            raise RunnerError(
                f"QEMU exited with status {qemu_rc}; guest status was not assessed: {detail}"
            )
        print("OUTER-QEMU-EXIT=0; GUEST-ASSERTIONS=NOT-RUN")
        return 0
    finally:
        _cleanup_run_root(run_root, identity)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="run a fixed PineNote boot bundle in a disposable QEMU envelope"
    )
    parser.add_argument("boot_bundle", help="absolute, immutable staged boot bundle")
    parser.add_argument("baseline", help="absolute, immutable dedicated raw disk")
    parser.add_argument("baseline_sha256", help="expected SHA-256 of the raw baseline")
    parser.add_argument(
        "--dedicated-baseline",
        action="store_true",
        required=True,
        help="acknowledge this is a fresh spike-only baseline, not a reader/release disk",
    )
    parser.add_argument("--qemu", help="trusted qemu-system-aarch64 executable")
    parser.add_argument("--qemu-img", help="trusted qemu-img executable")
    parser.add_argument(
        "--run-base", default=str(DEFAULT_RUN_BASE), help="canonical parent for mkdtemp"
    )
    parser.add_argument(
        "--timeout-seconds", type=float, default=DEFAULT_TIMEOUT_SECONDS
    )
    parser.add_argument(
        "--term-grace-seconds", type=float, default=DEFAULT_TERM_GRACE_SECONDS
    )
    return parser.parse_args(argv)


def _raise_signal(signum: int, _frame: object) -> None:
    raise RunnerSignal(signum)


def main(argv: Sequence[str] | None = None) -> int:
    os.umask(0o077)
    args = parse_args(sys.argv[1:] if argv is None else argv)
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, _raise_signal)
    try:
        return run(args)
    except RunnerSignal as error:
        print(f"FAIL: received signal {error.signum}; owned QEMU group cleaned", file=sys.stderr)
        return 128 + error.signum
    except (RunnerError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
