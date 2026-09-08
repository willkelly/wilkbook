#!/usr/bin/env python3
"""Test-only Python reference for the narrow execution-spike OCI bundle.

The profile, book fixture, bundle destination, Guix executable, and container
ID are trusted operator/preparation inputs.  Nothing here consumes a book
manifest or grants authority requested by book content.  The emitted launcher
is data only during host tests: this module never invokes runsc.  The trusted
generator and launcher are Guile; retain this implementation as an independent
policy oracle during that port, not as runtime-core code.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
from typing import Callable, Iterable, Mapping, Sequence


OCI_VERSION = "1.0.2"
STORE_ROOT = Path("/gnu/store")
STORE_NAME = re.compile(r"^[0-9a-z]{32}-.+$")
NONROOT_ID = 65534
SCRATCH_BYTES = 16 * 1024 * 1024
DEV_BYTES = 1024 * 1024
RUNSC = "/run/current-system/profile/bin/runsc"
ENV = "/run/current-system/profile/bin/env"
ID = "/run/current-system/profile/bin/id"

# Selection is mandatory at the CLI.  The first profile can answer only a
# functional compatibility question on the current kernel.  The second is a
# future isolation candidate and is not runnable on that kernel because it
# requires a separately reviewed CONFIG_USER_NS=y test configuration.
EXECUTION_PROFILES = {
    "functional-directfs": {
        "directfs": True,
        "claim": "functional-only-not-isolation-acceptance",
        "requiredKernelConfig": ["CONFIG_USER_NS=y"],
    },
    "isolation-userns": {
        "directfs": False,
        "claim": "isolation-candidate-not-yet-accepted",
        "requiredKernelConfig": ["CONFIG_USER_NS=y"],
    },
}

# Upstream release-20260831.0 still allows embedded helper fallback under its
# DEFAULT policy, and GVISOR_ENFORCE_RELEASE=SKIP bypasses release matching.
# Pin all reviewed choices and invoke runsc with a clean environment below.
PINNED_RUNTIME_FLAGS = (
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
)

# Fixed diagnostics for the compatibility fixture only.  They are trusted
# generator policy and are never accepted from book data.  Private path flags
# are added from the already validated bundle path in make_launch_argv().
DIAGNOSTIC_RUNTIME_FLAGS = (
    "--debug=true",
    "--debug-log-format=text",
    "--alsologtostderr=true",
)

SUPERVISOR_ENV = (
    "HOME=/nonexistent",
    "LANG=C",
    "LC_ALL=C",
    "PATH=/run/current-system/profile/bin",
)

# This is a guest compatibility probe, not the Book Protocol.  It emits one
# exact fixed-fixture diagnostic sentinel on stdout.  A future broker uses a
# private inherited descriptor owned by the protocol work instead.
PYTHON_SMOKE = r"""from pathlib import Path
import socket

book = Path("/book/input")
data = book.read_bytes()
Path("/scratch/book-size").write_text(str(len(data)), encoding="ascii")

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect(("192.0.2.1", 9))
except OSError:
    pass
else:
    sock.close()
    raise SystemExit("external network unexpectedly reachable")
finally:
    sock.close()

