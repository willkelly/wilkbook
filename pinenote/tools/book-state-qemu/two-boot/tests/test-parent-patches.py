#!/usr/bin/env python3
"""Authenticate accepted snapshots and exact review deltas without patch(1)."""

from __future__ import annotations

import difflib
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def digest(relative: str) -> str:
    return hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()


EXPECTED = {
    "accepted/disposable-qemu.scm":
        "0fe3668f14d3f9a3fb8b1e51b1cf12b5fc4afa5e2fca61a46406572b738b63ca",
    "accepted/disposable-reader-qemu.scm":
        "8ae1ec1afd562c1a2f737688b89b0bda396369d2b875b4d0221e7ff83109ccf9",
    "accepted/qemu-coordinator.scm":
        "ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde",
    "modules/reader-qemu-graph.scm":
        "16f11331c27cab0a5f432062fa4251dcbff5b23a7736306e98caa15b46966002",
    "modules/book-state-qemu/qemu-graph.scm":
        "708ccca8fe367a20ef886168bed524704a5cdd0a97acf5f0609eecd822ad977c",
    "modules/book-state-qemu/state-volume.scm":
        "79324bbb80ba8eb9e57c4d8285b0d6f4f76020bfb1016d0e8c22fe8526b42d29",
}

PATCHES = (
    ("accepted/disposable-qemu.scm", "modules/disposable-qemu.scm",
     "accepted/disposable-qemu.scm", "two-boot/modules/disposable-qemu.scm",
     "parent-patches/disposable-qemu-guardian-hooks.patch"),
    ("accepted/qemu-coordinator.scm", "candidate/qemu-state-coordinator.scm",
     "accepted/qemu-coordinator.scm",
     "two-boot/candidate/qemu-state-coordinator.scm",
     "parent-patches/qemu-state-coordinator.patch"),
    ("accepted/disposable-reader-qemu.scm", "one-boot.scm",
     "accepted/disposable-reader-qemu.scm", "two-boot/one-boot.scm",
     "parent-patches/one-boot-wrapper.patch"),
)


def main() -> int:
    for relative, expected in EXPECTED.items():
        actual = digest(relative)
        if actual != expected:
            raise AssertionError(f"accepted parent identity differs: {relative}: {actual}")
    for left, right, left_label, right_label, patch in PATCHES:
        expected = "".join(difflib.unified_diff(
            (ROOT / left).read_text().splitlines(True),
            (ROOT / right).read_text().splitlines(True),
            fromfile=left_label, tofile=right_label, n=3,
        ))
        actual = (ROOT / patch).read_text()
        if not expected or actual != expected:
            raise AssertionError(f"parent patch is absent or stale: {patch}")
    runner = (ROOT / "run-two-boot.scm").read_text()
    required = (
        '(define (start-checker-context run-base python)',
        '(string-append root "/checker-root-guardian.scm")',
        '(string-append root "/checker-guardian.scm")',
        '(string-append root "/checker-child.scm")',
        '("checker-child.scm" . "checker-child.scm")',
        "(define state-copy-identity-fields '(device inode uid mode links size))",
        '(state-copy-identity state-identity) artifact',
        '(final-artifact-mode . "0400")',
    )
    forbidden = (
        '(string-append evidence-root "/checker-root-guardian.scm")',
        '(string-append evidence-root "/checker-guardian.scm")',
        '(string-append evidence-root "/checker-child.scm")',
        '(final-artifact-mode . 0400)',
    )
    if any(item not in runner for item in required) or any(
            item in runner for item in forbidden):
        raise AssertionError(
            "final checker records are not staged outside the sealed payload")
    print("PASS: 6 accepted parent identities, 3 exact successor patches, "
          "isolated final-checker staging, and exact final-artifact joins")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
