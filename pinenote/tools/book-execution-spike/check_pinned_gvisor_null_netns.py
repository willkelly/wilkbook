#!/usr/bin/env python3
"""Read-only check of pinned runsc null-gofer-netns creation and cleanup."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys


COMMIT = "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
FILES = {
    "runsc/config/flags.go": "1a269e91665d022fa4cc4075b9b9c991735351a4e6beb4ab4a7a5b2c5983af50",
    "runsc/config/config.go": "ad760a4e98f24d6783dc4da72c6c02bd6794f71b8b4dc72ed48267b414e9cf1c",
    "runsc/container/null_netns.go": "eb799eee1c58618c36ef7235e3173a86ea0cbcee71bf37d2bbde7aa04cc86868",
    "runsc/specutils/namespace.go": "39d13e8fcf84f0f00312af24f0ec10b70664fdeb241ffec99ea52700924f8832",
    "runsc/container/container.go": "2cd847cc190722fb16ac35d313ee1cb0c12f9f3050d8e36a9580bff9b690efd4",
    "runsc/container/state_file.go": "7c4fba71aad13e7aadeb0cdc0baca9df707ffe8cd41463295e5b93b98eb1f8ba",
    "runsc/sandbox/sandbox.go": "5bb26b649bbe2bbfd5c61de1cbbadb4eb537ff5d5e6b610bac2e9dd11979198e",
}


def check(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} PINNED_GVISOR_CHECKOUT")
    root = Path(sys.argv[1]).resolve()
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    status = subprocess.run(
        ["git", "status", "--short"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    check(head == COMMIT, f"checkout HEAD is {head}, expected {COMMIT}")
    check(status == "", "pinned checkout is not clean")
    for relative, expected in FILES.items():
        check(sha256(root / relative) == expected, f"source changed: {relative}")

    flags = (root / "runsc/config/flags.go").read_text(encoding="utf-8")
    config = (root / "runsc/config/config.go").read_text(encoding="utf-8")
    null_netns = (root / "runsc/container/null_netns.go").read_text(
        encoding="utf-8"
    )
    namespace = (root / "runsc/specutils/namespace.go").read_text(encoding="utf-8")
    container = (root / "runsc/container/container.go").read_text(encoding="utf-8")
    state_file = (root / "runsc/container/state_file.go").read_text(encoding="utf-8")
    sandbox = (root / "runsc/sandbox/sandbox.go").read_text(encoding="utf-8")

    check(
        "goferNetworkNamespacePtr(GoferNetworkNamespaceNull)" in flags,
        "gofer network namespace no longer defaults to null",
    )
    check(
        "if c.SharedRootDir != \"\"" in config and "return c.RootDir" in config,
        "empty shared root no longer resolves to runtime root",
    )
    check(
        'const NullNetNSFilename = "null-netns"' in namespace,
        "shared null network namespace filename changed",
    )
    check(
        "os.OpenFile(path, os.O_RDONLY|os.O_CREATE, 0444)" in null_netns
        and 'fmt.Sprintf("/proc/%d/ns/net", pid)' in null_netns
        and "unix.MS_BIND" in null_netns,
        "null network namespace placeholder or bind-mount sequence changed",
    )
    check(
        "st.Type != unix.NSFS_MAGIC" in null_netns
        and "unix.NS_GET_NSTYPE" in null_netns
        and "nsType != unix.CLONE_NEWNET" in null_netns,
        "pinned null network namespace identity checks changed",
    )
    check(
        "if err := pinNullNetNS(conf, cmd.Process.Pid)" in container,
        "first null-network gofer no longer pins its new namespace",
    )
    check(
        "c.Saver.Destroy()" in container
        and "os.Remove(s.statePath())" in state_file
        and "os.Remove(s.lockPath())" in state_file,
        "ordinary container metadata cleanup changed",
    )
    check(
        "os.Remove(controlSocketPath)" in sandbox,
        "ordinary sandbox control-socket cleanup changed",
    )
    check(
        "UnmountNullNetNS" not in container and "UnmountNullNetNS" not in sandbox,
        "ordinary container destruction now owns shared null-netns cleanup",
    )
    check(
        "unix.MNT_DETACH" in namespace,
        "upstream whole-shared-root helper no longer uses lazy detach",
    )
    print("PASS: pinned gVisor null gofer-network namespace lifecycle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
