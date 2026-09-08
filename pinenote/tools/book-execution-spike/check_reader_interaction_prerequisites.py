#!/usr/bin/env python3
"""Check the already-built kernel/eudev prerequisites for the reader seam."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys


EXPECTED_CONFIG_SHA256 = (
    "0a885ef88e43a24fe0608a3157e5829e35fe8695fabddc115ee65f5f5479d309"
)
EXPECTED_CLOSURE_SHA256 = (
    "48728ed963043862f656e0b14fdef113200411cb8d83c08c179e95942c1980bc"
)
EXPECTED_SYSTEM_ROSTER_SHA256 = (
    "99066c31e00ac758f63c8d0f6afab147a0ee42753e8f55479332e117ba011e8f"
)
EXPECTED_UDEV_RULE_SHA256 = (
    "d24e847307991e0d48febb57ac95ab2878dd65af9a546d07c4793742b81ba21b"
)
REQUIRED_CONFIG = (
    "CONFIG_USER_NS=y",
    "CONFIG_UNIX=y",
    "CONFIG_PCI_HOST_GENERIC=y",
    "CONFIG_DEVTMPFS=y",
    "CONFIG_DEVTMPFS_MOUNT=y",
    "CONFIG_VIRTIO_MENU=y",
    "CONFIG_VIRTIO_PCI=y",
    "CONFIG_VIRTIO_CONSOLE=y",
)
NAMED_PORT_RULE = (
    'SUBSYSTEM=="virtio-ports", KERNEL=="vport*", ATTR{name}=="?*", '
    'SYMLINK+="virtio-ports/$attr{name}"'
)


class CheckError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_fixed_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise CheckError(f"{label} is not a regular non-symlink file: {path}")


def check_config(path: Path) -> None:
    require_fixed_file(path, "installed kernel config")
    observed = sha256(path)
    if observed != EXPECTED_CONFIG_SHA256:
        raise CheckError(
            f"installed config hash changed: expected {EXPECTED_CONFIG_SHA256}, got {observed}"
        )
    lines = path.read_text(encoding="ascii").splitlines()
    for setting in REQUIRED_CONFIG:
        symbol = setting.split("=", 1)[0]
        matches = [line for line in lines if line.startswith(symbol + "=")]
        if matches != [setting]:
            raise CheckError(f"kernel setting is not exact: {setting}: {matches!r}")


def check_closure(path: Path) -> None:
    require_fixed_file(path, "accepted language closure")
    observed = sha256(path)
    if observed != EXPECTED_CLOSURE_SHA256:
        raise CheckError(
            f"closure hash changed: expected {EXPECTED_CLOSURE_SHA256}, got {observed}"
        )
    text = path.read_text(encoding="utf-8")
    paths = re.findall(r'"(/gnu/store/[^"\\\x00\r\n]+)"', text)
    canonical = "(" + " ".join(json.dumps(item) for item in paths) + ")"
    if text != canonical:
        raise CheckError("accepted closure is not one canonical Scheme path list")
    if len(paths) != 45 or len(set(paths)) != 45:
        raise CheckError("accepted sandbox language closure is not 45 unique paths")
    if any(not re.fullmatch(r"/gnu/store/[0-9a-z]{32}-[^\x00\r\n]+", line) for line in paths):
        raise CheckError("accepted closure contains a noncanonical store path")


def check_system_roster(path: Path) -> None:
    require_fixed_file(path, "accepted system requisite roster")
    observed = sha256(path)
    if observed != EXPECTED_SYSTEM_ROSTER_SHA256:
        raise CheckError(
            "system requisite roster hash changed: "
            f"expected {EXPECTED_SYSTEM_ROSTER_SHA256}, got {observed}"
        )
    paths = path.read_text(encoding="utf-8").splitlines()
    if len(paths) != 341 or len(set(paths)) != 341 or paths != sorted(paths):
        raise CheckError("accepted system requisite roster is not 341 sorted unique paths")
    matches = [line for line in paths if line.endswith("-eudev-3.2.14")]
    if len(matches) != 1:
        raise CheckError(f"expected one eudev 3.2.14 closure entry, got {matches!r}")
    rule = Path(matches[0]) / "lib/udev/rules.d/50-udev-default.rules"
    require_fixed_file(rule, "eudev named-port rule")
    observed_rule = sha256(rule)
    if observed_rule != EXPECTED_UDEV_RULE_SHA256:
        raise CheckError(
            "eudev default rule hash changed: "
            f"expected {EXPECTED_UDEV_RULE_SHA256}, got {observed_rule}"
        )
    lines = rule.read_text(encoding="utf-8").splitlines()
    if lines.count(NAMED_PORT_RULE) != 1:
        raise CheckError("eudev does not contain the exact named virtio-port rule once")


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        raise CheckError(
            "usage: check_reader_interaction_prerequisites.py "
            "CONFIG LANGUAGE-CLOSURE SYSTEM-REQUISITES"
        )
    check_config(Path(arguments[0]))
    check_closure(Path(arguments[1]))
    check_system_roster(Path(arguments[2]))
    print("PASS: installed kernel and accepted eudev named-port prerequisites")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CheckError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
