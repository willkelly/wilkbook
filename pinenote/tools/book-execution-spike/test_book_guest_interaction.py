#!/usr/bin/env python3
"""Host-only routing and teardown tests for the reader-driven guest authority."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROTOCOL_DIR = REPO / "pinenote/tools/book-protocol"
SESSION_DIR = REPO / "pinenote/tools/book-session"
INTERACTION_DIR = REPO / "pinenote/tools/book-interaction"
INVOKE = HERE / "invoke-guest-book-interaction-test.scm"
sys.path.insert(0, str(HERE))
import test_guest_book_protocol  # noqa: E402


class GuestReaderInteractionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = test_guest_book_protocol.GuestProtocolAdapterTests(
            "test_two_real_native_books_through_strict_fake_boundary"
        )
        self.fixture.setUp()
        self.guile_bundle = self.fixture.guile_bundle
        self.python_bundle = self.fixture.python_bundle

    def tearDown(self) -> None:
        self.fixture.tearDown()

    def run_interaction(
        self,
        mode: str,
        fake_runsc: Path,
        *,
        timeout: str = "10",
        transcript_name: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        transcript = self.fixture.top / (
            transcript_name or f"reader-{mode}.transcript"
        )
        environment = {
            "GUILE_AUTO_COMPILE": "0",
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": os.environ["PATH"],
        }
        for name in (
            "GUILE_LOAD_PATH",
            "GUILE_LOAD_COMPILED_PATH",
            "GUILE_EXTENSIONS_PATH",
        ):
            if name in os.environ:
                environment[name] = os.environ[name]
        result = subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                str(INTERACTION_DIR),
                "-L",
                str(PROTOCOL_DIR),
                "-L",
                str(SESSION_DIR),
                "-L",
                str(HERE),
                str(INVOKE),
                mode,
                str(self.guile_bundle),
                str(self.python_bundle),
                str(fake_runsc),
                timeout,
                str(transcript),
            ],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(15, int(float(timeout)) + 10),
            check=False,
        )
        return result, transcript

    def assert_no_evidence_pass(self, result: subprocess.CompletedProcess[str]) -> None:
        combined = result.stdout + result.stderr
        self.assertNotIn("BOOKEXEC-READER-PROTOCOL-GUILE-SYSTRAP-PASS", combined)
        self.assertNotIn("BOOKEXEC-READER-PROTOCOL-PYTHON-SYSTRAP-PASS", combined)
        self.assertNotIn("BOOKEXEC-READER-PROTOCOL-PASS", combined)

    def assert_runtime_cleaned(self) -> None:
        for bundle in (self.guile_bundle, self.python_bundle):
            self.assertFalse((bundle / "runsc.pid").exists())
            state_root = bundle / "runsc-state"
            if (bundle / "fake-observation.json").exists():
                self.assertFalse(state_root.exists())
            elif state_root.exists():
                # The fixed bundle generator creates this empty directory
                # before a language is selected.  A failure during Guile must
                # not be mislabeled as having launched/cleaned Python.
                self.assertEqual(list(state_root.iterdir()), [])

    @staticmethod
    def transcript_values(path: Path, kind: str) -> list[str]:
        pattern = re.compile(rf"^\(authority {re.escape(kind)} 1 \"(.*)\"\)$")
        values: list[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            match = pattern.fullmatch(line)
            if match:
                values.append(match.group(1))
        return values

    def test_real_books_follow_fixed_guile_then_python_ui_route(self) -> None:
        result, transcript = self.run_interaction(
            "positive", self.fixture.make_fake_runsc()
        )
        captures = ""
        for bundle in (self.guile_bundle, self.python_bundle):
            for name in ("runsc.stdout", "runsc.stderr"):
                path = bundle / name
                if path.exists():
                    captures += f"\n{path}:\n{path.read_text(errors='replace')}"
        self.assertEqual(
            result.returncode, 0, result.stdout + result.stderr + captures
        )
        self.assertEqual(
            result.stdout, "BOOKEXEC-READER-PROTOCOL-HOST-TEST=PASS\n"
        )
        self.assertEqual(result.stderr, "")
        self.assert_no_evidence_pass(result)

        inputs = self.transcript_values(transcript, "input-update")
        presents = self.transcript_values(transcript, "present")
        self.assertEqual(len(inputs), 4)
        self.assertEqual(len(presents), 4)
        prefixes = ("Ada|nonce=g-", "élan λ|nonce=g-", "Grace|nonce=p-", "東京|nonce=p-")
        for value, prefix in zip(inputs, prefixes, strict=True):
            self.assertTrue(value.startswith(prefix), value)
            nonce = value.split("|nonce=", 1)[1]
            self.assertRegex(nonce, r"^[gp]-[A-Za-z0-9_-]{16}$")
        self.assertEqual(len(set(inputs)), 4)
        self.assertEqual(
            presents[:2],
            [f"GUILE[{len(value)}]:{value.upper()}" for value in inputs[:2]],
        )
        self.assertEqual(
            presents[2:],
            [f"PYTHON[{len(value)}]:{value[::-1]}" for value in inputs[2:]],
        )

        transcript_lines = transcript.read_text(encoding="utf-8").splitlines()
        tick_lines = [line for line in transcript_lines if line.startswith("(reader tick ")]
        self.assertEqual(
            tick_lines,
            [f'(reader tick 1 "qemu-{index}")' for index in range(1, 5)],
        )
        self.assertEqual(transcript_lines.count('(reader done 1 "ok")'), 1)
        self.assert_runtime_cleaned()
        for bundle in (self.guile_bundle, self.python_bundle):
            observation = json.loads(
                (bundle / "fake-observation.json").read_text(encoding="utf-8")
            )
            self.assertEqual(observation["open_fds"], [0, 1, 2, 3])
            self.assertFalse(observation["fd3_cloexec"])
            self.assertIsNone(
                test_guest_book_protocol.process_start_time(observation["pid"])
            )

    def test_repeated_malformed_and_disconnect_frames_fail_and_cleanup(self) -> None:
        for mode in (
            "repeat-submit",
            "repeat-tick",
            "wrong-generation",
            "malformed",
            "disconnect",
        ):
            with self.subTest(mode=mode):
                # Each subtest needs fresh generated bundles because bounded
                # capture files are deliberately O_EXCL lifecycle evidence.
                if mode != "repeat-submit":
                    self.fixture.tearDown()
                    self.fixture.setUp()
                    self.guile_bundle = self.fixture.guile_bundle
                    self.python_bundle = self.fixture.python_bundle
                result, _transcript = self.run_interaction(
                    mode,
                    self.fixture.make_fake_runsc(f"reader-{mode}"),
                    timeout="3",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(
                    "BOOKEXEC-READER-PROTOCOL-HOST-TEST=PASS", result.stdout
                )
                self.assert_no_evidence_pass(result)
                self.assert_runtime_cleaned()

    def test_crossed_language_endpoint_cannot_reach_success(self) -> None:
        result, _transcript = self.run_interaction(
            "positive", self.fixture.make_fake_runsc("crossed"), timeout="3"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BOOKEXEC-READER-PROTOCOL-HOST-TEST=PASS", result.stdout)
        self.assert_no_evidence_pass(result)
        self.assert_runtime_cleaned()


if __name__ == "__main__":
    unittest.main(verbosity=2)