print(f"BOOKEXEC-PAYLOAD-PYTHON book-bytes={len(data)}", flush=True)
"""


class BundleError(ValueError):
    """A trusted preparation input or generated invariant is invalid."""


def _lexical_absolute(raw: str, label: str) -> Path:
    if not raw.startswith("/"):
        raise BundleError(f"{label} must be absolute: {raw!r}")
    if "\x00" in raw or "\n" in raw or "\r" in raw:
        raise BundleError(f"{label} contains a forbidden control character")
    parts = raw.split("/")
    if any(part in ("", ".", "..") for part in parts[1:]):
        raise BundleError(
            f"{label} must be lexical and traversal-free (no //, . or ..): {raw!r}"
        )
    return Path(raw)


def _canonical_existing(
    raw: str, label: str, *, allow_input_symlink: bool
) -> Path:
    path = _lexical_absolute(raw, label)
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise BundleError(f"{label} cannot be resolved safely: {raw}") from error
    if not allow_input_symlink and resolved != path:
        raise BundleError(f"{label} must not contain a symlink: {raw}")
    return resolved


def _canonical_store_root(store_root: Path) -> Path:
    raw = str(store_root)
    resolved = _canonical_existing(raw, "Guix store root", allow_input_symlink=False)
    if not resolved.is_dir():
        raise BundleError(f"Guix store root is not a directory: {resolved}")
    return resolved


def _store_item(path: Path, store_root: Path, label: str) -> Path:
    try:
        relative = path.relative_to(store_root)
    except ValueError as error:
        raise BundleError(f"{label} is outside {store_root}: {path}") from error
    if not relative.parts:
        raise BundleError(f"{label} names the whole Guix store")
    name = relative.parts[0]
    if not STORE_NAME.fullmatch(name):
        raise BundleError(f"{label} has an invalid Guix store item name: {name!r}")
    return store_root / name


def validate_profile(raw: str, store_root: Path) -> Path:
    # A Guix profile is normally reached through one or more legitimate
    # symlinks (/etc/.../profile -> store profile).  Resolve that chain, but
    # require its final object to be one real top-level store directory.
    profile = _canonical_existing(raw, "profile", allow_input_symlink=True)
    item = _store_item(profile, store_root, "profile")
    if profile != item:
        raise BundleError(f"profile must resolve to a top-level store item: {profile}")
    if not stat.S_ISDIR(profile.lstat().st_mode):
        raise BundleError(f"profile store item is not a real directory: {profile}")
    # Guix profile output names are caller-selected.  Validate the selected
    # object and profile structure rather than treating "-profile" as authority.
    manifest = profile / "manifest"
    try:
        manifest_mode = manifest.lstat().st_mode
    except FileNotFoundError as error:
        raise BundleError(
            f"profile manifest is not a real regular: {manifest}"
        ) from error
    if not stat.S_ISREG(manifest_mode):
        raise BundleError(f"profile manifest is not a real regular: {manifest}")
    return profile


def validate_requisites(
    raw_paths: Iterable[str], profile: Path, store_root: Path
) -> tuple[Path, ...]:
    paths: list[Path] = []
    seen: set[Path] = set()
    for index, raw in enumerate(raw_paths, start=1):
        if not raw:
            raise BundleError(f"empty Guix requisite at line {index}")
        requisite = _canonical_existing(
            raw, f"Guix requisite line {index}", allow_input_symlink=False
        )
        item = _store_item(requisite, store_root, f"Guix requisite line {index}")
        if requisite != item:
            raise BundleError(
                f"Guix requisite must be one top-level store item: {requisite}"
            )
        mode = requisite.lstat().st_mode
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise BundleError(f"Guix requisite has unsupported type: {requisite}")
        if requisite in seen:
            raise BundleError(f"duplicate Guix requisite: {requisite}")
        seen.add(requisite)
        paths.append(requisite)
    if profile not in seen:
        raise BundleError("Guix requisites do not contain the selected profile")
    return tuple(sorted(paths, key=str))


def validate_book(raw: str, closure: Sequence[Path], store_root: Path) -> Path:
    # Unlike the profile alias, every component of the selected fixture path
    # must already be canonical.  This rejects a book-controlled symlink that
    # resolves somewhere broader than the operator selected.
    book = _canonical_existing(raw, "book fixture", allow_input_symlink=False)
    item = _store_item(book, store_root, "book fixture")
    if not stat.S_ISREG(book.lstat().st_mode):
        raise BundleError(f"book fixture is not a regular file: {book}")
    if item in closure:
        raise BundleError(
            "book fixture belongs to the language closure; select a separate "
            "immutable store item so only the chosen file is exposed"
        )
    return book


def validate_profile_entry(
    profile: Path, closure: Sequence[Path], store_root: Path, name: str
) -> None:
    relative = f"bin/{name}"
    entry = profile / relative
    try:
        resolved = entry.resolve(strict=True)
    except FileNotFoundError as error:
        raise BundleError(f"profile has no {relative}: {profile}") from error
    item = _store_item(resolved, store_root, f"profile {name}")
    if item not in closure:
        raise BundleError(f"profile {name} resolves outside the enumerated closure")
    if not stat.S_ISREG(resolved.lstat().st_mode) or not os.access(resolved, os.X_OK):
        raise BundleError(f"profile {name} target is not executable: {resolved}")


def run_guix_requisites(guix: Path, profile: Path) -> list[str]:
    result = subprocess.run(
        [str(guix), "gc", "--requisites", str(profile)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={
            "HOME": "/nonexistent",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/run/current-system/profile/bin:/usr/bin:/bin",
        },
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise BundleError(f"guix gc --requisites failed: {detail}")
    return result.stdout.splitlines()


def validate_guix(raw: str, store_root: Path) -> Path:
    guix = _canonical_existing(raw, "guix executable", allow_input_symlink=True)
    _store_item(guix, store_root, "guix executable")
    if not stat.S_ISREG(guix.lstat().st_mode) or not os.access(guix, os.X_OK):
        raise BundleError(f"guix target is not executable: {guix}")
    return guix


def _container_store_path(item: Path) -> str:
    return f"/gnu/store/{item.name}"


def _bind_mount(source: Path, destination: str, *, noexec: bool = False) -> dict:
    options = ["bind", "ro", "nosuid", "nodev"]
    if noexec:
        options.append("noexec")
    return {
        "destination": destination,
        "type": "bind",
        "source": str(source),
        "options": options,
    }


def make_spec(
    profile: Path, closure: Sequence[Path], book: Path, container_id: str
) -> dict:
    mounts = [
        {
            "destination": "/proc",
            "type": "proc",
            "source": "proc",
            "options": ["nosuid", "noexec", "nodev"],
        },
        {
            "destination": "/dev",
            "type": "tmpfs",
            "source": "tmpfs",
            "options": [
                "nosuid",
                "noexec",
                "strictatime",
                "mode=755",
                f"size={DEV_BYTES}",
            ],
        },
        {
            "destination": "/scratch",
            "type": "tmpfs",
            "source": "tmpfs",
            "options": [
                "nosuid",
                "nodev",
                "noexec",
                "mode=1777",
                f"size={SCRATCH_BYTES}",
            ],
        },
    ]
    mounts.extend(
        _bind_mount(item, _container_store_path(item)) for item in closure
    )
    mounts.append(_bind_mount(book, "/book/input", noexec=True))

    empty_capabilities = {
        "ambient": [],
        "bounding": [],
        "effective": [],
        "inheritable": [],
        "permitted": [],
    }
    return {
        "ociVersion": OCI_VERSION,
        "root": {"path": "rootfs", "readonly": True},
        "hostname": "wilkbook-execution-spike",
        "process": {
            "terminal": False,
            "user": {
                "uid": NONROOT_ID,
                "gid": NONROOT_ID,
                "additionalGids": [],
                "umask": 0o077,
            },
            "args": ["/profile/bin/python3", "-I", "-c", PYTHON_SMOKE],
            "env": [
                "HOME=/scratch",
                "LANG=C.UTF-8",
                "LC_ALL=C.UTF-8",
                "PATH=/profile/bin",
                "PYTHONNOUSERSITE=1",
                "TMPDIR=/scratch",
            ],
            "cwd": "/scratch",
            "capabilities": empty_capabilities,
            "noNewPrivileges": True,
            "rlimits": [
                {"type": "RLIMIT_CORE", "hard": 0, "soft": 0},
                {"type": "RLIMIT_FSIZE", "hard": 1048576, "soft": 1048576},
                {"type": "RLIMIT_NOFILE", "hard": 64, "soft": 64},
            ],
        },
        "mounts": mounts,
        "linux": {
            "cgroupsPath": f"/wilkbook-execution-{container_id}",
            "namespaces": [
                {"type": "pid"},
                {"type": "network"},
                {"type": "ipc"},
                {"type": "uts"},
                {"type": "mount"},
            ],
            "maskedPaths": [
                "/proc/acpi",
                "/proc/asound",
                "/proc/kcore",
                "/proc/keys",
                "/proc/latency_stats",
                "/proc/sched_debug",
                "/proc/timer_list",
                "/proc/timer_stats",
                "/sys/firmware",
            ],
            "readonlyPaths": [
                "/proc/bus",
                "/proc/fs",
                "/proc/irq",
                "/proc/sys",
                "/proc/sysrq-trigger",
            ],
        },
    }


def make_launch_argv(
    bundle: Path, container_id: str, execution_profile: str
) -> list[str]:
    profile = EXECUTION_PROFILES[execution_profile]
    runtime_root = bundle / "runsc-state"
    return [
        RUNSC,
        f"--root={runtime_root}",
        *DIAGNOSTIC_RUNTIME_FLAGS,
        f"--debug-log={bundle / 'runsc-debug'}/",
        f"--panic-log={bundle / 'runsc-panic' / 'runsc.panic.%COMMAND%.log'}",
        *PINNED_RUNTIME_FLAGS,
        f"--directfs={str(profile['directfs']).lower()}",
        "run",
        f"--bundle={bundle}",
        container_id,
    ]


def make_launch_record(
    bundle: Path, container_id: str, execution_profile: str
) -> dict:
    policy: Mapping[str, object] = EXECUTION_PROFILES[execution_profile]
    supervisor_env = [*SUPERVISOR_ENV, f"TMPDIR={bundle / 'supervisor-tmp'}"]
    return {
        "argv": make_launch_argv(bundle, container_id, execution_profile),
        "cgroupsPath": f"/wilkbook-execution-{container_id}",
        "claim": policy["claim"],
        "executionProfile": execution_profile,
        "requiredKernelConfig": policy["requiredKernelConfig"],
        "supervisorEnv": supervisor_env,
        "supervisorUid": 0,
    }


def _make_rootfs(
    rootfs: Path, profile: Path, closure: Sequence[Path]
) -> None:
    rootfs.mkdir(mode=0o755)
    for relative in ("gnu", "gnu/store", "book", "proc", "dev", "scratch"):
        destination = rootfs / relative
        destination.mkdir(mode=0o755)

    for item in closure:
        destination = rootfs / _container_store_path(item).lstrip("/")
        if stat.S_ISDIR(item.lstat().st_mode):
            destination.mkdir(mode=0o555)
        else:
            destination.touch(mode=0o444)

    (rootfs / "book/input").touch(mode=0o444)
    (rootfs / "profile").symlink_to(_container_store_path(profile))


def _validate_container_id(container_id: str) -> None:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", container_id):
        raise BundleError(
            "container ID must be 1..64 lowercase ASCII letters, digits, '.', '_' "
            "or '-', starting with a letter or digit"
        )


def _validate_bundle_destination(raw: str, store_root: Path) -> Path:
    bundle = _lexical_absolute(raw, "bundle destination")
    if bundle.exists() or bundle.is_symlink():
        raise BundleError(f"bundle destination already exists: {bundle}")
    parent = bundle.parent
    try:
        resolved_parent = parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise BundleError(f"bundle parent does not exist: {parent}") from error
    if resolved_parent != parent:
        raise BundleError(f"bundle parent must not contain a symlink: {parent}")
    if not parent.is_dir():
        raise BundleError(f"bundle parent is not a directory: {parent}")
    try:
        bundle.relative_to(store_root)
    except ValueError:
        pass
    else:
        raise BundleError("bundle destination must not be inside the Guix store")
    return bundle


def generate_bundle(
    *,
    profile_input: str,
    book_input: str,
    bundle_input: str,
    container_id: str,
    execution_profile: str,
    requisites_runner: Callable[[Path], Iterable[str]],
    store_root: Path = STORE_ROOT,
) -> Path:
    store = _canonical_store_root(store_root)
    profile = validate_profile(profile_input, store)
    closure = validate_requisites(requisites_runner(profile), profile, store)
    book = validate_book(book_input, closure, store)
    validate_profile_entry(profile, closure, store, "python3")
    validate_profile_entry(profile, closure, store, "guile")
    _validate_container_id(container_id)
    if execution_profile not in EXECUTION_PROFILES:
        raise BundleError(f"unknown execution profile: {execution_profile!r}")
    bundle = _validate_bundle_destination(bundle_input, store)

    # mkdir is the atomic no-overwrite claim.  Clean up only the directory this
    # invocation created; never replace or recursively remove an operator path.
    bundle.mkdir(mode=0o700)
    try:
        rootfs = bundle / "rootfs"
        _make_rootfs(rootfs, profile, closure)
        (bundle / "runsc-state").mkdir(mode=0o700)
        (bundle / "supervisor-tmp").mkdir(mode=0o700)
        (bundle / "runsc-debug").mkdir(mode=0o700)
        (bundle / "runsc-panic").mkdir(mode=0o700)
        spec = make_spec(profile, closure, book, container_id)
        config = bundle / "config.json"
        config.write_text(
            json.dumps(spec, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        config.chmod(0o600)

        launch_record = make_launch_record(
            bundle, container_id, execution_profile
        )
        argv = launch_record["argv"]
        launch = bundle / "launch.json"
        launch.write_text(
            json.dumps(launch_record, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        launch.chmod(0o600)

        script = bundle / "run.sh"
        script.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "umask 077\n"
            f"if [ \"$({shlex.quote(ID)} -u)\" -ne 0 ]; then\n"
            "  echo 'execution spike requires guest-root runsc supervisor' >&2\n"
            "  exit 1\n"
            "fi\n"
            f"exec {shlex.quote(ENV)} -i "
            f"{shlex.join(launch_record['supervisorEnv'])} "
            f"{shlex.join(argv)}\n",
            encoding="utf-8",
        )
        script.chmod(0o500)
    except BaseException:
        shutil.rmtree(bundle)
        raise
    return bundle


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="generate the fixed-policy OCI bundle for the QEMU execution spike"
    )
    parser.add_argument(
        "--profile",
        required=True,
        help="trusted Guix profile path (a symlink chain into /gnu/store is allowed)",
    )
    parser.add_argument(
        "--book",
        required=True,
        help="trusted, canonical regular-file fixture under a separate store item",
    )
    parser.add_argument(
        "--bundle", required=True, help="new absolute bundle directory to create"
    )
    parser.add_argument(
        "--container-id", default="wilkbook-python-smoke", help="fixed runsc ID"
    )
    parser.add_argument(
        "--execution-profile",
        required=True,
        choices=sorted(EXECUTION_PROFILES),
        help=(
            "explicit runtime profile; both require a reviewed CONFIG_USER_NS=y "
            "test kernel, and functional-directfs is functional-only"
        ),
    )
    parser.add_argument(
        "--guix",
        help="trusted guix executable; defaults to the guix found on PATH",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    guix_input = args.guix or shutil.which("guix")
    if not guix_input:
        print("FAIL: guix not found; pass an absolute trusted --guix path", file=sys.stderr)
        return 2
    try:
        store = _canonical_store_root(STORE_ROOT)
        guix = validate_guix(guix_input, store)
        bundle = generate_bundle(
            profile_input=args.profile,
            book_input=args.book,
            bundle_input=args.bundle,
            container_id=args.container_id,
            execution_profile=args.execution_profile,
            requisites_runner=lambda profile: run_guix_requisites(guix, profile),
            store_root=store,
        )
    except (BundleError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(bundle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
