#!/usr/bin/env python3
"""Host-only tests for the actual-guest serial assertion chain."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
CHECKER = HERE / "assert-guest-protocol-console.scm"
DIAGNOSTIC_STORE_EMITTER = HERE / "guest-smoke.scm"


def emitted_store_labels() -> tuple[str, str]:
    """Read the two labels passed to the actual diagnostic-store emitter."""
    source = DIAGNOSTIC_STORE_EMITTER.read_text(encoding="utf-8")
    labels = re.findall(r"\(make-diagnostic-store\s+'([a-z0-9-]+)", source)
    if labels != ["runsc-debug", "runsc-panic"]:
        raise RuntimeError(f"diagnostic-store emitter labels changed: {labels!r}")
    return labels[0], labels[1]


RUNSC_DEBUG, RUNSC_PANIC = emitted_store_labels()

MARKERS = [
    "BOOKEXEC-PROTOCOL-SOURCE-PROVENANCE-PASS",
    "BOOKEXEC-KERNEL-IDENTITY-PASS",
    "BOOKEXEC-NETWORK-ABSENT-PASS",
    "BOOKEXEC-FORBIDDEN-MOUNTS-PASS",
    "BOOKEXEC-RUNSC-VERSION-PASS",
    "BOOKEXEC-PROTOCOL-SCHEMA-REJECTION-PASS",
    "BOOKEXEC-PROTOCOL-STALE-REJECTION-PASS",
    "BOOKEXEC-PROTOCOL-TRUNCATED-CLOSE-PASS",
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
    "BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS",
    STORE[RUNSC_DEBUG],
    STORE[RUNSC_PANIC],
    "BOOKEXEC-PROTOCOL-PYTHON-SYSTRAP-PASS",
    "BOOKEXEC-PROTOCOL-CGROUP-TEARDOWN-PASS",
    "BOOKEXEC-PROTOCOL-PASS",
    "reboot: Power down",
]


class ProtocolConsoleTests(unittest.TestCase):
    def run_checker(self, lines: list[str]) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir="/tmp/opencode", delete=False
        ) as output:
            output.write("\n".join(lines) + "\n")
            path = Path(output.name)
        try:
            return subprocess.run(
                ["guile", "--no-auto-compile", str(CHECKER), str(path)],
                cwd=HERE,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
        finally:
            path.unlink()

    def test_fixture_uses_exact_actual_emitter_labels(self) -> None:
        self.assertEqual((RUNSC_DEBUG, RUNSC_PANIC), ("runsc-debug", "runsc-panic"))
        self.assertEqual(sum(f"label={RUNSC_DEBUG} " in line for line in VALID_LINES), 2)
        self.assertEqual(sum(f"label={RUNSC_PANIC} " in line for line in VALID_LINES), 2)

    def test_exact_semantic_and_cleanup_chain_passes(self) -> None:
        result = self.run_checker(VALID_LINES)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "GUEST-PROTOCOL-ASSERTIONS=PASS\n")
        self.assertEqual(result.stderr, "")

    def test_missing_duplicate_or_reordered_marker_fails(self) -> None:
        for mutation in (
            [line for line in VALID_LINES if line != "BOOKEXEC-PROTOCOL-PASS"],
            [*VALID_LINES, "BOOKEXEC-PROTOCOL-PASS"],
            [*reversed(VALID_LINES)],
        ):
            with self.subTest():
                result = self.run_checker(mutation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_missing_reordered_or_duplicate_store_summary_fails(self) -> None:
        missing = list(VALID_LINES)
        missing.remove(STORE[RUNSC_DEBUG])
        reordered = list(VALID_LINES)
        guile = reordered.index("BOOKEXEC-PROTOCOL-GUILE-SYSTRAP-PASS")
        reordered[guile - 1], reordered[guile] = reordered[guile], reordered[guile - 1]
        duplicate = list(VALID_LINES)
        duplicate.insert(duplicate.index(STORE[RUNSC_DEBUG]), STORE[RUNSC_DEBUG])
        for mutation in (missing, reordered, duplicate):
            with self.subTest():
                result = self.run_checker(mutation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_historical_short_store_labels_fail(self) -> None:
        for actual, wrong in ((RUNSC_DEBUG, "debug"), (RUNSC_PANIC, "panic")):
            with self.subTest(actual=actual, wrong=wrong):
                mutation = [line.replace(f"label={actual} ", f"label={wrong} ") for line in VALID_LINES]
                result = self.run_checker(mutation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_failure_and_overflow_fragments_fail(self) -> None:
        for fragment in (
            "BOOKEXEC-PROTOCOL-FAIL injected",
            "BOOKEXEC-DIAGNOSTIC-CAPTURE-OVERFLOW stream=stderr",
            f"BOOKEXEC-DIAGNOSTIC-STORE-OVERFLOW label={RUNSC_DEBUG}",
            "Kernel panic - not syncing",
        ):
            with self.subTest(fragment=fragment):
                result = self.run_checker([*VALID_LINES, fragment])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_wrong_store_limit_or_overflow_field_fails(self) -> None:
        for old, new in (
            ("file-limit=10", "file-limit=11"),
            ("capacity-bytes=1048576", "capacity-bytes=4194304"),
            ("overflow=#f", "overflow=#t"),
        ):
            with self.subTest(old=old, new=new):
                mutation = list(VALID_LINES)
                index = next(i for i, line in enumerate(mutation) if old in line)
                mutation[index] = mutation[index].replace(old, new)
                result = self.run_checker(mutation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
