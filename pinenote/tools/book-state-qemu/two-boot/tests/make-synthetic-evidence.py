#!/usr/bin/env python3
"""Create non-claiming, internally coherent checker fixtures."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


CHECKER = Path(__file__).resolve().parents[1] / "check-evidence.py"
SPEC = importlib.util.spec_from_file_location("two_boot_checker", CHECKER)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = checker
SPEC.loader.exec_module(checker)


class Pair:
    def __init__(self, head: Any, tail: Any):
        self.head = head
        self.tail = tail


class Sym(str):
    pass


def scm(value: Any) -> str:
    if value is True:
        return "#t"
    if value is False:
        return "#f"
    if isinstance(value, Sym):
        return str(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace(
            "\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, Pair):
        return f"({scm(value.head)} . {scm(value.tail)})"
    if isinstance(value, (list, tuple)):
        return "(" + " ".join(scm(item) for item in value) + ")"
    raise TypeError(value)


def alist_text(entries: list[tuple[str, Any]]) -> str:
    rendered = []
    for key, value in entries:
        key_value = Sym(key)
        if isinstance(value, list):
            rendered.append("(" + scm(key_value) +
                            (" " + " ".join(scm(item) for item in value)
                             if value else "") + ")")
        elif isinstance(value, Pair):
            rendered.append(
                "(" + scm(key_value) + " " + scm(value.head) +
                " . " + scm(value.tail) + ")")
        else:
            rendered.append("(" + scm(key_value) + " . " + scm(value) + ")")
    return "(" + " ".join(rendered) + ")\n"


def write_alist(path: Path, entries: list[tuple[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(alist_text(entries), encoding="utf-8")


def write_record(path: Path, entries: list[tuple[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{key}={value}\n" for key, value in entries),
                    encoding="utf-8")


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def process(path: Path, role: str, pid: int) -> tuple[int, str]:
    identity = (pid, str(pid * 10 + 1))
    write_alist(path, [
        ("schema", 1), ("role", Sym(role)), ("pid", identity[0]),
        ("start-time", identity[1]),
    ])
    return identity


def exec_record(path: Path, role: str, identity: tuple[int, str],
                guarded_root: str, state: tuple[int, int, int]) -> None:
    write_alist(path, [
        ("schema", 1), ("role", Sym(role)), ("pid", identity[0]),
        ("start-time", identity[1]), ("process-group", identity[0]),
        ("guarded-root", guarded_root), ("guarded-root-device", 44),
        ("guarded-root-inode", identity[0] + 90000),
        ("state-proc-file", "/proc/self/fd/17"), ("state-fd", 17),
        ("state-device", state[0]), ("state-inode", state[1]),
        ("state-size", state[2]), ("anchor-fd", 18),
        ("anchor-cloexec", True), ("non-cloexec-above-stderr", [17]),
    ])


def encode_frames(frames: list[tuple[str, int, str]]) -> bytes:
    return b"".join(
        f"{kind}|{generation}|{value.encode().hex()}\n".encode()
        for kind, generation, value in frames
    )


def reader_log(boot: int) -> str:
    lines = [
        " [*] Version: v2026.03",
        "BOOK_STATE_QEMU_SPAWN: koreader:exec-fd-hygiene:stdio-and-ui-fd3-only",
        *checker.expected_reader_markers(boot),
    ]
    return "\n".join(lines) + "\n"


def sandbox_boundary_pair(
        language: str, operation: str, version: int) -> tuple[bytes, bytes]:
    """Model V8's finalized capture plus completed-book-result attribution."""
    marker = checker.SANDBOX_BOUNDARY_MARKERS[language]
    capture = (
        b"MODEL-RUNSC-STDOUT diagnostic-before-boundary\n" + marker +
        b"\nBOOK_STATE_READER_JOIN_BOOK: model-book-finished\n"
    )
    source = (
        b"BOOK-STATE-GUEST sandbox-boundary-source language=" +
        language.encode() + b" container=" +
        checker.SANDBOX_CONTAINERS[language].encode() +
        b" source=owned-finalized-runsc.stdout "
         b"publication=next-line-after-child-drain marker-bytes=" +
        str(len(marker)).encode() + b" marker-sha256=" +
        hashlib.sha256(marker).hexdigest().encode() + b" capture-bytes=" +
         str(len(capture)).encode() + b" capture-sha256=" +
         hashlib.sha256(capture).hexdigest().encode() + b" operation=" +
         operation.encode() + b" resulting-state-version=" + str(version).encode()
    )
    return source, marker


