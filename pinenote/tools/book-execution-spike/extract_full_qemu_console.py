#!/usr/bin/env python3
"""Offline inverse of disposable-qemu.scm's full-console evidence framing."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import sys


# Keep these aligned with disposable-qemu.scm.  The evidence bound includes the
# 5x escaped console plus its small outer failure diagnostics.
MAX_SOURCE_BYTES = 3_423_172
MAX_EVIDENCE_BYTES = 20 * 1024 * 1024

BEGIN = re.compile(
    rb"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console\.log "
    rb"source-bytes=(0|[1-9][0-9]*) retention=full\n"
)
CONTENT = re.compile(
    rb"BOOKEXEC-QEMU-DIAGNOSTIC-CONTENT bytes=(0|[1-9][0-9]*)\n"
)
END = b"BOOKEXEC-QEMU-DIAGNOSTIC-END label=console.log retention=full\n"
CONSOLE_CONTROL = re.compile(
    rb"BOOKEXEC-QEMU-DIAGNOSTIC-(BEGIN|END|INCOMPLETE) "
    rb"label=console\.log(?=[ \t\r\n]|$)"
)
LOWER_HEX = b"0123456789abcdef"


class EvidenceDecodeError(ValueError):
    """The retained evidence is not one canonical full-console frame."""


def _read_regular_bounded(path: Path) -> bytes:
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise EvidenceDecodeError("evidence input is not a regular file")
    if before.st_nlink != 1:
        raise EvidenceDecodeError("evidence input has hard-link aliases")
    if before.st_size > MAX_EVIDENCE_BYTES:
        raise EvidenceDecodeError("evidence input exceeds the fixed byte bound")
    with path.open("rb") as source:
        data = source.read(MAX_EVIDENCE_BYTES + 1)
    if len(data) > MAX_EVIDENCE_BYTES:
        raise EvidenceDecodeError("evidence input exceeds the fixed byte bound")
    after = path.lstat()
    identity = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_nlink,
        item.st_size,
        item.st_mtime_ns,
    )
    if identity(before) != identity(after):
        raise EvidenceDecodeError("evidence input changed while being read")
    return data


def _decode_canonical_escapes(encoded: bytes) -> bytes:
    decoded = bytearray()
    index = 0
    while index < len(encoded):
        byte = encoded[index]
        if byte != 0x5C:
            if not 32 <= byte <= 126:
                raise EvidenceDecodeError("escaped payload contains a raw nonprintable byte")
            decoded.append(byte)
            index += 1
            continue
        if index + 1 >= len(encoded):
            raise EvidenceDecodeError("escaped payload ends in a backslash")
        escape = encoded[index + 1]
        named = {ord("n"): 10, ord("r"): 13, ord("t"): 9, 0x5C: 0x5C}
        if escape in named:
            decoded.append(named[escape])
            index += 2
            continue
        if escape != ord("x") or index + 3 >= len(encoded):
            raise EvidenceDecodeError("escaped payload contains an unknown escape")
        digits = encoded[index + 2 : index + 4]
        if any(digit not in LOWER_HEX for digit in digits):
            raise EvidenceDecodeError("hex escapes must use two lowercase digits")
        value = int(digits, 16)
        if value in (9, 10, 13, 0x5C) or 32 <= value <= 126:
            raise EvidenceDecodeError("escaped payload is not in the emitter's canonical form")
        decoded.append(value)
        index += 4
    return bytes(decoded)


def _encode_like_outer(source: bytes) -> bytes:
    encoded = bytearray(b"| ")
    for index, byte in enumerate(source):
        if byte == 10:
            encoded.extend(b"\\n")
            if index + 1 < len(source):
                encoded.extend(b"\n| ")
        elif byte == 13:
            encoded.extend(b"\\r")
        elif byte == 9:
            encoded.extend(b"\\t")
        elif byte == 0x5C:
            encoded.extend(b"\\\\")
        elif 32 <= byte <= 126:
            encoded.append(byte)
        else:
            encoded.extend(f"\\x{byte:02x}".encode("ascii"))
    encoded.append(10)
    return bytes(encoded)


def _console_control_kind(line: bytes) -> bytes | None:
    """Identify an unprefixed console BEGIN/END/INCOMPLETE record."""
    control = CONSOLE_CONTROL.match(line)
    return None if control is None else control.group(1)


def decode_full_console_evidence(evidence: bytes) -> bytes:
    if len(evidence) > MAX_EVIDENCE_BYTES:
        raise EvidenceDecodeError("evidence input exceeds the fixed byte bound")
    lines = evidence.splitlines(keepends=True)
    if not lines or any(not line.endswith(b"\n") for line in lines):
        raise EvidenceDecodeError("every retained evidence line must end in LF")
    begin_indexes = [index for index, line in enumerate(lines) if BEGIN.fullmatch(line)]
    end_indexes = [index for index, line in enumerate(lines) if line == END]
    if len(begin_indexes) != 1 or len(end_indexes) != 1:
        raise EvidenceDecodeError("expected exactly one complete full-console frame")
    begin_index = begin_indexes[0]
    end_index = end_indexes[0]
    if end_index <= begin_index + 2:
        raise EvidenceDecodeError("full-console frame has no encoded payload line")
    allowed_controls = {(b"BEGIN", begin_index), (b"END", end_index)}
    for index, line in enumerate(lines):
        control = _console_control_kind(line)
        if control is not None and (control, index) not in allowed_controls:
            raise EvidenceDecodeError(
                "unexpected unprefixed console framing control outside the frame"
            )
    begin_match = BEGIN.fullmatch(lines[begin_index])
    content_match = CONTENT.fullmatch(lines[begin_index + 1])
    if begin_match is None or content_match is None:
        raise EvidenceDecodeError("full-console content header is missing or malformed")
    declared_source = int(begin_match.group(1))
    declared_content = int(content_match.group(1))
    if declared_source > MAX_SOURCE_BYTES or declared_content > MAX_SOURCE_BYTES:
        raise EvidenceDecodeError("declared console bytes exceed the outer runner bound")
    payload_lines = lines[begin_index + 2 : end_index]
    if any(not line.startswith(b"| ") for line in payload_lines):
        raise EvidenceDecodeError("encoded console line lacks the exact outer prefix")
    encoded = b"".join(line[2:-1] for line in payload_lines)
    decoded = _decode_canonical_escapes(encoded)
    if len(decoded) != declared_source or len(decoded) != declared_content:
        raise EvidenceDecodeError("decoded byte count disagrees with retained framing")
    rendered = b"".join(payload_lines)
    if _encode_like_outer(decoded) != rendered:
        raise EvidenceDecodeError("encoded console is not the exact outer emitter image")
    return decoded


def extract_full_console(input_path: Path, output_path: Path) -> tuple[int, str]:
    decoded = decode_full_console_evidence(_read_regular_bounded(input_path))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(output_path, flags, 0o600)
    created = True
    try:
        view = memoryview(decoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write while preserving decoded console")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o400)
    except BaseException:
        os.close(descriptor)
        if created:
            output_path.unlink(missing_ok=True)
        raise
    else:
        os.close(descriptor)
    return len(decoded), hashlib.sha256(decoded).hexdigest()


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print(f"usage: {arguments[0]} RETAINED-EVIDENCE NEW-RAW-CONSOLE", file=sys.stderr)
        return 2
    size, digest = extract_full_console(Path(arguments[1]), Path(arguments[2]))
    print(
        f"PASS: decoded exact full console source-bytes={size} "
        f"sha256={digest} output={arguments[2]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
