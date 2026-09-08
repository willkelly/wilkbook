#!/usr/bin/env python3
"""Check the derivation-only Book State guest requisite roster."""

from __future__ import annotations

import argparse
from pathlib import Path


EXPECTED_KERNEL = (
    "/gnu/store/61ls988abhyi7lzvm19plffyv580nxc1-"
    "linux-pinenote-book-execution-test-7.1.8-pinenote.drv"
)
EXPECTED_GVISOR_DERIVATION = (
    "/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-"
    "gvisor-source-built-20260831.0.drv"
)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)
    print(f"PASS: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root_derivation")
    parser.add_argument("requisites", type=Path)
    arguments = parser.parse_args()
    paths = arguments.requisites.read_text(encoding="utf-8").splitlines()
    check(paths == sorted(set(paths)), "requisites are unique and sorted")
    check(arguments.root_derivation in paths, "requisites include system root")
    check(EXPECTED_KERNEL in paths, "requisites retain exact USER_NS kernel derivation")
    check(
        EXPECTED_GVISOR_DERIVATION in paths,
        "requisites retain exact source-built gVisor derivation",
    )
    gvisor_drivers = [
        path for path in paths
        if path.endswith("-gvisor-source-built-20260831.0.drv")
    ]
    check(len(gvisor_drivers) == 1, "requisites contain exactly one source-built gVisor derivation")
    forbidden = (
        "gvisor-bin-20260831.0",
        "gvisor-local-test-artifacts",
        "gvisor-v12",
        "CONTROL",
        "/tmp/",
        "/build/",
        "doc/reviews",
        "source-packets",
    )
    check(
        not any(token in path for path in paths for token in forbidden),
        "requisites exclude binary/local/CONTROL/generated/tmp/review inputs",
    )
    check(len(paths) == 2784, "requisites contain the exact 2,784-node system graph")
    print(f"REQUISITES-CHECK count={len(paths)}")


if __name__ == "__main__":
    main()