def console(boot: int) -> bytes:
    operations = {
        1: ("op_guile_a", "op_python_a"),
        2: ("op_guile_b", "op_python_b"),
    }[boot]
    lines = [
        b"[    0.000000] Linux version synthetic-checker-fixture",
        (b"BOOK-STATE-GUEST source-provenance=pass "
         b"accepted-reader-join-source-root=" + checker.READER_JOIN_SOURCE.encode()),
        *checker.BASE_MARKERS,
    ]
    for language, operation in zip(("guile", "python"), operations):
        if boot == 1:
            lines.append(
                f"BOOK-STATE-GUEST language={language} read=absent version=0 bytes=0 ui-painted=true".encode())
        else:
            size = len(checker.TEXT[language]["a"].encode())
            lines.extend([
                f"BOOK-STATE-GUEST language={language} read=a version=1 bytes={size} ui-painted=true".encode(),
                f"BOOK-STATE-GUEST language={language} recovered=A-before-save=true".encode(),
            ])
        lines.append(
            f"BOOK-STATE-GUEST language={language} saved={'A' if boot == 1 else 'B'} version={boot} operation={operation}".encode())
        # V8 publishes these only after the fixed book has completed and the
        # owned runsc group and bounded stdout/stderr captures are finalized.
        # This is a checker model, not runtime containment evidence.
        lines.extend(sandbox_boundary_pair(language, operation, boot))
    lines.extend([
        (b"BOOK-STATE-GUEST inspector-path=/var/lib/wilkbook-book-state-demo/"
         b"book-state-v1.sqlite namespaces=2 receipts=" + str(boot * 2).encode() +
         b" quick-check=ok foreign-keys=ok sidecars=none"),
        f"BOOK-STATE-GUEST result=pass initial-stage={'absent' if boot == 1 else 'a'} final-versions={boot},{boot}".encode(),
        b"[    2.000000] synthetic shutdown progress",
        b"[    3.000000] reboot: Power down",
    ])
    return b"\n".join(lines) + b"\n"


def graph_arguments(run_root: str) -> list[str]:
    state_file = json.dumps({
        "driver": "file", "filename": "/proc/self/fd/17",
        "node-name": "book-state-file", "read-only": False, "locking": "on",
    }, separators=(",", ":"))
    seed = [
        "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-qemu/bin/qemu-system-aarch64",
        "-append", "console=ttyAMA0 root=PNGuixRoot ro",
        "-blockdev", state_file,
    ]
    return checker.expected_graph(seed, {"run-root": run_root})


def make_state(path: Path) -> str:
    with path.open("wb") as output:
        output.truncate(checker.STATE_SIZE)
    with path.open("r+b", buffering=0) as output:
        output.seek(1024 + 0x38)
        output.write(b"\x53\xef")
        output.write(b"\x01\x00")
        output.seek(1024 + 0x78)
        output.write(checker.STATE_LABEL.ljust(16, b"\x00"))
    path.chmod(0o400)
    return digest(path)


