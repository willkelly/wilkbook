#!/usr/bin/env python3
"""Read-only check of the exact pinned gVisor public FD-donation seam."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys


COMMIT = "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
FILES = {
    "runsc/cmd/run.go": "66832e6f90533d94cee4e162e71d0c40aa103fe7be4de92264676c1deaded58a",
    "runsc/cmd/sandboxsetup/fdmappings.go": "e135732811633d0be9e92599d48a5ec4cfc1e5c38ae150ed305cd167e4b79b76",
    "runsc/donation/donation.go": "e035efc442790a5ebf74fc8f4ad3dc525a746b6862e25e159f72c8160ba84eae",
    "runsc/boot/loader.go": "70508976f5b1d52094da8c002dd805fd9f2b8cb02a07ac3037fe8d3b250d7c15",
    "g3doc/user_guide/fuse.md": "35a02bf4059d9559fd1df80b2a688d5abd58ec9f45b04340b8eb0e1d82b9d5e5",
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

    run_source = (root / "runsc/cmd/run.go").read_text(encoding="utf-8")
    mapping_source = (root / "runsc/cmd/sandboxsetup/fdmappings.go").read_text(
        encoding="utf-8"
    )
    donation_source = (root / "runsc/donation/donation.go").read_text(
        encoding="utf-8"
    )
    loader_source = (root / "runsc/boot/loader.go").read_text(encoding="utf-8")
    guide = (root / "g3doc/user_guide/fuse.md").read_text(encoding="utf-8")

    check(
        'f.Var(&r.passFDs, "pass-fd"' in run_source,
        "run command does not register --pass-fd",
    )
    check(
        "fdMap[mapping.Guest] = file" in run_source,
        "run command no longer keys donated files by guest FD",
    )
    check(
        "Host:  fdHost" in mapping_source and "Guest: fdGuest" in mapping_source,
        "M:N parsing no longer records host and guest FDs",
    )
    check(
        'fmt.Sprintf("--pass-fd=%d:%d", nextFD, fd)' in donation_source,
        "internal sandbox donation no longer preserves guest mapping",
    )
    check(
        "guest: customFD.Guest" in loader_source,
        "Sentry loader no longer records the requested guest FD",
    )
    check(
        "fdMap[customFD.guest] = customFD.host" in loader_source,
        "application FD table no longer imports at the requested guest FD",
    )
    check(
        "The format is `--pass-fd=HOST_FD:GUEST_FD`" in guide,
        "pinned user guide no longer documents HOST_FD:GUEST_FD",
    )
    command_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (root / "runsc/cmd").rglob("*.go")
    )
    check(
        "preserve-fds" not in command_sources,
        "unexpected public preserve-fds command seam",
    )
    print("PASS: pinned gVisor run --pass-fd=HOST_FD:GUEST_FD seam")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
