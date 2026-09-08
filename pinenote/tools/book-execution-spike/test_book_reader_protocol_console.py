#!/usr/bin/env python3
"""Host regressions for the reader-driven guest serial assertion chain."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
CHECKER = HERE / "assert-guest-reader-protocol-console.scm"
DIAGNOSTIC_STORE_EMITTER = HERE / "guest-smoke.scm"
ACTUAL_CONSOLE = (
    HERE
    / "build/artifacts/reader-interaction-real-qemu-20260906-v6-harvest/console.log"
)
ACTUAL_CONSOLE_SHA256 = (
    "6b67e290e473533446ee02582475b34c4021abd7629ef0f1922c47ef44605d56"
)


def emitted_store_labels() -> tuple[str, str]:
    source = DIAGNOSTIC_STORE_EMITTER.read_text(encoding="utf-8")
    labels = re.findall(r"\(make-diagnostic-store\s+'([a-z0-9-]+)", source)
    if labels != ["runsc-debug", "runsc-panic"]:
        raise RuntimeError(f"diagnostic-store emitter labels changed: {labels!r}")
    return labels[0], labels[1]


RUNSC_DEBUG, RUNSC_PANIC = emitted_store_labels()
MARKERS = [
    "BOOKEXEC-READER-PROTOCOL-SOURCE-PROVENANCE-PASS",
    "BOOKEXEC-KERNEL-IDENTITY-PASS",
    "BOOKEXEC-NETWORK-ABSENT-PASS",
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
    "BOOKEXEC-RUNSC-VERSION-PASS",
    "BOOKEXEC-READER-PROTOCOL-SCHEMA-REJECTION-PASS",
    "BOOKEXEC-READER-PROTOCOL-STALE-REJECTION-PASS",
    "BOOKEXEC-READER-PROTOCOL-TRUNCATED-CLOSE-PASS",
]
STORE = {
    RUNSC_DEBUG: (
        f"BOOKEXEC-DIAGNOSTIC-STORE label={RUNSC_DEBUG} entries=1 file-limit=10 "
        "source-bytes=1 allocated-bytes=4096 capacity-bytes=4194304 "
        "invalid-entry=#f byte-exhausted=#f inode-exhausted=#f overflow=#f"
    ),
    RUNSC_PANIC: (
        f"BOOKEXEC-DIAGNOSTIC-STORE label={RUNSC_PANIC} entries=0 file-limit=2 "
        "source-bytes=0 allocated-bytes=0 capacity-bytes=1048576 "
        "invalid-entry=#f byte-exhausted=#f inode-exhausted=#f overflow=#f"
    ),
}
VALID_LINES = [
    "Linux boot noise",
    *MARKERS,
    STORE[RUNSC_DEBUG],
    STORE[RUNSC_PANIC],
    "BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS",
    STORE[RUNSC_DEBUG],
    STORE[RUNSC_PANIC],
    "BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS",
    "BOOKEXEC-READER-PROTOCOL-CGROUP-TEARDOWN-PASS",
    "BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS",
    "BOOKEXEC-READER-PROTOCOL-PASS",
    "reboot: Power down",
]


class ReaderProtocolConsoleTests(unittest.TestCase):
    def run_checker_path(self, path: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["guile", "--no-auto-compile", str(CHECKER), str(path)],
            cwd=HERE,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )

    def run_checker(self, lines: list[str]) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir="/tmp/opencode", delete=False
        ) as output:
            output.write("\n".join(lines) + "\n")
            path = Path(output.name)
        try:
            return self.run_checker_path(path)
        finally:
            path.unlink()

    def assert_rejected(self, lines: list[str]) -> None:
        result = self.run_checker(lines)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_fixture_derives_the_exact_actual_emitter_labels(self) -> None:
        self.assertEqual(
            (RUNSC_DEBUG, RUNSC_PANIC), ("runsc-debug", "runsc-panic")
        )
        self.assertEqual(
            sum(f"label={RUNSC_DEBUG} " in line for line in VALID_LINES), 2
        )
        self.assertEqual(
            sum(f"label={RUNSC_PANIC} " in line for line in VALID_LINES), 2
        )

    def test_exact_reader_semantic_cleanup_and_powerdown_chain_passes(self) -> None:
        result = self.run_checker(VALID_LINES)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            result.stdout, "GUEST-READER-PROTOCOL-ASSERTIONS=PASS\n"
        )
        self.assertEqual(result.stderr, "")

    def test_actual_v6_console_and_canonical_printk_timestamp_pass(self) -> None:
        self.assertEqual(
            hashlib.sha256(ACTUAL_CONSOLE.read_bytes()).hexdigest(),
            ACTUAL_CONSOLE_SHA256,
        )
        actual = self.run_checker_path(ACTUAL_CONSOLE)
        self.assertEqual(actual.returncode, 0, actual.stdout + actual.stderr)
        self.assertEqual(
            actual.stdout, "GUEST-READER-PROTOCOL-ASSERTIONS=PASS\n"
        )
        timestamped = list(VALID_LINES)
        timestamped[-1] = "[   30.381268] reboot: Power down"
        synthetic = self.run_checker(timestamped)
        self.assertEqual(
            synthetic.returncode, 0, synthetic.stdout + synthetic.stderr
        )

    def test_missing_reordered_and_duplicated_markers_fail(self) -> None:
        missing = list(VALID_LINES)
        missing.remove("BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS")
        reordered = list(VALID_LINES)
        left = reordered.index("BOOKEXEC-READER-PROTOCOL-CGROUP-TEARDOWN-PASS")
        right = reordered.index("BOOKEXEC-READER-PROTOCOL-UI-EOF-PASS")
        reordered[left], reordered[right] = reordered[right], reordered[left]
        duplicated = [*VALID_LINES, "BOOKEXEC-READER-PROTOCOL-PASS"]
        for lines in (missing, reordered, duplicated):
            with self.subTest():
                self.assert_rejected(lines)

    def test_missing_reordered_duplicated_and_wrong_label_summaries_fail(self) -> None:
        missing = list(VALID_LINES)
        missing.remove(STORE[RUNSC_DEBUG])
        reordered = list(VALID_LINES)
        guile = reordered.index("BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS")
        reordered[guile - 1], reordered[guile] = reordered[guile], reordered[guile - 1]
        duplicated = list(VALID_LINES)
        duplicated.insert(duplicated.index(STORE[RUNSC_DEBUG]), STORE[RUNSC_DEBUG])
        wrong_label = [
            line.replace(f"label={RUNSC_DEBUG} ", "label=debug ", 1)
            for line in VALID_LINES
        ]
        for lines in (missing, reordered, duplicated, wrong_label):
            with self.subTest():
                self.assert_rejected(lines)

    def test_overflow_wrong_limits_noncanonical_counts_and_capacity_fail(self) -> None:
        for old, new in (
            ("file-limit=10", "file-limit=11"),
            ("capacity-bytes=1048576", "capacity-bytes=4194304"),
            ("overflow=#f", "overflow=#t"),
            ("entries=1", "entries=01"),
            ("allocated-bytes=4096", "allocated-bytes=4194305"),
        ):
            with self.subTest(old=old, new=new):
                mutation = list(VALID_LINES)
                index = next(i for i, line in enumerate(mutation) if old in line)
                mutation[index] = mutation[index].replace(old, new)
                self.assert_rejected(mutation)

    def test_failure_fragments_marker_whitespace_and_powerdown_order_fail(self) -> None:
        for fragment in (
            "BOOKEXEC-READER-PROTOCOL-FAIL injected",
            "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW stream=stderr",
            f"BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW label={RUNSC_DEBUG}",
            "Kernel panic - not syncing",
        ):
            with self.subTest(fragment=fragment):
                self.assert_rejected([*VALID_LINES, fragment])
        whitespace = list(VALID_LINES)
        index = whitespace.index("BOOKEXEC-READER-PROTOCOL-PASS")
        whitespace[index] += " "
        self.assert_rejected(whitespace)
        early_powerdown = list(VALID_LINES)
        early_powerdown.remove("reboot: Power down")
        early_powerdown.insert(index, "reboot: Power down")
        self.assert_rejected(early_powerdown)

    def test_shutdown_adversarial_cases_fail(self) -> None:
        missing = VALID_LINES[:-1]
        duplicated = [*VALID_LINES, "[   30.381268] reboot: Power down"]
        timestamped = list(VALID_LINES)
        timestamped[-1] = "[   30.381268] reboot: Power down"
        out_of_order = timestamped[:-1]
        out_of_order.insert(
            out_of_order.index("BOOKEXEC-READER-PROTOCOL-PASS"),
            timestamped[-1],
        )
        malformed = list(VALID_LINES)
        malformed[-1] = "[    30.381268] reboot: Power down"
        prefixed_payload = list(VALID_LINES)
        prefixed_payload[-1] = (
            "BOOK-PAYLOAD [   30.381268] reboot: Power down"
        )
        suffixed = list(VALID_LINES)
        suffixed[-1] = "[   30.381268] reboot: Power down trailing"
        for label, lines in (
            ("missing", missing),
            ("duplicate", duplicated),
            ("out-of-order", out_of_order),
            ("malformed-timestamp", malformed),
            ("prefixed-payload-lookalike", prefixed_payload),
            ("suffixed-garbage", suffixed),
        ):
            with self.subTest(label=label):
                self.assert_rejected(lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