def make_boot(root: Path, boot: int, authority: dict[str, str],
              state: tuple[int, int, int], before: str, after: str) -> None:
    base = 1000 * boot
    identities = {
        "owner": (base + 1, str((base + 1) * 10 + 1)),
        "owner-guardian": (base + 2, str((base + 2) * 10 + 1)),
        "launch-root-guardian": (base + 3, str((base + 3) * 10 + 1)),
        "coordinator": (base + 4, str((base + 4) * 10 + 1)),
        "coordinator-guardian": (base + 5, str((base + 5) * 10 + 1)),
        "ephemeral-root-guardian": (base + 6, str((base + 6) * 10 + 1)),
        "qemu": (base + 7, str((base + 7) * 10 + 1)),
        "reader": (base + 8, str((base + 8) * 10 + 1)),
    }
    roles = {
        "owner-child.scm": ("one-boot-owner-child", "owner"),
        "owner-guardian.scm": ("one-boot-owner-guardian", "owner-guardian"),
        "launch-root-guardian.scm": ("boot-launch-root-guardian", "launch-root-guardian"),
        "coordinator-child.scm": ("coordinator-direct-child", "coordinator"),
        "coordinator-guardian.scm": ("coordinator-process-guardian", "coordinator-guardian"),
        "run-root-guardian.scm": ("ephemeral-run-root-guardian", "ephemeral-root-guardian"),
    }
    for name, (role, prefix) in roles.items():
        pid, start = identities[prefix]
        observed = process(root / name, role, pid)
        assert observed == (pid, start)
    for index in range(1, 11):
        if index == 10:
            guardian = identities["coordinator-guardian"]
            child = identities["coordinator"]
        else:
            guardian = (base + 100 + index * 2,
                        str((base + 100 + index * 2) * 10 + 1))
            child = (base + 101 + index * 2,
                     str((base + 101 + index * 2) * 10 + 1))
        process(root / f"inner-{index:03d}-guardian.scm",
                "accepted-inner-process-guardian", guardian[0])
        process(root / f"inner-{index:03d}-child.scm",
                "accepted-inner-direct-child", child[0])
    run_root = f"/tmp/opencode/model-runs/book-execution-qemu.boot{boot}"
    launch_root = f"/tmp/opencode/model-runs/book-state-two-boot-launch.boot{boot}"
    exec_record(root / "owner-exec.scm", "one-boot-owner-exec",
                identities["owner"], launch_root, state)
    exec_record(root / "coordinator-exec.scm", "coordinator-exec-child",
                identities["coordinator"], run_root, state)
    arguments = graph_arguments(run_root)
    write_alist(root / "qemu-graph.scm", [
        ("schema", 1), ("unpaused", True), ("vcpus", 2), ("memory-mib", 512),
        ("state-device", state[0]), ("state-inode", state[1]),
        ("state-size", state[2]), ("arguments", arguments),
    ])
    write_alist(root / "run.scm", [
        ("schema", 1), ("disposition", Sym("semantic-success")),
        ("unpaused", True), ("vcpus", 2), ("memory-mib", 512),
        ("hard-vm-deadline-seconds", 360), ("term-grace-seconds", 5),
        ("run-root", run_root), ("run-root-device", 50),
        ("run-root-inode", 5000 + boot), ("overlay-device", 50),
        ("overlay-inode", 6000 + boot), ("state-device", state[0]),
        ("state-inode", state[1]), ("state-size", state[2]),
        ("hard-vm-owner-result-observed", True),
        ("hard-vm-owner-status", 0), ("hard-vm-owner-timed-out", False),
    ])
    reader_root = root / "run/reader-ui"
    reader_root.mkdir(parents=True)
    commands, events = checker.expected_ui(boot)
    (reader_root / "ui-guest-to-reader.bin").write_bytes(encode_frames(commands))
    (reader_root / "ui-reader-to-guest.bin").write_bytes(encode_frames(events))
    proxy = [
        ("schema", 1),
        ("guest-to-reader-bytes", (reader_root / "ui-guest-to-reader.bin").stat().st_size),
        ("reader-to-guest-bytes", (reader_root / "ui-reader-to-guest.bin").stat().st_size),
        ("guest-to-reader-eof", True), ("reader-to-guest-eof", True),
        ("complete", True),
    ]
    write_alist(reader_root / "ui-proxy.scm", proxy)
    embedded_proxy = [Pair(Sym(key), value) for key, value in proxy]
    write_alist(reader_root / "coordinator-result.scm", [
        ("schema", 1), ("state-device", state[0]), ("state-inode", state[1]),
        ("state-size", state[2]),
        ("coordinator-pid", identities["coordinator"][0]),
        ("coordinator-process-group", identities["coordinator"][0]),
        ("qemu-pid", identities["qemu"][0]),
        ("qemu-start-time", identities["qemu"][1]),
        ("qemu-process-group", identities["coordinator"][0]),
        ("qemu-status", Pair(Sym("exit"), 0)),
        ("reader-pid", identities["reader"][0]),
        ("reader-start-time", identities["reader"][1]),
        ("reader-process-group", identities["coordinator"][0]),
        ("reader-status", Pair(Sym("exit"), 0)), ("children-zero", True),
        ("ui-proxy", embedded_proxy),
    ])
    (reader_root / "qemu.pid").write_text(
        f"{identities['qemu'][0]} {identities['qemu'][1]}\n")
    (reader_root / "reader.pid").write_text(
        f"{identities['reader'][0]} {identities['reader'][1]}\n")
    (reader_root / "qemu.stdout").write_bytes(
        b"BOOK_STATE_QEMU_SPAWN: qemu:exec-fd-hygiene:stdio-and-state-ofd-only\n")
    (reader_root / "qemu.stderr").write_bytes(b"")
    (reader_root / "reader.log").write_text(reader_log(boot), encoding="utf-8")
    (root / "run/console.log").write_bytes(console(boot))
    (root / "run/qemu.stdout").write_bytes(checker.COORDINATOR_SUCCESS)
    (root / "run/qemu.stderr").write_bytes(b"")
    (root / "one-boot.stdout").write_bytes(checker.ONE_BOOT_SUCCESS)
    (root / "one-boot.stderr").write_bytes(b"")
    entries: list[tuple[str, Any]] = [
        ("schema", 1), ("boot-index", boot),
        ("boot-id", f"{boot:032x}"), ("status", "pass"), ("timed-out", "false"),
        ("hard-vm-timed-out", "false"), ("owner-timed-out", "false"),
        ("guest-source-manifest-sha256", checker.GUEST_SOURCE),
        ("guest-source-snapshot-manifest-sha256", checker.GUEST_SNAPSHOT),
        ("guest-capsule-roster-sha256", checker.GUEST_CAPSULE),
        ("guest-authority-source-sha256", checker.GUEST_AUTHORITY),
        ("guest-contract-sha256", checker.GUEST_CONTRACT),
        ("two-boot-timeout-contract-sha256", checker.TIMEOUT_CONTRACT),
        ("guest-cooperative-budget-seconds", 300),
        ("hard-vm-deadline-seconds", 360),
        ("term-grace-seconds", 5),
        ("one-boot-owner-hard-deadline-seconds", 420),
        ("root-filesystem-label", "PNGuixRoot"),
        ("state-filesystem-label", "WBBookStateV1"),
        ("source-manifest-sha256", authority["source"]),
        ("bundle-manifest-sha256", authority["bundle"]),
        ("kernel-sha256", authority["kernel"]),
        ("initrd-sha256", authority["initrd"]),
        ("config-sha256", authority["config"]),
        ("baseline-sha256", authority["baseline"]),
        ("qemu-graph-sha256", digest(root / "qemu-graph.scm")),
        ("run-root", run_root), ("run-root-device", 50),
        ("run-root-inode", 5000 + boot), ("overlay-device", 50),
        ("overlay-inode", 6000 + boot), ("state-device", state[0]),
        ("state-inode", state[1]), ("state-size", state[2]),
        ("state-hash-before", before), ("state-hash-after", after),
    ]
    for prefix in checker.PROCESS_PREFIXES:
        entries.extend([
            (f"{prefix}-pid", identities[prefix][0]),
            (f"{prefix}-start-time", identities[prefix][1]),
        ])
    write_record(root / "boot.record", entries)


