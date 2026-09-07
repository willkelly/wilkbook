#!/usr/bin/env python3
"""Host-only tests for exact full-console evidence inversion."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import tempfile
import unittest

from extract_full_qemu_console import (
    END,
    EvidenceDecodeError,
    MAX_SOURCE_BYTES,
    _encode_like_outer,
    decode_full_console_evidence,
    extract_full_console,
)


CAPTURED_EVIDENCE = (
    Path(__file__).resolve().parent
    / "build/protocol-control-root-mount-runtime-evidence-v2.OMSobe.log"
)
CAPTURED_EVIDENCE_SHA256 = (
    "5bfcd98425f0d3e554a343e89775d2ba2f56212ac21753bc15a6542c5818e378"
)
INDEPENDENT_RAW_CONSOLE_SHA256 = (
    "171aedc3cda996e81609cd363c1985e2a6758295a98431c59880a584d46be9d3"
)
CHANGED_INCOMPLETE = (
    b"BOOKEXEC-QEMU-DIAGNOSTIC-INCOMPLETE label=console.log state=changed "
    b"exported-bytes=25120 limit-bytes=3423172\n"
)


def full_frame(source: bytes) -> bytes:
    return b"".join(
        (
            b"wrapper before\n",
            b"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console.log source-bytes="
            + str(len(source)).encode("ascii")
            + b" retention=full\n",
            b"BOOKEXEC-QEMU-DIAGNOSTIC-CONTENT bytes="
            + str(len(source)).encode("ascii")
            + b"\n",
            _encode_like_outer(source),
            END,
            b"wrapper after\n",
        )
    )


class FullConsoleDecoderTests(unittest.TestCase):
    @unittest.skipUnless(
        CAPTURED_EVIDENCE.is_file(), "immutable successor evidence absent"
    )
    def test_successor_capture_matches_independent_raw_console_identity(self) -> None:
        evidence = CAPTURED_EVIDENCE.read_bytes()
        self.assertEqual(hashlib.sha256(evidence).hexdigest(), CAPTURED_EVIDENCE_SHA256)
        console = decode_full_console_evidence(evidence)
        self.assertEqual(len(console), 25_120)
        self.assertEqual(
            hashlib.sha256(console).hexdigest(), INDEPENDENT_RAW_CONSOLE_SHA256
        )

    def test_exact_emitter_inverse_without_double_decoding(self) -> None:
        source = b"first\\n literal\r\nsecond\t\\\x00\xff\n"
        self.assertEqual(decode_full_console_evidence(full_frame(source)), source)

    def test_all_byte_values_round_trip(self) -> None:
        source = bytes(range(256))
        self.assertEqual(decode_full_console_evidence(full_frame(source)), source)

    def test_declared_source_or_content_byte_mismatch_fails(self) -> None:
        frame = full_frame(b"abc\n")
        for old, new in (
            (b"source-bytes=4", b"source-bytes=3"),
            (b"CONTENT bytes=4", b"CONTENT bytes=5"),
        ):
            with self.subTest(old=old):
                with self.assertRaises(EvidenceDecodeError):
                    decode_full_console_evidence(frame.replace(old, new, 1))

    def test_duplicate_or_incomplete_frame_fails(self) -> None:
        frame = full_frame(b"abc\n")
        for evidence in (frame + frame, frame.replace(END, b"", 1)):
            with self.subTest():
                with self.assertRaises(EvidenceDecodeError):
                    decode_full_console_evidence(evidence)

    @unittest.skipUnless(CAPTURED_EVIDENCE.is_file(), "immutable successor evidence absent")
    def test_review_ex1_fails_without_creating_output(self) -> None:
        retained = CAPTURED_EVIDENCE.read_bytes()
        self.assertEqual(retained.count(END), 1)
        contradiction = retained.replace(END, END + CHANGED_INCOMPLETE, 1)
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            evidence = Path(directory) / "evidence.log"
            output = Path(directory) / "console.raw"
            evidence.write_bytes(contradiction)
            with self.assertRaises(EvidenceDecodeError):
                extract_full_console(evidence, output)
            self.assertFalse(output.exists())

    def test_extra_console_controls_before_and_after_frame_fail(self) -> None:
        frame = full_frame(b"abc\n")
        controls = (
            b"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console.log "
            b"source-bytes=3 retention=full\n",
            b"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console.log "
            b"source-bytes=03 retention=full\n",
            END,
            b"BOOKEXEC-QEMU-DIAGNOSTIC-END label=console.log retention=partial\n",
            CHANGED_INCOMPLETE,
        )
        for position in ("before", "after"):
            for control in controls:
                with self.subTest(position=position, control=control):
                    evidence = (
                        control + frame if position == "before" else frame + control
                    )
                    with self.assertRaises(EvidenceDecodeError):
                        decode_full_console_evidence(evidence)

    def test_prefixed_framing_payload_and_other_label_frames_are_allowed(self) -> None:
        source = b"".join(
            (
                b"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=console.log "
                b"source-bytes=3 retention=full\n",
                END,
                CHANGED_INCOMPLETE.removesuffix(b"\n"),
            )
        )
        stderr_frame = b"".join(
            (
                b"BOOKEXEC-QEMU-DIAGNOSTIC-BEGIN label=qemu.stderr source-bytes=3\n",
                b"BOOKEXEC-QEMU-DIAGNOSTIC-CONTENT bytes=3\n",
                b"| err\n",
                b"BOOKEXEC-QEMU-DIAGNOSTIC-END label=qemu.stderr\n",
            )
        )
        evidence = stderr_frame + full_frame(source) + stderr_frame
        self.assertEqual(decode_full_console_evidence(evidence), source)

    def test_noncanonical_prefix_escape_or_raw_byte_fails(self) -> None:
        frame = full_frame(b"a\n\x01")
        mutations = (
            frame.replace(b"| a", b"! a", 1),
            frame.replace(b"\\n", b"\\x0a", 1),
            frame.replace(b"\\x01", b"\\x0A", 1),
            frame.replace(b"\\x01", b"\x01", 1),
        )
        for evidence in mutations:
            with self.subTest():
                with self.assertRaises(EvidenceDecodeError):
                    decode_full_console_evidence(evidence)

    def test_declared_outer_bound_is_enforced_without_large_input(self) -> None:
        frame = full_frame(b"")
        oversized = frame.replace(
            b"source-bytes=0",
            f"source-bytes={MAX_SOURCE_BYTES + 1}".encode("ascii"),
            1,
        )
        with self.assertRaises(EvidenceDecodeError):
            decode_full_console_evidence(oversized)

    def test_extraction_creates_one_read_only_file_and_refuses_overwrite(self) -> None:
        source = b"exact\r\nconsole\n"
        with tempfile.TemporaryDirectory(dir="/tmp/opencode") as directory:
            root = Path(directory)
            evidence = root / "evidence.log"
            output = root / "console.raw"
            evidence.write_bytes(full_frame(source))
            size, _digest = extract_full_console(evidence, output)
            self.assertEqual(size, len(source))
            self.assertEqual(output.read_bytes(), source)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o400)
            with self.assertRaises(FileExistsError):
                extract_full_console(evidence, output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
