#!/usr/bin/env python3
"""Verify the exact accepted guest/outer plus native joined source inventory."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
BUILD = HERE / "build"
BASELINE_ROSTER = BUILD / "reader-interaction-guest-outer-frozen-inputs-v1.txt"
CURRENT_ROSTER = BUILD / "reader-interaction-guest-outer-frozen-inputs-v3.txt"
BASELINE_ROSTER_SHA256 = (
    "f08701a58a7c0e83e1c8cd57122b34185fa0c4d7deeaf9d9f5d7080b5dd616e4"
)
CURRENT_ROSTER_SHA256 = (
    "50390fbd40478e5d6fbddfb80f17794fdb715dba6eb57597fc5480771f9c659b"
)
EXTRA_JOINED = (
    (
        "b5ff6eabc225a270f017aaa32a74381bfe4f0dac5e51b63e33bc85b274815f33",
        "pinenote/tools/book-execution-spike/"
        "test_disposable_reader_qemu_actual_coordinator.py",
    ),
)
NATIVE_JOINED = (
    (
        "ca0c552f9ad63ecf214a01d2cfced274fbb17a15971fdac7705feb4881325bde",
        "pinenote/tools/book-interaction/qemu-coordinator.scm",
    ),
    (
        "18adc5dabd5561f723eb80e728730b62997ea5d30094662c46c9b143c5ddbac4",
        "pinenote/tools/book-interaction/qemu-coordinator-contract.md",
    ),
    (
        "5e2918e2ce38f3d32058230f59f19364dbda71f2da77ca52d4008c242bf3ce74",
        "pinenote/tools/book-interaction/test-qemu-mode-guest.scm",
    ),
    (
        "3142afaec5baf01b5c6a1661cf3790085090d13b518134bce8951b40fc5f216f",
        "pinenote/tools/book-interaction/run-qemu-mode-tests.sh",
    ),
    (
        "ac5ed5c735efa91c7817e9b12d36f5838f21308a3fc3e6ba55a1db87c53d476d",
        "pinenote/tools/book-interaction/README.md",
    ),
    (
        "89a28b0aec7fd752860be4b15414e9763c7d2f86a2e343bc5e5422bf53272964",
        "pinenote/tools/book-interaction/fixture/"
        "bookinteractionprobe.koplugin/_meta.lua",
    ),
    (
        "8f58786c38f1a947d145b3299ef937129028a5e0bf265e339eb578a7d14b1125",
        "pinenote/tools/book-interaction/fixture/"
        "bookinteractionprobe.koplugin/main.lua",
    ),
    (
        "4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832",
        "pinenote/tools/book-interaction/fixture/"
        "bookinteractionprobe.koplugin/private_channel.lua",
    ),
    (
        "cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a",
        "pinenote/tools/book-interaction/fixture/"
        "bookinteractionprobe.koplugin/ui_audit.lua",
    ),
)
EXPECTED_HEADERS = (
    "schema=1",
    "scope=reader-interaction-full-joined-source-inventory",
    "status=frozen-production-pin-corrected-pending-finite-joined-recheck",
    "path-count=46",
    "entry-format=sha256=LOWERCASE_HEX REPOSITORY_RELATIVE_PATH",
    "guest-outer-reviewed-baseline-path-count=35",
    "guest-outer-reviewed-baseline-roster-sha256=" + BASELINE_ROSTER_SHA256,
    "guest-outer-current-path-count=36",
    "guest-outer-current-roster-sha256=" + CURRENT_ROSTER_SHA256,
    "guest-finish-delivery-review-result=accepted",
    "guest-finish-delivery-review-snapshot-sha256="
    "3a4c39c3f5fda18be817607d2a75ac83c21fe16bdfeb34a5ae7905bb8ae64221",
    "native-coordinator-review-result=accepted",
    "native-coordinator-review-snapshot-sha256="
    "5ea9b027fa7027f822ea7227bfde9e90e3d43cf311c44f17f827dd429e1a6863",
    "joined-review-blocked-snapshot-sha256="
    "8eea8caa1f5f8531ca6fc147a9c6dee27bec9fef6c49733491f12e5669f884ae",
    "joined-review-blocker=production-coordinator-pin-mismatch",
    "joined-fix-status=one-literal-production-pin-applied-pending-finite-recheck",
    "mutable-append-only-review-file-hash-is-machine-gate=false",
    "outer-core-source-edit=one-accepted-coordinator-hash-literal",
    "accepted-coordinator-binding=normal-production-five-source-roster",
    "image-build-authorized=false",
    "qemu-run-authorized=false",
    "runsc-authorized=false",
    "arm-execution-authorized=false",
    "hardware-authorized=false",
)
ENTRY_PATTERN = re.compile(r"sha256=([0-9a-f]{64}) ([A-Za-z0-9_./-]+)")


class InventoryError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_regular(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise InventoryError(f"{label} is not a regular non-symlink file: {path}")
    if path.stat().st_nlink != 1:
        raise InventoryError(f"{label} is not single-link: {path}")


def parse_entries(path: Path) -> tuple[tuple[str, str], ...]:
    require_regular(path, "inventory")
    lines = path.read_text(encoding="utf-8").splitlines()
    entry_index = next(
        (index for index, line in enumerate(lines) if line.startswith("sha256=")),
        None,
    )
    if entry_index is None:
        raise InventoryError("inventory has no source entries")
    if tuple(lines[:entry_index]) != EXPECTED_HEADERS:
        raise InventoryError("joined inventory headers differ from the fixed contract")
    entries: list[tuple[str, str]] = []
    for line in lines[entry_index:]:
        match = ENTRY_PATTERN.fullmatch(line)
        if not match:
            raise InventoryError(f"malformed joined inventory line: {line!r}")
        entries.append((match.group(1), match.group(2)))
    if len(entries) != 46 or len({relative for _, relative in entries}) != 46:
        raise InventoryError("joined inventory is not 46 unique paths")
    return tuple(entries)


def parse_frozen_roster(path: Path, expected_hash: str, count: int) -> tuple[tuple[str, str], ...]:
    require_regular(path, "frozen guest/outer roster")
    if sha256(path) != expected_hash:
        raise InventoryError(f"frozen guest/outer roster hash mismatch: {path.name}")
    entries: list[tuple[str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("sha256="):
            match = ENTRY_PATTERN.fullmatch(line)
            if not match:
                raise InventoryError(f"malformed frozen-roster entry: {line!r}")
            entries.append((match.group(1), match.group(2)))
    if len(entries) != count or len({relative for _, relative in entries}) != count:
        raise InventoryError(f"{path.name} is not {count} unique paths")
    return tuple(entries)


def expected_entries(root: Path) -> tuple[tuple[str, str], ...]:
    build = root / "pinenote/tools/book-execution-spike/build"
    parse_frozen_roster(
        build / BASELINE_ROSTER.name, BASELINE_ROSTER_SHA256, 35
    )
    current = list(
        parse_frozen_roster(build / CURRENT_ROSTER.name, CURRENT_ROSTER_SHA256, 36)
    )
    insertion = next(
        index + 1
        for index, (_, relative) in enumerate(current)
        if relative.endswith("/test_disposable_reader_qemu.py")
    )
    current[insertion:insertion] = EXTRA_JOINED
    return tuple(current) + NATIVE_JOINED


def verify_inventory(manifest: Path, root: Path = REPO) -> None:
    expected = expected_entries(root)
    observed = parse_entries(manifest)
    if observed != expected:
        raise InventoryError("joined inventory entries differ from exact accepted order")
    forbidden_reviews = {
        "doc/reviews/2026-09-06-book-interaction-qemu-native-adversarial.md",
        "doc/reviews/2026-09-06-book-interaction-qemu-guest-outer-adversarial.md",
    }
    if forbidden_reviews.intersection(relative for _, relative in observed):
        raise InventoryError("mutable append-only review file entered machine hash gate")
    for expected_hash, relative in observed:
        source = root / relative
        require_regular(source, "joined source")
        actual = sha256(source)
        if actual != expected_hash:
            raise InventoryError(
                f"joined source hash mismatch: {relative}: "
                f"expected {expected_hash}, got {actual}"
            )


def self_test(manifest: Path) -> None:
    verify_inventory(manifest)
    entries = parse_entries(manifest)
    with tempfile.TemporaryDirectory(
        prefix="reader-interaction-joined-inventory.", dir="/tmp/opencode"
    ) as temporary:
        root = Path(temporary) / "repo"
        for _, relative in entries:
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, destination)
        for roster in (BASELINE_ROSTER, CURRENT_ROSTER):
            destination = root / roster.relative_to(REPO)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(roster, destination)
        private_manifest = root / manifest.relative_to(REPO)
        private_manifest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(manifest, private_manifest)
        verify_inventory(private_manifest, root)

        for relative in (
            "pinenote/tools/book-execution-spike/guest-book-interaction.scm",
            "pinenote/tools/book-interaction/qemu-coordinator.scm",
            "pinenote/tools/book-interaction/fixture/"
            "bookinteractionprobe.koplugin/private_channel.lua",
        ):
            target = root / relative
            original = target.read_bytes()
            target.write_bytes(original + b"\nmutation\n")
            try:
                verify_inventory(private_manifest, root)
            except InventoryError:
                pass
            else:
                raise InventoryError(f"private source mutation was accepted: {relative}")
            target.write_bytes(original)

        original_manifest = private_manifest.read_bytes()
        private_manifest.write_bytes(original_manifest + original_manifest.splitlines(True)[-1])
        try:
            verify_inventory(private_manifest, root)
        except InventoryError:
            pass
        else:
            raise InventoryError("duplicate private inventory entry was accepted")


def main(arguments: list[str]) -> int:
    if len(arguments) != 2 or arguments[0] not in {"check", "self-test"}:
        raise InventoryError("usage: check_reader_interaction_joined_inventory.py check|self-test MANIFEST")
    manifest = Path(arguments[1])
    if not manifest.is_absolute():
        manifest = REPO / manifest
    if arguments[0] == "self-test":
        self_test(manifest)
        print("PASS: joined source inventory and four private-copy drift cases")
    else:
        verify_inventory(manifest)
        print("PASS: exact 46-path joined reader-interaction source inventory")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except InventoryError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
