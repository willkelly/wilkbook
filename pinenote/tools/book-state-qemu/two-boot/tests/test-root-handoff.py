#!/usr/bin/env python3
"""Bind immutable payload input to emitted argv and Guix root semantics."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
GUILE = Path(
    "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile"
)
GUIX_LINUX_BOOT = Path(
    "/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules/"
    "share/guile/site/3.0/gnu/build/linux-boot.scm"
)


def load_checker():
    spec = importlib.util.spec_from_file_location("root_handoff_checker",
                                                  ROOT / "check-evidence.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def roots(append: str) -> list[str]:
    return [token for token in append.split() if token.startswith("root=")]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-root-handoff.py IMMUTABLE_V9_BUNDLE")
    bundle = Path(sys.argv[1])
    config = bundle / "boot-bundle/extlinux/extlinux.conf"
    append_lines = [
        line.strip()[7:].strip()
        for line in config.read_text().splitlines()
        if line.strip().startswith("APPEND ")
    ]
    if len(append_lines) != 1 or roots(append_lines[0]) != [
            "root=LABEL=PNGuixRoot"]:
        raise AssertionError("immutable V9 payload input root spelling changed")

    expression = (
        "(use-modules (disposable-qemu)) "
        "(display ((@@ (disposable-qemu) read-fixed-append) "
        "(cadr (command-line)))) (newline)"
    )
    result = subprocess.run(
        [str(GUILE), "--no-auto-compile", "-L", str(ROOT / "modules"),
         "-c", expression, str(config)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=dict(os.environ), timeout=30, check=False, text=True,
    )
    if result.returncode != 0 or result.stderr or roots(result.stdout.strip()) != [
            "root=PNGuixRoot"]:
        raise AssertionError(
            f"production parser root handoff failed: {result!r}")

    checker = load_checker()
    checker.check_root_handoff(result.stdout.strip())
    for rejected in (
            "root=LABEL=PNGuixRoot", "root=PNGuixRoot root=PNGuixRoot",
            "root=/dev/vda1"):
        try:
            checker.check_root_handoff(rejected)
        except checker.CheckError:
            pass
        else:
            raise AssertionError(f"checker accepted invalid root handoff: {rejected}")

    source = GUIX_LINUX_BOOT.read_text()
    start = source.index("(define (device-string->file-system-device")
    end = source.index('(display "Welcome, this is GNU', start)
    conversion = source[start:end]
    if ('(else (file-system-label device-string))' not in conversion or
            '"LABEL="' in conversion):
        raise AssertionError("pinned Guix root conversion semantics changed")

    print("PASS: immutable LABEL= input becomes one bare Guix label in argv/checker; pinned Guix source confirms bare-label semantics")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