def seal_payload(root: Path) -> str:
    path = root / "PAYLOAD.sha256"
    if path.exists():
        path.unlink()
    members = sorted(
        item.relative_to(root).as_posix()
        for item in root.rglob("*") if item.is_file()
    )
    path.write_text("".join(f"{digest(root / name)}  {name}\n" for name in members))
    return digest(path)


def seal_final(root: Path) -> str:
    (root / "CHECKER.txt").write_bytes(checker.ONE_BOOT_SUCCESS.replace(
        b"BOOK_STATE_ONE_BOOT: status=pass; semantic=archived; processes=zero; run-root=removed",
        b"PASS: exact two-fresh-boot Book State evidence and cleanup join"))
    (root / "CHECKER.stderr").write_bytes(b"")
    process(root / "checker-child.scm", "evidence-checker-direct-child", 9001)
    process(root / "checker-guardian.scm", "evidence-checker-process-guardian", 9002)
    process(root / "checker-root-guardian.scm", "evidence-checker-root-guardian", 9003)
    manifest = root / "EVIDENCE.sha256"
    members = sorted(
        item.relative_to(root).as_posix()
        for item in root.rglob("*") if item.is_file() and item != manifest
    )
    manifest.write_text("".join(f"{digest(root / name)}  {name}\n" for name in members))
    for item in root.rglob("*"):
        if item.is_file():
            item.chmod(0o400)
    for item in sorted((item for item in root.rglob("*") if item.is_dir()),
                       key=lambda item: len(item.parts), reverse=True):
        item.chmod(0o500)
    root.chmod(0o500)
    return digest(manifest)


def thaw(root: Path) -> None:
    if not root.exists():
        return
    root.chmod(0o700)
    for item in root.rglob("*"):
        if item.is_dir():
            item.chmod(0o700)


