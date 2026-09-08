#!/usr/bin/env python3
"""Regressions for S2-1: source identity, not append-only review bytes."""

from __future__ import annotations

from contextlib import redirect_stdout
import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
REVIEW = REPO / "doc/reviews/2026-09-05-book-protocol-fd-adversarial.md"
GUARD = HERE / "check_protocol_guest_inventory.py"
sys.path.insert(0, str(HERE))
import check_protocol_guest_inventory as inventory  # noqa: E402


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class ReviewDriftGuardTests(unittest.TestCase):
    def test_append_only_review_change_does_not_invalidate_source_gate(self) -> None:
        guard_source = GUARD.read_text(encoding="utf-8")
        self.assertNotIn(str(REVIEW.relative_to(REPO)), guard_source)
        self.assertNotIn("STAGE1_REVIEW", guard_source)
        self.assertNotIn(
            "ab164146dfe1b769dcb4bfd5dfa8b57c59ab775967d962e565d50b876653cf34",
            guard_source,
        )

        original = REVIEW.read_bytes()
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-review-drift.", dir="/tmp/opencode"
        ) as temporary:
            appended = Path(temporary) / REVIEW.name
            appended.write_bytes(original + b"\nappend-only regression note\n")
            self.assertNotEqual(digest(original), digest(appended.read_bytes()))
            with redirect_stdout(io.StringIO()):
                inventory.verify_hash_roster(
                    inventory.STAGE1_FILES,
                    "accepted Stage-1 fixture remains frozen",
                )

    def test_reviewed_stage1_source_mutation_still_fails(self) -> None:
        original = HERE / "protocol-fixture/protocol-host.scm"
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-stage1-source-drift.", dir="/tmp/opencode"
        ) as temporary:
            mutated = Path(temporary) / original.name
            mutated.write_bytes(original.read_bytes() + b"\n; mutation\n")
            roster = dict(inventory.STAGE1_FILES)
            expected = roster.pop(original)
            roster[mutated] = expected
            with redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(
                    SystemExit,
                    r"^FAIL: accepted Stage-1 fixture remains frozen: "
                    r"protocol-host\.scm$",
                ):
                    inventory.verify_hash_roster(
                        roster,
                        "accepted Stage-1 fixture remains frozen",
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
