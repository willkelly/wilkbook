#!/usr/bin/env python3
"""Strict offline checker for one frozen two-fresh-boot evidence payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MAX_LOG = 4 * 1024 * 1024
STATE_SIZE = 64 * 1024 * 1024
STATE_LABEL = b"WBBookStateV1"
READER_JOIN_SOURCE = (
    "6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0"
)
GUEST_SOURCE = (
    "920bacf12f7f5c011671e1c10f1b56afb891cc4c9af387a78e3c74cc5f2d4492"
)
GUEST_SNAPSHOT = (
    "0858d36dae8c720a5e2b754a13592bc1e2cb94cbbe565908c7e653d29720b8bb"
)
GUEST_CAPSULE = (
    "8506c901ac11818550b02fe65c161d4c419c59473d98a62b22a4278c788edcc7"
)
GUEST_AUTHORITY = (
    "f8a30641076d5e10fe4e49d5ee0f2fecf0da82450f5ac90d7137fcbdbb7037fb"
)
GUEST_CONTRACT = (
    "48913fb08fad48bd990266be4505f049c2b6a7884a76353adf0b7971370ad3f4"
)
TIMEOUT_CONTRACT = (
    "e584555b6ef21abc7ab799dee7a3d0d27b4f7869ba5f5a3fb012d2d1ec49708a"
)
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")
FD_NUMBER = r"(?:[3-9]|[1-9][0-9]+)"
PROC_RE = re.compile(rf"/proc/self/fd/({FD_NUMBER})\Z")
OPERATION_RE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
KERNEL_TIME_RE = re.compile(rb"^\[\s*([0-9]+(?:\.[0-9]+)?)\]")

TEXT = {
    "guile": {
        "revision": "reader-note/guile@1",
        "instance": "persistent-note-guile",
        "a": "Mémoire persistante A — 東京 λ\nligne deux",
        "b": "Mémoire persistante B — Αθήνα — café",
    },
    "python": {
        "revision": "reader-note/python@1",
        "instance": "persistent-note-python",
        "a": "Примечание Python A — مرحبا — café",
        "b": "Примечание Python B — 東京 — λ",
    },
}

SANDBOX_CONTAINERS = {
    "guile": "wilkbook-guile-book-state",
    "python": "wilkbook-python-book-state",
}
SANDBOX_BOUNDARY_MARKERS = {
    language: (
        "BOOK_STATE_SANDBOX_BOUNDARY: "
        f"language={language} result=pass storage-mount=absent "
        "storage-fd=absent ui-transport=absent book-session-fd=3"
    ).encode()
    for language in ("guile", "python")
}
SANDBOX_BOUNDARY_MARKER_SHA256 = {
    "guile": "f0aba758a654b7a0d4b88a4268fc33624d9c1d8040c565f597dd0cc8164766c8",
    "python": "5a25153f60b2d1b026692d52eb5ed0070c94394ba123f825b6a0034ee6fefff6",
}
SANDBOX_BOUNDARY_STEM = b"BOOK_STATE_SANDBOX_BOUNDARY"
SANDBOX_SOURCE_STEM = b"BOOK-STATE-GUEST sandbox-boundary-source"

BASE_MARKERS = [
    b"BOOKEXEC-KERNEL-IDENTITY-PASS",
    b"BOOKEXEC-NETWORK-ABSENT-PASS",
    b"BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
    b"BOOKEXEC-RUNSC-VERSION-PASS",
]
FORBIDDEN_CONSOLE = [
    b"BOOK-STATE-GUEST result=fail",
    b"BOOKEXEC-SMOKE-FAIL",
    b"Kernel panic",
    b"BUG:",
    b"Oops:",
]
PRINTK_PREFIX_RE = re.compile(rb"\A\[\s*[0-9]+(?:\.[0-9]+)?\] ")
PLAIN_FAILURE_RE = re.compile(rb"\A[ \t]*FAIL:")
COORDINATOR_SUCCESS = (
    b"BOOK_STATE_QEMU_COORDINATOR: qemu-and-reader=reaped; "
    b"reader-lifecycle=pass; ui-transcript=complete\n"
)
ONE_BOOT_SUCCESS = (
    b"BOOK_STATE_ONE_BOOT: status=pass; semantic=archived; processes=zero; "
    b"run-root=removed\n"
)
SINGLE_BOOT_SUCCESS = (
    "PASS: exact fresh boot {boot} Book State evidence and cleanup join\n"
)
CROSS_BOOT_SUCCESS = "PASS: exact pre-cleanup two-boot cross-lifetime join\n"


class CheckError(Exception):
    pass


@dataclass(frozen=True)
class SandboxBoundaryAttribution:
    language: str
    container: str
    marker_bytes: int
    marker_sha256: str
    capture_bytes: int
    # Provenance asserted by the trusted producer after its stable-FD capture
    # read.  The retained console alone is not the captured stdout byte file, so
    # this checker preserves but does not pretend to recompute this digest.
    capture_sha256: str
    operation: str
    resulting_state_version: int


@dataclass(frozen=True)
class ConsoleEvidence:
    operations: tuple[str, ...]
    sandbox_attributions: tuple[SandboxBoundaryAttribution, ...]


class Symbol(str):
    pass


@dataclass(frozen=True)
class Improper:
    items: tuple[Any, ...]
    tail: Any


class SExpression:
    """Closed reader for the small write(2)-style evidence vocabulary."""

    def __init__(self, data: bytes, label: str):
        if len(data) > MAX_LOG:
            raise CheckError(f"{label}: Scheme record exceeds 4 MiB")
        try:
            self.text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CheckError(f"{label}: Scheme record is not UTF-8") from error
        self.label = label
        self.index = 0

    def fail(self, message: str) -> None:
        raise CheckError(f"{self.label}: {message} at byte {self.index}")

    def skip(self) -> None:
        while self.index < len(self.text) and self.text[self.index].isspace():
            self.index += 1

    def parse(self) -> Any:
        self.skip()
        value = self.value()
        self.skip()
        if self.index != len(self.text):
            self.fail("trailing Scheme data")
        return value

    def value(self) -> Any:
        self.skip()
        if self.index >= len(self.text):
            self.fail("unexpected end of Scheme record")
        head = self.text[self.index]
        if head == "(":
            return self.list_value()
        if head == '"':
            return self.string_value()
        return self.atom_value()

    def list_value(self) -> Any:
        self.index += 1
        values: list[Any] = []
        while True:
            self.skip()
            if self.index >= len(self.text):
                self.fail("unterminated list")
            if self.text[self.index] == ")":
                self.index += 1
                return values
            if self.text[self.index] == ".":
                before = self.text[self.index - 1] if self.index else " "
                after = self.text[self.index + 1] if self.index + 1 < len(self.text) else " "
                if before.isspace() and after.isspace() and values:
                    self.index += 1
                    tail = self.value()
                    self.skip()
                    if self.index >= len(self.text) or self.text[self.index] != ")":
                        self.fail("improper list has more than one tail")
                    self.index += 1
                    return Improper(tuple(values), tail)
            values.append(self.value())

    def string_value(self) -> str:
        self.index += 1
        result: list[str] = []
        while self.index < len(self.text):
            character = self.text[self.index]
            self.index += 1
            if character == '"':
                return "".join(result)
            if character != "\\":
                if ord(character) < 0x20:
                    self.fail("literal control in Scheme string")
                result.append(character)
                continue
            if self.index >= len(self.text):
                self.fail("unterminated string escape")
            escaped = self.text[self.index]
            self.index += 1
            replacements = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
            if escaped in replacements:
                result.append(replacements[escaped])
            elif escaped == "x":
                end = self.text.find(";", self.index)
                if end < 0:
                    self.fail("unterminated hexadecimal string escape")
                token = self.text[self.index:end]
                if not token or not re.fullmatch(r"[0-9a-fA-F]+", token):
                    self.fail("invalid hexadecimal string escape")
                result.append(chr(int(token, 16)))
                self.index = end + 1
            else:
                self.fail("unsupported Scheme string escape")
        self.fail("unterminated Scheme string")
        raise AssertionError

    def atom_value(self) -> Any:
        start = self.index
        while self.index < len(self.text):
            character = self.text[self.index]
            if character.isspace() or character in "()":
                break
            self.index += 1
        token = self.text[start:self.index]
        if not token:
            self.fail("empty atom")
        if token == "#t":
            return True
        if token == "#f":
            return False
        if re.fullmatch(r"-?(?:0|[1-9][0-9]*)", token):
            return int(token)
        if not re.fullmatch(r"[A-Za-z0-9+*/<=>!?$%_&~^:.-]+", token):
            self.fail("atom is outside the closed symbol vocabulary")
        return Symbol(token)


def die(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)


def read_bytes(path: Path, maximum: int = MAX_LOG) -> bytes:
    info = path.lstat()
    die(stat.S_ISREG(info.st_mode), f"not a regular file: {path}")
    die(info.st_nlink == 1, f"retained file is not single-link: {path}")
    die(info.st_size <= maximum, f"retained file exceeds its bound: {path}")
    with path.open("rb", buffering=0) as source:
        value = source.read(maximum + 1)
    die(len(value) <= maximum, f"retained file grew beyond its bound: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb", buffering=0) as source:
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def read_record(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in read_bytes(path).splitlines():
        die(raw and b"=" in raw, f"malformed line record: {path}")
        key_raw, value_raw = raw.split(b"=", 1)
        try:
            key = key_raw.decode("ascii")
            value = value_raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CheckError(f"non-text line record: {path}") from error
        die(re.fullmatch(r"[a-z0-9-]+", key) is not None,
            f"invalid line-record key in {path}")
        die(key not in result, f"duplicate line-record key {key} in {path}")
        die(value != "", f"empty line-record value {key} in {path}")
        result[key] = value
    die(bool(result), f"empty line record: {path}")
    return result


def cdr(entry: Any, label: str) -> Any:
    if isinstance(entry, Improper):
        die(bool(entry.items), f"{label}: empty improper alist entry")
        if len(entry.items) == 1:
            return entry.tail
        return Improper(entry.items[1:], entry.tail)
    die(isinstance(entry, list) and bool(entry), f"{label}: malformed alist entry")
    return entry[1:]


def alist(value: Any, label: str) -> dict[str, Any]:
    die(isinstance(value, list), f"{label}: record is not a proper list")
    result: dict[str, Any] = {}
    for entry in value:
        if isinstance(entry, Improper):
            items = entry.items
        else:
            die(isinstance(entry, list), f"{label}: non-list alist entry")
            items = tuple(entry)
        die(bool(items) and isinstance(items[0], Symbol),
            f"{label}: alist key is not a symbol")
        key = str(items[0])
        die(key not in result, f"{label}: duplicate alist key {key}")
        result[key] = cdr(entry, label)
    return result


def read_alist(path: Path) -> dict[str, Any]:
    return alist(SExpression(read_bytes(path), str(path)).parse(), str(path))


def pair_value(value: Any, label: str) -> tuple[str, int]:
    die(isinstance(value, Improper) and len(value.items) == 1,
        f"{label}: expected one dotted status pair")
    die(isinstance(value.items[0], Symbol) and isinstance(value.tail, int),
        f"{label}: malformed status pair")
    return str(value.items[0]), value.tail


def require_keys(record: dict[str, Any], expected: Iterable[str], label: str) -> None:
    wanted = set(expected)
    die(set(record) == wanted,
        f"{label}: keys differ: missing={sorted(wanted - set(record))} "
        f"extra={sorted(set(record) - wanted)}")


def parse_manifest(path: Path, expected_hash: str) -> dict[str, str]:
    die(SHA256_RE.fullmatch(expected_hash) is not None,
        f"caller did not supply a canonical manifest hash for {path.name}")
    die(sha256(path) == expected_hash, f"{path.name} authentication failed")
    entries: dict[str, str] = {}
    prior: str | None = None
    for raw in read_bytes(path).splitlines():
        die(len(raw) >= 67 and raw[64:66] == b"  ",
            f"malformed {path.name} line")
        try:
            digest = raw[:64].decode("ascii")
            relative = raw[66:].decode("utf-8")
        except UnicodeDecodeError as error:
            raise CheckError(f"non-text {path.name} line") from error
        die(SHA256_RE.fullmatch(digest) is not None,
            f"malformed hash in {path.name}")
        parts = relative.split("/")
        die(relative and not relative.startswith("/") and
            all(part not in ("", ".", "..") for part in parts),
            f"unsafe path in {path.name}: {relative!r}")
        die(prior is None or prior < relative,
            f"{path.name} is not uniquely sorted")
        entries[relative] = digest
        prior = relative
    die(bool(entries), f"empty {path.name}")
    return entries


def inventory(root: Path) -> tuple[list[str], list[str]]:
    files: list[str] = []
    directories: list[str] = []
    for directory, names, filenames in os.walk(root, topdown=True, followlinks=False):
        names.sort()
        filenames.sort()
        base = Path(directory)
        relative_directory = base.relative_to(root).as_posix()
        directories.append("" if relative_directory == "." else relative_directory)
        for name in list(names):
            info = (base / name).lstat()
            die(stat.S_ISDIR(info.st_mode),
                f"evidence contains symlink/special directory entry: {base / name}")
        for name in filenames:
            path = base / name
            info = path.lstat()
            die(stat.S_ISREG(info.st_mode),
                f"evidence contains symlink/special file: {path}")
            files.append(path.relative_to(root).as_posix())
    return sorted(files), sorted(directories)


def authenticate_payload(root: Path, expected_hash: str,
                         final_hash: str | None) -> dict[str, str]:
    payload_path = root / "PAYLOAD.sha256"
    entries = parse_manifest(payload_path, expected_hash)
    for relative, expected in entries.items():
        path = root / relative
        die(path.exists() and sha256(path) == expected,
            f"payload hash mismatch: {relative}")
    files, directories = inventory(root)
    payload_files = sorted([*entries, "PAYLOAD.sha256"])
    if final_hash is None:
        die(files == payload_files,
            "unsealed checker input contains additions or omissions")
    else:
        final_entries = parse_manifest(root / "EVIDENCE.sha256", final_hash)
        die(files == sorted([*final_entries, "EVIDENCE.sha256"]),
            "final evidence inventory differs from its manifest")
        for relative, expected in final_entries.items():
            die(sha256(root / relative) == expected,
                f"final evidence hash mismatch: {relative}")
        die(set(payload_files).issubset(set(final_entries)),
            "final evidence omits payload evidence")
        expected_checker = {
            "CHECKER.txt", "CHECKER.stderr", "checker-child.scm",
            "checker-guardian.scm", "checker-root-guardian.scm",
        }
        die(set(final_entries) - set(payload_files) == expected_checker,
            "final evidence has an unexpected post-payload addition")
        for relative in files:
            info = (root / relative).lstat()
            die(info.st_uid == os.getuid() and info.st_nlink == 1 and
                stat.S_IMODE(info.st_mode) == 0o400,
                f"final evidence file is not owned single-link mode-0400: {relative}")
        for relative in directories:
            path = root if relative == "" else root / relative
            info = path.lstat()
            die(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o500,
                f"final evidence directory is not owned mode-0500: {relative or '.'}")
    return entries


def parse_frame_file(path: Path) -> list[tuple[str, int, str]]:
    data = read_bytes(path, 256 * 1024)
    die(data.endswith(b"\n"), f"private UI transcript lacks terminal newline: {path}")
    result: list[tuple[str, int, str]] = []
    for line in data.splitlines():
        fields = line.split(b"|")
        die(len(fields) == 3, f"malformed private UI frame in {path}")
        kind_raw, generation_raw, encoded = fields
        die(re.fullmatch(rb"[a-z-]+", kind_raw) is not None,
            f"invalid private UI kind in {path}")
        die(re.fullmatch(rb"[1-9][0-9]*", generation_raw) is not None,
            f"noncanonical UI generation in {path}")
        die(len(encoded) % 2 == 0 and re.fullmatch(rb"[0-9a-f]*", encoded) is not None,
            f"noncanonical private UI hexadecimal text in {path}")
        try:
            value = bytes.fromhex(encoded.decode("ascii")).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise CheckError(f"invalid private UI UTF-8 in {path}") from error
        die("\x00" not in value and len(value.encode()) <= 4096,
            f"private UI value outside bounds in {path}")
        result.append((kind_raw.decode("ascii"), int(generation_raw), value))
    return result


def expected_ui(boot: int) -> tuple[list[tuple[str, int, str]],
                                    list[tuple[str, int, str]]]:
    commands: list[tuple[str, int, str]] = []
    events: list[tuple[str, int, str]] = [("channel-ready", 1, "")]
    for generation, language in enumerate(("guile", "python"), 1):
        initial = "" if boot == 1 else TEXT[language]["a"]
        final = TEXT[language]["a"] if boot == 1 else TEXT[language]["b"]
        loaded = "loaded-absent" if boot == 1 else "loaded-value"
        load_command = "load-absent" if boot == 1 else "load-value"
        commands.extend([
            ("open", generation, ""),
            (load_command, generation, initial),
            ("edit", generation, final),
            ("save", generation, ""),
            ("commit-ok", generation, final),
            ("present", generation, final),
            ("close", generation, ""),
        ])
        events.extend([
            ("ready", generation, ""),
            ("status", generation, loaded),
            ("applied", generation, initial),
            ("status", generation, "dirty"),
            ("submit", generation, final),
            ("status", generation, "pending"),
            ("status", generation, "saved"),
            ("applied", generation, final),
            ("closed", generation, ""),
        ])
    commands.append(("finish", 2, ""))
    events.append(("done", 2, "ok"))
    return commands, events


def expected_reader_markers(boot: int) -> list[str]:
    result = [
        "BOOK_STATE_READER: plugin-init:trusted-automated-fixture",
        "BOOK_STATE_READER: private-source-registered",
        "BOOK_STATE_READER: selection-action:registered",
    ]
    for generation, language in enumerate(("guile", "python"), 1):
        initial = "" if boot == 1 else TEXT[language]["a"]
        final = TEXT[language]["a"] if boot == 1 else TEXT[language]["b"]
        loaded = "loaded-absent" if boot == 1 else "loaded-value"
        result.append(f"BOOK_STATE_READER: dialog-shown:generation={generation}")
        if generation == 1:
            result.append("BOOK_STATE_READER: startup-overlays-dismissed:2")
        result.extend([
            f"BOOK_STATE_READER: dialog-ready:generation={generation}",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation={generation}:state={loaded}:text-bytes={len(initial.encode())}",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-presentation:generation={generation}:text-bytes={len(initial.encode())}",
            f"BOOK_STATE_READER: status-painted:generation={generation}:state={loaded}",
            f"BOOK_STATE_READER: presentation-painted:generation={generation}:text-bytes={len(initial.encode())}",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation={generation}:state=dirty:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER: status-painted:generation={generation}:state=dirty",
            f"BOOK_STATE_READER: submit:generation={generation}:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation={generation}:state=pending:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER: status-painted:generation={generation}:state=pending",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation={generation}:state=saved:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER: status-painted:generation={generation}:state=saved",
            f"BOOK_STATE_READER_UI_AUDIT: paintTo-presentation:generation={generation}:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER: presentation-painted:generation={generation}:text-bytes={len(final.encode())}",
            f"BOOK_STATE_READER: closed:generation={generation}",
        ])
    result.extend([
        "BOOK_STATE_READER: selection-action:removed",
        "BOOK_STATE_READER: cleanup-audit:before-quit",
        "BOOK_STATE_READER_UI_AUDIT: cleanup:dialogs-source-fd-action-callback:clean",
        "BOOK_STATE_READER: cleanup-audit:all-generations-clean",
    ])
    return result


def sandbox_source_pattern(language: str) -> re.Pattern[bytes]:
    marker = SANDBOX_BOUNDARY_MARKERS[language]
    marker_hash = SANDBOX_BOUNDARY_MARKER_SHA256[language]
    return re.compile(
        rb"BOOK-STATE-GUEST sandbox-boundary-source language="
        + language.encode()
        + rb" container=" + SANDBOX_CONTAINERS[language].encode()
        + rb" source=owned-finalized-runsc\.stdout "
          rb"publication=next-line-after-child-drain marker-bytes="
        + str(len(marker)).encode()
        + rb" marker-sha256=" + marker_hash.encode()
        + rb" capture-bytes=(?P<capture_bytes>[1-9][0-9]*) "
          rb"capture-sha256=(?P<capture_sha256>[0-9a-f]{64}) "
          rb"operation=(?P<boundary_operation>[A-Za-z0-9_-]{1,128}) "
          rb"resulting-state-version=(?P<resulting_state_version>[1-9][0-9]*)\Z"
    )


def parse_sandbox_source_attribution(
        line: bytes, language: str) -> SandboxBoundaryAttribution:
    match = sandbox_source_pattern(language).fullmatch(line)
    die(match is not None,
        f"{language} sandbox capture attribution is malformed")
    assert match is not None
    capture_bytes = int(match.group("capture_bytes"))
    die(len(SANDBOX_BOUNDARY_MARKERS[language]) + 1 <= capture_bytes <= MAX_LOG,
        f"{language} boundary capture byte count is impossible")
    operation = match.group("boundary_operation").decode("ascii")
    die(OPERATION_RE.fullmatch(operation) is not None,
        f"{language} boundary operation ID is malformed")
    return SandboxBoundaryAttribution(
        language=language,
        container=SANDBOX_CONTAINERS[language],
        marker_bytes=len(SANDBOX_BOUNDARY_MARKERS[language]),
        marker_sha256=SANDBOX_BOUNDARY_MARKER_SHA256[language],
        capture_bytes=capture_bytes,
        capture_sha256=match.group("capture_sha256").decode("ascii"),
        operation=operation,
        resulting_state_version=int(match.group("resulting_state_version")),
    )


def expected_guest_lines(boot: int) -> list[re.Pattern[bytes]]:
    patterns: list[re.Pattern[bytes]] = [
        re.compile(
            rb"BOOK-STATE-GUEST source-provenance=pass "
            rb"accepted-reader-join-source-root=" + READER_JOIN_SOURCE.encode() + rb"\Z"
        )
    ]
    for language in ("guile", "python"):
        if boot == 1:
            patterns.append(re.compile(
                f"BOOK-STATE-GUEST language={language} read=absent version=0 bytes=0 ui-painted=true".encode()
                + rb"\Z"))
        else:
            size = len(TEXT[language]["a"].encode())
            patterns.append(re.compile(
                f"BOOK-STATE-GUEST language={language} read=a version=1 bytes={size} ui-painted=true".encode()
                + rb"\Z"))
            patterns.append(re.compile(
                f"BOOK-STATE-GUEST language={language} recovered=A-before-save=true".encode()
                + rb"\Z"))
        saved = "A" if boot == 1 else "B"
        version = boot
        patterns.append(re.compile(
            f"BOOK-STATE-GUEST language={language} saved={saved} version={version} operation=".encode()
            + rb"(?P<saved_operation>[A-Za-z0-9_-]{1,128})\Z"))
        patterns.append(sandbox_source_pattern(language))
    receipts = 2 if boot == 1 else 4
    patterns.extend([
        re.compile(
            rb"BOOK-STATE-GUEST inspector-path=/var/lib/wilkbook-book-state-demo/book-state-v1\.sqlite "
            + f"namespaces=2 receipts={receipts} quick-check=ok foreign-keys=ok sidecars=none".encode()
            + rb"\Z"
        ),
        re.compile(
            f"BOOK-STATE-GUEST result=pass initial-stage={'absent' if boot == 1 else 'a'} "
            f"final-versions={boot},{boot}".encode() + rb"\Z"
        ),
    ])
    return patterns


def console_payload(line: bytes) -> bytes:
    """Remove only the canonical printk timestamp framing used by this guest."""
    match = PRINTK_PREFIX_RE.match(line)
    return line[match.end():] if match is not None else line


def console_failure_line(line: bytes) -> bool:
    payload = console_payload(line)
    return (
        PLAIN_FAILURE_RE.match(payload) is not None
        or payload.startswith(b"BOOK-STATE-GUEST result=fail")
        or payload.startswith(b"BOOKEXEC-SMOKE-FAIL")
    )


def check_console(path: Path, boot: int) -> ConsoleEvidence:
    data = read_bytes(path)
    for fragment in FORBIDDEN_CONSOLE:
        die(fragment not in data, f"boot {boot} console contains {fragment!r}")
    lines = [line.rstrip(b"\r") for line in data.split(b"\n")]
    die(not any(console_failure_line(line) for line in lines),
        f"boot {boot} console contains a framed failure production")
    positions: list[int] = []
    for marker in BASE_MARKERS:
        found = [index for index, line in enumerate(lines) if line == marker]
        die(len(found) == 1, f"boot {boot} lacks one exact {marker!r}")
        positions.append(found[0])
    die(positions == sorted(positions) and len(set(positions)) == len(positions),
        f"boot {boot} base guest markers are reordered")
    guest = [line for line in lines if line.startswith(b"BOOK-STATE-GUEST ")]
    patterns = expected_guest_lines(boot)
    die(len(guest) == len(patterns),
        f"boot {boot} has extra or missing Book State guest markers")
    operations: list[str] = []
    saved_results: dict[str, tuple[str, int]] = {}
    for line, pattern in zip(guest, patterns):
        match = pattern.fullmatch(line)
        die(match is not None,
            f"boot {boot} Book State marker is malformed/reordered: {line!r}")
        operation_raw = match.groupdict().get("saved_operation")
        if operation_raw is not None:
            operation = operation_raw.decode("ascii")
            die(OPERATION_RE.fullmatch(operation) is not None,
                f"boot {boot} operation ID is malformed")
            operations.append(operation)
            language = line.split(b" language=", 1)[1].split(b" ", 1)[0].decode()
            saved_results[language] = (operation, boot)

    reserved_boundary = [
        (index, line) for index, line in enumerate(lines)
        if SANDBOX_BOUNDARY_STEM in line
    ]
    reserved_source = [
        (index, line) for index, line in enumerate(lines)
        if SANDBOX_SOURCE_STEM in line
    ]
    die(len(reserved_boundary) == 2,
        f"boot {boot} does not contain exactly two actual sandbox boundary records")
    die(len(reserved_source) == 2,
        f"boot {boot} does not contain exactly two sandbox capture attributions")
    boundary_positions: list[int] = []
    attributions: list[SandboxBoundaryAttribution] = []
    for expected_index, language in enumerate(("guile", "python")):
        source_index, source_line = reserved_source[expected_index]
        marker_index, marker_line = reserved_boundary[expected_index]
        attribution = parse_sandbox_source_attribution(source_line, language)
        die(marker_line == SANDBOX_BOUNDARY_MARKERS[language],
            f"boot {boot} {language} sandbox boundary record is not exact pass")
        die(marker_index == source_index + 1,
            f"boot {boot} {language} actual boundary record does not immediately follow its attribution")
        die(language in saved_results and
            attribution.operation == saved_results[language][0] and
            attribution.resulting_state_version == saved_results[language][1] == boot,
            f"boot {boot} {language} sandbox attribution does not name its preceding save result")
        boundary_positions.append(marker_index)
        attributions.append(attribution)

    semantic_positions = {
        language: {
            "read": next(index for index, line in enumerate(lines)
                         if line.startswith(
                             f"BOOK-STATE-GUEST language={language} read=".encode())),
            "saved": next(index for index, line in enumerate(lines)
                          if line.startswith(
                              f"BOOK-STATE-GUEST language={language} saved=".encode())),
        }
        for language in ("guile", "python")
    }
    inspector_position = next(
        index for index, line in enumerate(lines)
        if line.startswith(b"BOOK-STATE-GUEST inspector-path=")
    )
    result_position = next(
        index for index, line in enumerate(lines)
        if line.startswith(b"BOOK-STATE-GUEST result=pass ")
    )
    die(semantic_positions["guile"]["read"] <
        semantic_positions["guile"]["saved"] < reserved_source[0][0] <
        boundary_positions[0] < semantic_positions["python"]["read"] <
        semantic_positions["python"]["saved"] < reserved_source[1][0] <
        boundary_positions[1] < inspector_position < result_position,
        f"boot {boot} sandbox relay is outside its actual owned language phase")
    guest_positions = [index for index, line in enumerate(lines)
                       if line.startswith(b"BOOK-STATE-GUEST ")]
    die(len(guest_positions) >= 2 and guest_positions[0] < positions[0] and
        positions[-1] < guest_positions[1] and
        guest_positions == sorted(guest_positions),
        f"boot {boot} source/base/semantic marker chain is reordered")
    shutdown = [index for index, line in enumerate(lines)
                if line == b"book-state guest exited with status 0; requesting shutdown"]
    # Shepherd captures the service's current-error-port; that source line is
    # not part of the UART stream.  Pin the real transport rather than requiring
    # a record no production boot can archive.  Clean completion is still
    # independently required above and by the status-0 owner/coordinator records.
    die(not shutdown,
        f"boot {boot} unexpectedly contains the non-console service status line")
    power = [index for index, line in enumerate(lines)
             if re.fullmatch(rb"(?:\[\s*[0-9]+(?:\.[0-9]+)?\] )?reboot: Power down", line)]
    die(len(power) == 1 and result_position < power[0],
        f"boot {boot} lacks one canonical power-down after guest success")
    linux = [line for line in lines if b"Linux version " in line]
    die(len(linux) == 1, f"boot {boot} is not one kernel lifetime")
    timestamps = []
    for line in lines:
        match = KERNEL_TIME_RE.match(line)
        if match:
            timestamps.append(float(match.group(1)))
    die(bool(timestamps) and min(timestamps) <= 1.0 and max(timestamps) > 1.0,
        f"boot {boot} console does not show a restarted kernel clock")
    return ConsoleEvidence(tuple(operations), tuple(attributions))


def check_reader_log(path: Path, boot: int) -> None:
    try:
        lines = read_bytes(path, 128 * 1024).decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise CheckError(f"boot {boot} reader log is not UTF-8") from error
    die(not any("FAIL:" in line or "Saving failed." in line for line in lines),
        f"boot {boot} reader log contains failure text")
    version = [line for line in lines if line == " [*] Version: v2026.03"]
    die(len(version) == 1, f"boot {boot} reader version marker differs")
    fd_line = "BOOK_STATE_QEMU_SPAWN: koreader:exec-fd-hygiene:stdio-and-ui-fd3-only"
    die(lines.count(fd_line) == 1, f"boot {boot} KOReader FD-3 boundary differs")
    semantic = [line for line in lines
                if line.startswith("BOOK_STATE_READER: ") or
                line.startswith("BOOK_STATE_READER_UI_AUDIT: ")]
    die(semantic == expected_reader_markers(boot),
        f"boot {boot} reader widget/paint lifecycle is malformed, extra, or reordered")


def path_token(record: dict[str, str], key: str) -> str:
    value = record[key]
    die(value.startswith("/tmp/opencode/") and os.path.isabs(value) and
        "\x00" not in value and "\n" not in value and "\r" not in value,
        f"unsafe evidence path in {key}")
    return value


def positive(record: dict[str, str], key: str) -> int:
    value = record[key]
    die(re.fullmatch(r"[1-9][0-9]*", value) is not None,
        f"{key} is not a canonical positive integer")
    return int(value)


PROCESS_PREFIXES = [
    "owner", "owner-guardian", "launch-root-guardian", "coordinator",
    "coordinator-guardian", "ephemeral-root-guardian", "qemu", "reader",
]


def process_pairs(record: dict[str, str]) -> list[tuple[int, str]]:
    result = []
    for prefix in PROCESS_PREFIXES:
        pid = positive(record, f"{prefix}-pid")
        start = record[f"{prefix}-start-time"]
        die(re.fullmatch(r"[1-9][0-9]*", start) is not None,
            f"{prefix} start time is not canonical")
        result.append((pid, start))
    die(len(set(result)) == len(result), "one boot reuses a host process identity")
    return result


def process_alist(path: Path, role: str) -> tuple[int, str]:
    record = read_alist(path)
    require_keys(record, ("schema", "role", "pid", "start-time"), str(path))
    die(record["schema"] == 1 and record["role"] == Symbol(role),
        f"process record role/schema differs: {path}")
    die(isinstance(record["pid"], int) and record["pid"] > 0 and
        isinstance(record["start-time"], str) and
        re.fullmatch(r"[1-9][0-9]*", record["start-time"]) is not None,
        f"process identity is malformed: {path}")
    return record["pid"], record["start-time"]


def exec_record(path: Path, role: str, expected: tuple[int, str],
                run_root: str, state: tuple[int, int, int]) -> None:
    record = read_alist(path)
    keys = (
        "schema", "role", "pid", "start-time", "process-group",
        "guarded-root", "guarded-root-device", "guarded-root-inode",
        "state-proc-file", "state-fd", "state-device", "state-inode",
        "state-size", "anchor-fd", "anchor-cloexec",
        "non-cloexec-above-stderr",
    )
    require_keys(record, keys, str(path))
    die(record["schema"] == 1 and record["role"] == Symbol(role),
        f"exec record role/schema differs: {path}")
    die((record["pid"], record["start-time"]) == expected,
        f"exec identity differs from guarded direct child: {path}")
    die(record["process-group"] == record["pid"],
        f"exec child is not its accepted owned process group: {path}")
    die(record["guarded-root"] == run_root,
        f"exec record names another guarded root: {path}")
    match = PROC_RE.fullmatch(record["state-proc-file"])
    die(match is not None and int(match.group(1)) == record["state-fd"],
        f"exec record has a noncanonical state descriptor: {path}")
    die((record["state-device"], record["state-inode"], record["state-size"]) == state,
        f"exec record names another state image: {path}")
    die(record["anchor-cloexec"] is True and
        isinstance(record["anchor-fd"], int) and record["anchor-fd"] > 2 and
        record["anchor-fd"] != record["state-fd"],
        f"exec record lacks its private CLOEXEC anchor: {path}")
    die(record["non-cloexec-above-stderr"] == [record["state-fd"]],
        f"exec record allowlist is not exactly the state OFD: {path}")


def expected_graph(arguments: list[str], boot_record: dict[str, str]) -> list[str]:
    die(bool(arguments), "empty QEMU argument vector")
    qemu = arguments[0]
    run_root = boot_record["run-root"]
    kernel = f"{run_root}/boot/Image"
    initrd = f"{run_root}/boot/initrd.cpio.gz"
    overlay = f"{run_root}/disk-overlay.qcow2"
    state_values = [value for value in arguments if value.startswith(
        '{"driver":"file","filename":"/proc/self/fd/') and
        '"node-name":"book-state-file"' in value]
    die(len(state_values) == 1, "graph lacks one state file node")
    state_match = re.fullmatch(
        rf'\{{"driver":"file","filename":"(/proc/self/fd/{FD_NUMBER})",'
        r'"node-name":"book-state-file","read-only":false,"locking":"on"\}',
        state_values[0],
    )
    die(state_match is not None and PROC_RE.fullmatch(state_match.group(1)) is not None,
        "state graph does not use one canonical inherited descriptor")
    state_proc = state_match.group(1)
    append_indexes = [index for index, value in enumerate(arguments) if value == "-append"]
    die(len(append_indexes) == 1 and append_indexes[0] + 1 < len(arguments),
        "graph does not have one APPEND value")
    append = arguments[append_indexes[0] + 1]
    overlay_file = json.dumps({
        "driver": "file", "filename": overlay,
        "node-name": "rootfs-overlay-file", "read-only": False,
    }, separators=(",", ":"))
    overlay_format = json.dumps({
        "driver": "qcow2", "file": "rootfs-overlay-file",
        "node-name": "rootfs-overlay", "read-only": False,
    }, separators=(",", ":"))
    state_file = json.dumps({
        "driver": "file", "filename": state_proc,
        "node-name": "book-state-file", "read-only": False, "locking": "on",
    }, separators=(",", ":"))
    state_raw = json.dumps({
        "driver": "raw", "file": "book-state-file",
        "node-name": "book-state", "read-only": False,
    }, separators=(",", ":"))
    return [
        qemu, "-no-user-config", "-nodefaults", "-M", "virt", "-accel",
        "tcg,thread=multi", "-cpu", "max", "-smp", "2", "-m", "512",
        "-display", "none", "-no-reboot", "-nic", "none", "-monitor", "none",
        "-chardev",
        f"socket,id=console0,path={run_root}/console.sock,server=on,wait=off,"
        f"logfile={run_root}/console.log,logappend=off",
        "-serial", "chardev:console0",
        "-chardev",
        f"socket,id=bookui0,path={run_root}/book-ui.sock,server=on,wait=off",
        "-device", "virtio-serial-pci,id=book-ui-serial",
        "-device", "virtserialport,id=book-ui-port,chardev=bookui0,"
        "name=org.wilkbook.book-interaction",
        "-kernel", kernel, "-initrd", initrd, "-append", append,
        "-blockdev", overlay_file, "-blockdev", overlay_format,
        "-device", "virtio-blk-pci,drive=rootfs-overlay",
        "-blockdev", state_file, "-blockdev", state_raw,
        "-device", "virtio-blk-pci,drive=book-state,id=book-state-disk,"
        "serial=WBBOOKSTATEV1",
    ]


def check_graph(path: Path, boot_record: dict[str, str],
                state: tuple[int, int, int]) -> list[str]:
    record = read_alist(path)
    require_keys(record, (
        "schema", "unpaused", "vcpus", "memory-mib", "state-device",
        "state-inode", "state-size", "arguments",
    ), str(path))
    die(record["schema"] == 1 and record["unpaused"] is True and
        record["vcpus"] == 2 and record["memory-mib"] == 512,
        "QEMU graph resource/pause record differs")
    die((record["state-device"], record["state-inode"], record["state-size"]) == state,
        "QEMU graph state identity differs")
    arguments = record["arguments"]
    die(isinstance(arguments, list) and all(isinstance(item, str) for item in arguments),
        "QEMU graph arguments are not a string vector")
    die(arguments == expected_graph(arguments, boot_record),
        "QEMU graph differs from accepted reader + descriptor state graph")
    joined = "\n".join(arguments)
    for fragment in (
        "-S", "-snapshot", "snapshot=on", "cache.no-flush=on", "locking=off",
        "hostfwd=", "guestfwd=", "user,id=", "tap,id=", "virtio-9p",
        "virtiofs", "vhost-user-fs", "-virtfs", "-fsdev", "-qmp",
        "-incoming", "-monitor tcp:", "-chardev tcp",
    ):
        die(fragment not in joined, f"QEMU graph contains forbidden {fragment!r}")
    for language in TEXT.values():
        for forbidden in (language["revision"], language["instance"],
                          language["a"], language["b"]):
            die(forbidden not in joined,
                "QEMU argv injects a namespace or semantic value")
    check_root_handoff(arguments[arguments.index("-append") + 1])
    return arguments


def check_root_handoff(append: str) -> None:
    roots = [token for token in append.split() if token.startswith("root=")]
    die(roots == ["root=PNGuixRoot"],
        "QEMU kernel command line must contain exactly one Guix-native root label")


BOOT_FIXED_FILES = {
    "boot.record", "coordinator-child.scm", "coordinator-exec.scm",
    "coordinator-guardian.scm", "launch-root-guardian.scm",
    "one-boot.stderr", "one-boot.stdout", "owner-child.scm", "owner-exec.scm",
    "owner-guardian.scm", "qemu-graph.scm", "run-root-guardian.scm", "run.scm",
    "run/console.log", "run/qemu.stderr", "run/qemu.stdout",
    "run/reader-ui/coordinator-result.scm", "run/reader-ui/qemu.pid",
    "run/reader-ui/qemu.stderr", "run/reader-ui/qemu.stdout",
    "run/reader-ui/reader.log", "run/reader-ui/reader.pid",
    "run/reader-ui/ui-guest-to-reader.bin", "run/reader-ui/ui-proxy.scm",
    "run/reader-ui/ui-reader-to-guest.bin",
}


def check_boot_inventory(root: Path) -> None:
    observed = {path.relative_to(root).as_posix()
                for path in root.rglob("*") if path.is_file()}
    inner = {
        f"inner-{index:03d}-{kind}.scm"
        for index in range(1, 11) for kind in ("guardian", "child")
    }
    die(observed == BOOT_FIXED_FILES | inner,
        f"boot evidence inventory differs: missing={sorted((BOOT_FIXED_FILES | inner) - observed)} "
        f"extra={sorted(observed - (BOOT_FIXED_FILES | inner))}")
    expected_directories = {"run", "run/reader-ui"}
    observed_directories = {
        path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_dir()
    }
    die(observed_directories == expected_directories,
        "boot evidence directory inventory differs")


def check_boot(root: Path, boot: int, campaign: dict[str, str]) -> dict[str, Any]:
    check_boot_inventory(root)
    record = read_record(root / "boot.record")
    fixed = {
        "schema", "boot-index", "boot-id", "status", "timed-out",
        "hard-vm-timed-out", "owner-timed-out",
        "guest-source-manifest-sha256",
        "guest-source-snapshot-manifest-sha256",
        "guest-capsule-roster-sha256", "guest-authority-source-sha256",
        "guest-contract-sha256",
        "two-boot-timeout-contract-sha256",
        "guest-cooperative-budget-seconds", "hard-vm-deadline-seconds",
        "term-grace-seconds", "one-boot-owner-hard-deadline-seconds",
        "root-filesystem-label",
        "state-filesystem-label", "source-manifest-sha256",
        "bundle-manifest-sha256", "kernel-sha256", "initrd-sha256",
        "config-sha256", "baseline-sha256", "qemu-graph-sha256", "run-root",
        "run-root-device", "run-root-inode", "overlay-device", "overlay-inode",
        "state-device", "state-inode", "state-size", "state-hash-before",
        "state-hash-after",
    }
    process_fields = {
        f"{prefix}-{suffix}" for prefix in PROCESS_PREFIXES
        for suffix in ("pid", "start-time")
    }
    require_keys(record, fixed | process_fields, f"boot {boot} record")
    die(record["schema"] == "1" and record["boot-index"] == str(boot) and
        record["status"] == "pass" and record["timed-out"] == "false" and
        record["hard-vm-timed-out"] == "false" and
        record["owner-timed-out"] == "false",
        f"boot {boot} disposition is not exact success")
    die(record["guest-cooperative-budget-seconds"] == "300" and
        record["hard-vm-deadline-seconds"] == "360" and
        record["term-grace-seconds"] == "5" and
        record["one-boot-owner-hard-deadline-seconds"] == "420",
        f"boot {boot} timeout layers differ")
    die(record["guest-source-manifest-sha256"] == GUEST_SOURCE and
        record["guest-source-snapshot-manifest-sha256"] == GUEST_SNAPSHOT and
        record["guest-capsule-roster-sha256"] == GUEST_CAPSULE and
        record["guest-authority-source-sha256"] == GUEST_AUTHORITY and
        record["guest-contract-sha256"] == GUEST_CONTRACT and
        record["two-boot-timeout-contract-sha256"] == TIMEOUT_CONTRACT,
        f"boot {boot} is not bound to the exact accepted guest capsule and timeout contract")
    die(record["root-filesystem-label"] == "PNGuixRoot" and
        record["state-filesystem-label"] == "WBBookStateV1",
        f"boot {boot} filesystem labels differ")
    for key in (
        "source-manifest-sha256", "bundle-manifest-sha256", "kernel-sha256",
        "initrd-sha256", "config-sha256", "baseline-sha256",
        "qemu-graph-sha256", "state-hash-before", "state-hash-after",
    ):
        die(SHA256_RE.fullmatch(record[key]) is not None,
            f"boot {boot} {key} is not SHA-256")
    die(record["source-manifest-sha256"] == campaign["source-manifest-sha256"] and
        record["bundle-manifest-sha256"] == campaign["bundle-manifest-sha256"],
        f"boot {boot} source/bundle authority differs from campaign")
    run_root = path_token(record, "run-root")
    die(Path(run_root).name.startswith("book-execution-qemu."),
        f"boot {boot} run root is not fresh accepted naming")
    state = (positive(record, "state-device"), positive(record, "state-inode"),
             positive(record, "state-size"))
    die(state[2] == STATE_SIZE, f"boot {boot} state image size differs")
    for key in ("run-root-device", "run-root-inode", "overlay-device", "overlay-inode"):
        positive(record, key)
    pairs = process_pairs(record)

    role_files = {
        "owner-child.scm": "one-boot-owner-child",
        "owner-guardian.scm": "one-boot-owner-guardian",
        "launch-root-guardian.scm": "boot-launch-root-guardian",
        "coordinator-child.scm": "coordinator-direct-child",
        "coordinator-guardian.scm": "coordinator-process-guardian",
        "run-root-guardian.scm": "ephemeral-run-root-guardian",
    }
    prefix_for = {
        "owner-child.scm": "owner", "owner-guardian.scm": "owner-guardian",
        "launch-root-guardian.scm": "launch-root-guardian",
        "coordinator-child.scm": "coordinator",
        "coordinator-guardian.scm": "coordinator-guardian",
        "run-root-guardian.scm": "ephemeral-root-guardian",
    }
    for name, role in role_files.items():
        prefix = prefix_for[name]
        observed = process_alist(root / name, role)
        expected = (positive(record, f"{prefix}-pid"),
                    record[f"{prefix}-start-time"])
        die(observed == expected, f"boot {boot} process record disagrees: {name}")
    inner_pairs: list[tuple[int, str]] = []
    for index in range(1, 11):
        guardian = process_alist(
            root / f"inner-{index:03d}-guardian.scm",
            "accepted-inner-process-guardian")
        child = process_alist(
            root / f"inner-{index:03d}-child.scm",
            "accepted-inner-direct-child")
        die(guardian != child, f"boot {boot} inner guardian aliases its child")
        inner_pairs.extend((guardian, child))
    die(process_alist(root / "inner-010-guardian.scm",
                      "accepted-inner-process-guardian") ==
        (positive(record, "coordinator-guardian-pid"),
         record["coordinator-guardian-start-time"]),
        f"boot {boot} coordinator guardian is not the tenth accepted invocation")
    die(process_alist(root / "inner-010-child.scm",
                      "accepted-inner-direct-child") ==
        (positive(record, "coordinator-pid"), record["coordinator-start-time"]),
        f"boot {boot} coordinator is not the tenth accepted invocation")
    independently_fresh = pairs + inner_pairs[:-2]
    die(len(set(independently_fresh)) == len(independently_fresh),
        f"boot {boot} reuses an inner supervisor/process identity")

    launch_record = read_alist(root / "owner-exec.scm")
    launch_root = launch_record.get("guarded-root")
    die(isinstance(launch_root, str), f"boot {boot} owner exec root is absent")
    exec_record(root / "owner-exec.scm", "one-boot-owner-exec",
                (positive(record, "owner-pid"), record["owner-start-time"]),
                launch_root, state)
    exec_record(root / "coordinator-exec.scm", "coordinator-exec-child",
                (positive(record, "coordinator-pid"),
                 record["coordinator-start-time"]), run_root, state)

    run = read_alist(root / "run.scm")
    require_keys(run, (
        "schema", "disposition", "unpaused", "vcpus", "memory-mib",
        "hard-vm-deadline-seconds", "term-grace-seconds", "run-root",
        "run-root-device", "run-root-inode", "overlay-device", "overlay-inode",
        "state-device", "state-inode", "state-size",
        "hard-vm-owner-result-observed", "hard-vm-owner-status",
        "hard-vm-owner-timed-out",
    ), f"boot {boot} run record")
    die(run["schema"] == 1 and run["disposition"] == Symbol("semantic-success") and
        run["unpaused"] is True and run["vcpus"] == 2 and run["memory-mib"] == 512 and
        run["hard-vm-deadline-seconds"] == 360 and run["term-grace-seconds"] == 5,
        f"boot {boot} run disposition/resources differ")
    die(run["hard-vm-owner-result-observed"] is True and
        run["hard-vm-owner-status"] == 0 and
        run["hard-vm-owner-timed-out"] is False,
        f"boot {boot} hard VM owner did not report exact non-timeout success")
    die(run["run-root"] == run_root and
        (run["state-device"], run["state-inode"], run["state-size"]) == state,
        f"boot {boot} run record identity differs")

    graph_path = root / "qemu-graph.scm"
    die(sha256(graph_path) == record["qemu-graph-sha256"],
        f"boot {boot} graph hash differs")
    graph = check_graph(graph_path, record, state)

    reader_root = root / "run/reader-ui"
    coordinator = read_alist(reader_root / "coordinator-result.scm")
    require_keys(coordinator, (
        "schema", "state-device", "state-inode", "state-size",
        "coordinator-pid", "coordinator-process-group", "qemu-pid",
        "qemu-start-time", "qemu-process-group", "qemu-status", "reader-pid",
        "reader-start-time", "reader-process-group", "reader-status",
        "children-zero", "ui-proxy",
    ), f"boot {boot} coordinator record")
    die(coordinator["schema"] == 1 and coordinator["children-zero"] is True and
        pair_value(coordinator["qemu-status"], "qemu status") == ("exit", 0) and
        pair_value(coordinator["reader-status"], "reader status") == ("exit", 0),
        f"boot {boot} coordinator child status differs")
    die((coordinator["state-device"], coordinator["state-inode"],
         coordinator["state-size"]) == state,
        f"boot {boot} coordinator state identity differs")
    die((coordinator["qemu-pid"], coordinator["qemu-start-time"]) ==
        (positive(record, "qemu-pid"), record["qemu-start-time"]) and
        (coordinator["reader-pid"], coordinator["reader-start-time"]) ==
        (positive(record, "reader-pid"), record["reader-start-time"]),
        f"boot {boot} coordinator process identity differs")
    expected_group = positive(record, "coordinator-pid")
    die(coordinator["coordinator-pid"] == expected_group and
        coordinator["coordinator-process-group"] == expected_group and
        coordinator["qemu-process-group"] == expected_group and
        coordinator["reader-process-group"] == expected_group,
        f"boot {boot} QEMU/reader are not direct coordinator-owned-group children")

    def simple_pid(path: Path) -> tuple[int, str]:
        fields = read_bytes(path).decode("ascii").strip().split(" ")
        die(len(fields) == 2 and all(re.fullmatch(r"[1-9][0-9]*", item) for item in fields),
            f"malformed coordinator PID record: {path}")
        return int(fields[0]), fields[1]

    die(simple_pid(reader_root / "qemu.pid") ==
        (positive(record, "qemu-pid"), record["qemu-start-time"]),
        f"boot {boot} QEMU PID evidence differs")
    die(simple_pid(reader_root / "reader.pid") ==
        (positive(record, "reader-pid"), record["reader-start-time"]),
        f"boot {boot} reader PID evidence differs")

    guest_to_reader = reader_root / "ui-guest-to-reader.bin"
    reader_to_guest = reader_root / "ui-reader-to-guest.bin"
    expected_commands, expected_events = expected_ui(boot)
    die(parse_frame_file(guest_to_reader) == expected_commands,
        f"boot {boot} guest-to-reader semantic transcript differs")
    die(parse_frame_file(reader_to_guest) == expected_events,
        f"boot {boot} reader-to-guest semantic transcript differs")
    proxy = read_alist(reader_root / "ui-proxy.scm")
    embedded = alist(coordinator["ui-proxy"], f"boot {boot} embedded proxy")
    for item, label in ((proxy, "proxy"), (embedded, "embedded proxy")):
        require_keys(item, (
            "schema", "guest-to-reader-bytes", "reader-to-guest-bytes",
            "guest-to-reader-eof", "reader-to-guest-eof", "complete",
        ), f"boot {boot} {label}")
        die(item["schema"] == 1 and item["guest-to-reader-eof"] is True and
            item["reader-to-guest-eof"] is True and item["complete"] is True and
            item["guest-to-reader-bytes"] == guest_to_reader.stat().st_size and
            item["reader-to-guest-bytes"] == reader_to_guest.stat().st_size,
            f"boot {boot} {label} byte/EOF record differs")
    die(proxy == embedded, f"boot {boot} duplicate proxy records disagree")

    check_reader_log(reader_root / "reader.log", boot)
    console_evidence = check_console(root / "run/console.log", boot)
    die(read_bytes(root / "run/qemu.stdout") == COORDINATOR_SUCCESS,
        f"boot {boot} coordinator success line differs")
    die(read_bytes(root / "run/qemu.stderr") == b"",
        f"boot {boot} coordinator stderr is not empty")
    die(read_bytes(root / "one-boot.stdout") == ONE_BOOT_SUCCESS,
        f"boot {boot} one-boot success line differs")
    die(read_bytes(root / "one-boot.stderr") == b"",
        f"boot {boot} one-boot stderr is not empty")
    qemu_output = read_bytes(reader_root / "qemu.stdout")
    die(qemu_output.splitlines().count(
        b"BOOK_STATE_QEMU_SPAWN: qemu:exec-fd-hygiene:stdio-and-state-ofd-only") == 1,
        f"boot {boot} QEMU descriptor marker differs")
    die(b"BOOK_STATE_QEMU_COORDINATOR: FAIL:" not in
        read_bytes(reader_root / "qemu.stderr"),
        f"boot {boot} QEMU/coordinator failure marker is present")
    return {
        "record": record, "state": state, "pairs": independently_fresh,
        "graph": graph, "operations": list(console_evidence.operations),
        "sandbox-attributions": console_evidence.sandbox_attributions,
    }


def check_single_boot(root: Path, boot: int) -> None:
    die(boot in (1, 2), "single-boot index must be 1 or 2")
    die(root.is_absolute() and str(root).startswith("/tmp/opencode/") and
        root.resolve() == root and stat.S_ISDIR(root.lstat().st_mode),
        "single-boot evidence root must be canonical under /tmp/opencode")
    record = read_record(root / "boot.record")
    result = check_boot(root, boot, {
        "source-manifest-sha256": record.get("source-manifest-sha256", ""),
        "bundle-manifest-sha256": record.get("bundle-manifest-sha256", ""),
    })
    die(result["record"]["state-hash-before"] !=
        result["record"]["state-hash-after"],
        f"boot {boot} did not mutate the persistent state image")
    die(len(result["operations"]) == 2 and
        len(set(result["operations"])) == 2,
        f"boot {boot} does not contain two distinct durable operation IDs")


def check_boot_checker_records(root: Path) -> list[tuple[int, str]]:
    pairs: list[tuple[int, str]] = []
    for boot in (1, 2):
        die(read_bytes(root / f"BOOT{boot}-CHECKER.txt") ==
            SINGLE_BOOT_SUCCESS.format(boot=boot).encode() and
            read_bytes(root / f"BOOT{boot}-CHECKER.stderr") == b"",
            f"boot {boot} retained strict-checker output differs")
        pairs.extend([
            process_alist(root / f"boot{boot}-checker-child.scm",
                          "boot-evidence-checker-direct-child"),
            process_alist(root / f"boot{boot}-checker-guardian.scm",
                          "boot-evidence-checker-process-guardian"),
            process_alist(root / f"boot{boot}-checker-root-guardian.scm",
                          "boot-evidence-checker-root-guardian"),
        ])
    return pairs


def normalize_graph(arguments: list[str], record: dict[str, str]) -> list[str]:
    run_root = record["run-root"]
    result = []
    for value in arguments:
        value = value.replace(run_root, "$RUN_ROOT")
        value = re.sub(rf"/proc/self/fd/{FD_NUMBER}",
                       "/proc/self/fd/$STATE_FD", value)
        result.append(value)
    return result


def check_cross_relations(root: Path, first: dict[str, Any],
                          second: dict[str, Any]) -> list[tuple[int, str]]:
    first_record = first["record"]
    second_record = second["record"]
    die(first_record["boot-id"] != second_record["boot-id"] and
        re.fullmatch(r"[0-9a-f]{32}", first_record["boot-id"]) is not None and
        re.fullmatch(r"[0-9a-f]{32}", second_record["boot-id"]) is not None,
        "campaign boot evidence IDs are not distinct canonical values")
    die(first["state"] == second["state"],
        "the two boots do not name the same state image identity")
    die(first_record["state-hash-after"] == second_record["state-hash-before"] and
        len({first_record["state-hash-before"], first_record["state-hash-after"],
             second_record["state-hash-after"]}) == 3,
        "state hash chain does not prove two sequential mutations")
    die(first_record["run-root"] != second_record["run-root"] and
        (first_record["run-root-device"], first_record["run-root-inode"]) !=
        (second_record["run-root-device"], second_record["run-root-inode"]) and
        (first_record["overlay-device"], first_record["overlay-inode"]) !=
        (second_record["overlay-device"], second_record["overlay-inode"]),
        "run roots or root overlays were reused")
    die(set(first["pairs"]).isdisjoint(second["pairs"]),
        "host process identities were reused across boots")
    for key in ("kernel-sha256", "initrd-sha256", "config-sha256",
                 "baseline-sha256", "guest-source-manifest-sha256",
                 "guest-source-snapshot-manifest-sha256",
                 "guest-capsule-roster-sha256", "guest-authority-source-sha256",
                 "guest-contract-sha256", "two-boot-timeout-contract-sha256"):
        die(first_record[key] == second_record[key],
            f"authenticated boot/guest authority differs across boots: {key}")
    die(normalize_graph(first["graph"], first_record) ==
        normalize_graph(second["graph"], second_record),
        "QEMU graph differs across boots after fresh-path/OFD normalization")
    operations = first["operations"] + second["operations"]
    die(len(operations) == 4 and len(set(operations)) == 4,
        "the four durable saves do not have distinct book-owned operation IDs")
    boot_checker_pairs = check_boot_checker_records(root)
    die(len(set(boot_checker_pairs)) == 6 and
        set(boot_checker_pairs).isdisjoint(set(first["pairs"] + second["pairs"])),
        "per-boot checker identities alias each other or a boot process")
    return boot_checker_pairs


def check_cross_boots(root: Path) -> None:
    die(root.is_absolute() and str(root).startswith("/tmp/opencode/") and
        root.resolve() == root and stat.S_ISDIR(root.lstat().st_mode),
        "cross-boot evidence root must be canonical under /tmp/opencode")
    expected = {
        *{f"boot{boot}/{relative}" for boot in (1, 2)
          for relative in BOOT_FIXED_FILES},
        *{f"boot{boot}/inner-{index:03d}-{kind}.scm"
          for boot in (1, 2) for index in range(1, 11)
          for kind in ("guardian", "child")},
        *{f"BOOT{boot}-CHECKER.{suffix}"
          for boot in (1, 2) for suffix in ("txt", "stderr")},
        *{f"boot{boot}-checker-{kind}.scm"
          for boot in (1, 2) for kind in ("child", "guardian", "root-guardian")},
        "cross-checker-child.scm", "cross-checker-guardian.scm",
        "cross-checker-root-guardian.scm",
    }
    files, _ = inventory(root)
    die(set(files) == expected, "pre-cleanup cross-boot inventory differs")
    authority = read_record(root / "boot1/boot.record")
    campaign = {
        "source-manifest-sha256": authority.get("source-manifest-sha256", ""),
        "bundle-manifest-sha256": authority.get("bundle-manifest-sha256", ""),
    }
    first = check_boot(root / "boot1", 1, campaign)
    second = check_boot(root / "boot2", 2, campaign)
    check_cross_relations(root, first, second)


def check_state_artifact(path: Path, expected_hash: str) -> None:
    info = path.lstat()
    die(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and
        info.st_size == STATE_SIZE and stat.S_IMODE(info.st_mode) == 0o400,
        "final state artifact is not single-link mode-0400 64 MiB regular data")
    die(sha256(path) == expected_hash, "final state artifact hash differs")
    with path.open("rb", buffering=0) as source:
        source.seek(1024)
        superblock = source.read(1024)
    die(len(superblock) == 1024 and superblock[0x38:0x3A] == b"\x53\xef",
        "final state artifact lacks ext4 magic")
    die(superblock[0x78:0x88].rstrip(b"\x00") == STATE_LABEL,
        "final state artifact label differs")
    filesystem_state = int.from_bytes(superblock[0x3A:0x3C], "little")
    die(filesystem_state & 1 == 1, "final ext4 artifact is not marked clean")


CAMPAIGN_KEYS = {
    "schema", "status", "bundle-id",
    "bundle-manifest-sha256", "source-manifest-sha256",
    "guest-source-manifest-sha256",
    "guest-source-snapshot-manifest-sha256",
    "guest-capsule-roster-sha256", "guest-authority-source-sha256",
    "guest-contract-sha256",
    "guest-cooperative-budget-seconds", "hard-vm-deadline-seconds",
    "term-grace-seconds", "one-boot-owner-hard-deadline-seconds",
    "timeout-contract-sha256", "campaign-root", "campaign-root-device",
    "campaign-root-inode", "campaign-root-removed", "run-base-empty",
    "state-filesystem-label", "state-filesystem-size",
    "writers-released-before-inspection", "e2fsck-read-only",
    "initial-state-sha256", "post-boot1-state-sha256",
    "post-boot2-state-sha256", "final-artifact-sha256", "final-artifact-mode",
    "boot1-record-sha256", "boot2-record-sha256",
}


def check(root: Path, payload_hash: str, final_hash: str | None) -> None:
    die(root.is_absolute() and str(root).startswith("/tmp/opencode/") and
        root.resolve() == root and stat.S_ISDIR(root.lstat().st_mode),
        "evidence root must be a canonical real /tmp/opencode directory")
    payload = authenticate_payload(root, payload_hash, final_hash)
    expected_payload = {
        "campaign.record", "book-state.ext4",
        *{f"boot{boot}/{relative}" for boot in (1, 2)
          for relative in BOOT_FIXED_FILES},
        *{f"boot{boot}/inner-{index:03d}-{kind}.scm"
           for boot in (1, 2) for index in range(1, 11)
           for kind in ("guardian", "child")},
        *{f"BOOT{boot}-CHECKER.{suffix}"
          for boot in (1, 2) for suffix in ("txt", "stderr")},
        *{f"boot{boot}-checker-{kind}.scm"
          for boot in (1, 2) for kind in ("child", "guardian", "root-guardian")},
        "CROSS-CHECKER.txt", "CROSS-CHECKER.stderr", "cross-checker-child.scm",
        "cross-checker-guardian.scm", "cross-checker-root-guardian.scm",
    }
    die(set(payload) == expected_payload,
        "payload manifest roster is not the closed two-boot roster")
    for relative in payload:
        if relative != "book-state.ext4":
            die((root / relative).stat().st_size <= MAX_LOG,
                f"retained log/record exceeds 4 MiB: {relative}")

    campaign = read_record(root / "campaign.record")
    require_keys(campaign, CAMPAIGN_KEYS, "campaign record")
    die(campaign["schema"] == "2" and campaign["status"] == "pass" and
        campaign["campaign-root-removed"] == "true" and
        campaign["run-base-empty"] == "true" and
        campaign["state-filesystem-label"] == "WBBookStateV1" and
        campaign["state-filesystem-size"] == str(STATE_SIZE) and
        campaign["writers-released-before-inspection"] == "true" and
        campaign["e2fsck-read-only"] == "pass" and
        campaign["final-artifact-mode"] == "0400",
        "campaign disposition/cleanup/inspection record differs")
    die(campaign["guest-source-manifest-sha256"] == GUEST_SOURCE and
        campaign["guest-source-snapshot-manifest-sha256"] == GUEST_SNAPSHOT and
        campaign["guest-capsule-roster-sha256"] == GUEST_CAPSULE and
        campaign["guest-authority-source-sha256"] == GUEST_AUTHORITY and
        campaign["guest-contract-sha256"] == GUEST_CONTRACT and
        campaign["guest-cooperative-budget-seconds"] == "300" and
        campaign["hard-vm-deadline-seconds"] == "360" and
        campaign["term-grace-seconds"] == "5" and
        campaign["one-boot-owner-hard-deadline-seconds"] == "420" and
        campaign["timeout-contract-sha256"] == TIMEOUT_CONTRACT,
        "campaign is not bound to the exact accepted guest/timeout boundary")
    die(ID_RE.fullmatch(campaign["bundle-id"]) is not None,
        "campaign bundle ID is malformed")
    path_token(campaign, "campaign-root")
    positive(campaign, "campaign-root-device")
    positive(campaign, "campaign-root-inode")
    for key in CAMPAIGN_KEYS:
        if key.endswith("sha256"):
            die(SHA256_RE.fullmatch(campaign[key]) is not None,
                f"campaign {key} is not SHA-256")
    die(sha256(root / "boot1/boot.record") == campaign["boot1-record-sha256"] and
        sha256(root / "boot2/boot.record") == campaign["boot2-record-sha256"],
        "campaign boot-record hashes differ")
    check_state_artifact(root / "book-state.ext4",
                         campaign["final-artifact-sha256"])

    first = check_boot(root / "boot1", 1, campaign)
    second = check_boot(root / "boot2", 2, campaign)
    first_record = first["record"]
    second_record = second["record"]
    die(first_record["boot-id"] != second_record["boot-id"] and
        re.fullmatch(r"[0-9a-f]{32}", first_record["boot-id"]) is not None and
        re.fullmatch(r"[0-9a-f]{32}", second_record["boot-id"]) is not None,
        "campaign boot evidence IDs are not distinct canonical values")
    die(first["state"] == second["state"],
        "the two boots do not name the same state image identity")
    die(first_record["state-hash-before"] == campaign["initial-state-sha256"] and
        first_record["state-hash-after"] == campaign["post-boot1-state-sha256"] and
        second_record["state-hash-before"] == campaign["post-boot1-state-sha256"] and
        second_record["state-hash-after"] == campaign["post-boot2-state-sha256"] and
        campaign["post-boot2-state-sha256"] == campaign["final-artifact-sha256"] and
        len({campaign["initial-state-sha256"],
             campaign["post-boot1-state-sha256"],
             campaign["post-boot2-state-sha256"]}) == 3,
        "state hash chain does not prove two sequential mutations")
    die(first_record["run-root"] != second_record["run-root"] and
        (first_record["run-root-device"], first_record["run-root-inode"]) !=
        (second_record["run-root-device"], second_record["run-root-inode"]) and
        (first_record["overlay-device"], first_record["overlay-inode"]) !=
        (second_record["overlay-device"], second_record["overlay-inode"]),
        "run roots or root overlays were reused")
    die(set(first["pairs"]).isdisjoint(second["pairs"]),
        "host process identities were reused across boots")
    die(first_record["kernel-sha256"] == second_record["kernel-sha256"] and
        first_record["initrd-sha256"] == second_record["initrd-sha256"] and
        first_record["config-sha256"] == second_record["config-sha256"] and
        first_record["baseline-sha256"] == second_record["baseline-sha256"],
        "authenticated boot assets differ across boots")
    for key in ("guest-source-manifest-sha256",
                 "guest-source-snapshot-manifest-sha256",
                 "guest-capsule-roster-sha256", "guest-authority-source-sha256",
                 "guest-contract-sha256",
                 "two-boot-timeout-contract-sha256"):
        die(first_record[key] == second_record[key],
            f"guest/timeout authority differs across boots: {key}")

    die(normalize_graph(first["graph"], first_record) ==
        normalize_graph(second["graph"], second_record),
        "QEMU graph differs across boots after fresh-path/OFD normalization")
    operations = first["operations"] + second["operations"]
    die(len(operations) == 4 and len(set(operations)) == 4,
        "the four durable saves do not have distinct book-owned operation IDs")
    boot_checker_pairs = check_boot_checker_records(root)
    die(len(set(boot_checker_pairs)) == 6 and
        set(boot_checker_pairs).isdisjoint(set(first["pairs"] + second["pairs"])),
        "per-boot checker identities alias each other or a boot process")
    die(read_bytes(root / "CROSS-CHECKER.txt") == CROSS_BOOT_SUCCESS.encode() and
        read_bytes(root / "CROSS-CHECKER.stderr") == b"",
        "retained pre-cleanup cross-boot checker output differs")
    cross_checker_pairs = [
        process_alist(root / "cross-checker-child.scm",
                      "cross-evidence-checker-direct-child"),
        process_alist(root / "cross-checker-guardian.scm",
                      "cross-evidence-checker-process-guardian"),
        process_alist(root / "cross-checker-root-guardian.scm",
                      "cross-evidence-checker-root-guardian"),
    ]
    prior_pairs = set(first["pairs"] + second["pairs"] + boot_checker_pairs)
    die(len(set(cross_checker_pairs)) == 3 and
        set(cross_checker_pairs).isdisjoint(prior_pairs),
        "cross-boot checker identities alias an earlier process")
    if final_hash is not None:
        die(read_bytes(root / "CHECKER.txt") ==
            b"PASS: exact two-fresh-boot Book State evidence and cleanup join\n" and
            read_bytes(root / "CHECKER.stderr") == b"",
            "retained production checker output differs")
        checker_pairs = [
            process_alist(root / "checker-child.scm",
                          "evidence-checker-direct-child"),
            process_alist(root / "checker-guardian.scm",
                          "evidence-checker-process-guardian"),
            process_alist(root / "checker-root-guardian.scm",
                          "evidence-checker-root-guardian"),
        ]
        die(len(set(checker_pairs)) == 3 and
            set(checker_pairs).isdisjoint(
                prior_pairs | set(cross_checker_pairs)),
            "checker process identities are duplicated or alias a boot process")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence")
    parser.add_argument("--payload-manifest-sha256")
    parser.add_argument("--final-manifest-sha256")
    parser.add_argument("--single-boot-evidence")
    parser.add_argument("--boot-index", type=int)
    parser.add_argument("--cross-boot-evidence")
    arguments = parser.parse_args(argv)
    try:
        campaign_mode = (arguments.evidence is not None or
                         arguments.payload_manifest_sha256 is not None or
                         arguments.final_manifest_sha256 is not None)
        single_mode = (arguments.single_boot_evidence is not None or
                       arguments.boot_index is not None)
        cross_mode = arguments.cross_boot_evidence is not None
        die(sum((campaign_mode, single_mode, cross_mode)) == 1,
            "select exactly one campaign, single-boot, or cross-boot checker mode")
        if single_mode:
            die(arguments.single_boot_evidence is not None and
                arguments.boot_index is not None,
                "single-boot checker mode requires evidence and boot index")
            check_single_boot(Path(arguments.single_boot_evidence),
                              arguments.boot_index)
            print(SINGLE_BOOT_SUCCESS.format(boot=arguments.boot_index), end="")
            return 0
        if cross_mode:
            check_cross_boots(Path(arguments.cross_boot_evidence))
            print(CROSS_BOOT_SUCCESS, end="")
            return 0
        die(arguments.evidence is not None and
            arguments.payload_manifest_sha256 is not None,
            "campaign checker mode requires evidence and payload manifest")
        check(Path(arguments.evidence), arguments.payload_manifest_sha256,
              arguments.final_manifest_sha256)
    except (CheckError, OSError) as error:
        print(f"FAIL: two-boot evidence: {error}", file=sys.stderr)
        return 1
    print("PASS: exact two-fresh-boot Book State evidence and cleanup join")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