def replace_record(path: Path, updates: dict[str, str]) -> None:
    lines = path.read_text().splitlines()
    found = set()
    result = []
    for line in lines:
        key, value = line.split("=", 1)
        if key in updates:
            value = updates[key]
            found.add(key)
        result.append(f"{key}={value}")
    assert found == set(updates)
    path.write_text("\n".join(result) + "\n")


def refresh_boot_reference(root: Path, boot: int) -> None:
    boot_record = root / f"boot{boot}/boot.record"
    replace_record(root / "campaign.record", {
        f"boot{boot}-record-sha256": digest(boot_record),
    })


def make(root: Path) -> str:
    root.mkdir(mode=0o700)
    state_hash = make_state(root / "book-state.ext4")
    authority = {
        "source": "1" * 64, "bundle": "2" * 64, "kernel": "3" * 64,
        "initrd": "4" * 64, "config": "5" * 64, "baseline": "6" * 64,
    }
    initial, post1 = "7" * 64, "8" * 64
    make_boot(root / "boot1", 1, authority, (77, 88, checker.STATE_SIZE),
              initial, post1)
    make_boot(root / "boot2", 2, authority, (77, 88, checker.STATE_SIZE),
              post1, state_hash)
    for boot in (1, 2):
        (root / f"BOOT{boot}-CHECKER.txt").write_text(
            checker.SINGLE_BOOT_SUCCESS.format(boot=boot))
        (root / f"BOOT{boot}-CHECKER.stderr").write_bytes(b"")
        process(root / f"boot{boot}-checker-child.scm",
                "boot-evidence-checker-direct-child", 8000 + boot * 10 + 1)
        process(root / f"boot{boot}-checker-guardian.scm",
                "boot-evidence-checker-process-guardian", 8000 + boot * 10 + 2)
        process(root / f"boot{boot}-checker-root-guardian.scm",
                "boot-evidence-checker-root-guardian", 8000 + boot * 10 + 3)
    (root / "CROSS-CHECKER.txt").write_text(checker.CROSS_BOOT_SUCCESS)
    (root / "CROSS-CHECKER.stderr").write_bytes(b"")
    process(root / "cross-checker-child.scm",
            "cross-evidence-checker-direct-child", 8501)
    process(root / "cross-checker-guardian.scm",
            "cross-evidence-checker-process-guardian", 8502)
    process(root / "cross-checker-root-guardian.scm",
            "cross-evidence-checker-root-guardian", 8503)
    write_record(root / "campaign.record", [
        ("schema", 2), ("status", "pass"),
        ("bundle-id", "synthetic-bundle"),
        ("bundle-manifest-sha256", authority["bundle"]),
        ("source-manifest-sha256", authority["source"]),
        ("guest-source-manifest-sha256", checker.GUEST_SOURCE),
        ("guest-source-snapshot-manifest-sha256", checker.GUEST_SNAPSHOT),
        ("guest-capsule-roster-sha256", checker.GUEST_CAPSULE),
        ("guest-authority-source-sha256", checker.GUEST_AUTHORITY),
        ("guest-contract-sha256", checker.GUEST_CONTRACT),
        ("guest-cooperative-budget-seconds", 300),
        ("hard-vm-deadline-seconds", 360),
        ("term-grace-seconds", 5),
        ("one-boot-owner-hard-deadline-seconds", 420),
        ("timeout-contract-sha256", checker.TIMEOUT_CONTRACT),
        ("campaign-root", "/tmp/opencode/model-campaign/book-state-campaign.fixture"),
        ("campaign-root-device", 70), ("campaign-root-inode", 80),
        ("campaign-root-removed", "true"), ("run-base-empty", "true"),
        ("state-filesystem-label", "WBBookStateV1"),
        ("state-filesystem-size", checker.STATE_SIZE),
        ("writers-released-before-inspection", "true"),
        ("e2fsck-read-only", "pass"), ("initial-state-sha256", initial),
        ("post-boot1-state-sha256", post1),
        ("post-boot2-state-sha256", state_hash),
        ("final-artifact-sha256", state_hash), ("final-artifact-mode", "0400"),
        ("boot1-record-sha256", digest(root / "boot1/boot.record")),
        ("boot2-record-sha256", digest(root / "boot2/boot.record")),
    ])
    return seal_payload(root)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} ROOT")
    print(make(Path(sys.argv[1]).resolve()))
