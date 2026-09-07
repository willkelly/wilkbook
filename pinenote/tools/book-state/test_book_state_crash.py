#!/usr/bin/env python3
"""Real separate-Guile-process restart and crash tests for Book State."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
WORKER = HERE / "test-worker.scm"


class BookStateCrashTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="book-state-crash.", dir="/tmp/opencode"))
        self.root.chmod(0o700)

    def tearDown(self) -> None:
        allowed = {
            "book-state-v1.sqlite",
            "book-state-v1.sqlite-journal",
            "book-state-v1.sqlite-wal",
            "book-state-v1.sqlite-shm",
        }
        for path in self.root.iterdir():
            self.assertIn(path.name, allowed)
            self.assertFalse(path.is_symlink())
            path.unlink()
        self.root.rmdir()

    def worker(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        environment = {
            "HOME": "/nonexistent",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "GUILE_AUTO_COMPILE": "0",
            "PATH": os.environ["PATH"],
        }
        for name in (
            "GUILE_EXTENSIONS_PATH",
            "GUILE_LOAD_COMPILED_PATH",
            "GUILE_LOAD_PATH",
        ):
            environment[name] = os.environ[name]
        return subprocess.run(
            [
                "guile",
                "--no-auto-compile",
                "-L",
                str(HERE),
                str(WORKER),
                *arguments,
            ],
            cwd=HERE,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )

    def assert_worker(self, expected: str, *arguments: str) -> None:
        result = self.worker(*arguments)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, expected + "\n")

    def database_snapshot(self) -> tuple[tuple[object, ...], list[tuple[object, ...]]]:
        """Use Python only as an independent SQLite recovery/fault oracle."""
        database = self.root / "book-state-v1.sqlite"
        with sqlite3.connect(database) as connection:
            self.assertEqual(connection.execute("PRAGMA quick_check").fetchone(), ("ok",))
            state = connection.execute(
                "SELECT state_version, has_value, text FROM book_instances"
            ).fetchone()
            receipts = connection.execute(
                "SELECT operation_id, expected_state_version, "
                "resulting_state_version, text FROM commit_receipts "
                "ORDER BY resulting_state_version"
            ).fetchall()
        assert state is not None
        return state, receipts

    def test_save_reopen_crash_recovery_and_lost_acknowledgement(self) -> None:
        root = str(self.root)
        self.assert_worker("(absent 0)", "read", root)
        self.assert_worker(
            '(receipt "save-1" 0 1 18)',
            "commit",
            root,
            "none",
            "save-1",
            "0",
            "first durable text",
        )

        # A new Guile process opens the database and sees acknowledged text.
        self.assert_worker('(value 1 "first durable text")', "read", root)
        self.assert_worker(
            '(receipt "save-1" 0 1 18)',
            "commit",
            root,
            "none",
            "save-1",
            "0",
            "first durable text",
        )
        self.assertEqual(
            self.database_snapshot(),
            (
                (1, 1, "first durable text"),
                [("save-1", 0, 1, "first durable text")],
            ),
        )

        # SIGKILL after transactional writes but before COMMIT leaves no value.
        before = self.worker(
            "commit",
            root,
            "before-commit",
            "save-before-crash",
            "1",
            "must roll back",
        )
        self.assertEqual(before.returncode, -signal.SIGKILL, before.stderr)
        self.assertEqual(before.stdout, "")
        # Python's independent SQLite connection performs any hot-journal
        # recovery before asking the new Guile process to reopen the store.
        self.assertEqual(
            self.database_snapshot(),
            (
                (1, 1, "first durable text"),
                [("save-1", 0, 1, "first durable text")],
            ),
        )
        self.assert_worker('(value 1 "first durable text")', "read", root)

        # SIGKILL after COMMIT but before the worker can print its receipt loses
        # the acknowledgement, not the durable value or retry record.
        after = self.worker(
            "commit",
            root,
            "after-commit-before-ack",
            "save-lost-ack",
            "1",
            "survives lost acknowledgement",
        )
        self.assertEqual(after.returncode, -signal.SIGKILL, after.stderr)
        self.assertEqual(after.stdout, "")
        self.assertEqual(
            self.database_snapshot(),
            (
                (2, 1, "survives lost acknowledgement"),
                [
                    ("save-1", 0, 1, "first durable text"),
                    (
                        "save-lost-ack",
                        1,
                        2,
                        "survives lost acknowledgement",
                    ),
                ],
            ),
        )
        self.assert_worker(
            '(value 2 "survives lost acknowledgement")', "read", root
        )
        self.assert_worker(
            '(receipt "save-lost-ack" 1 2 29)',
            "commit",
            root,
            "none",
            "save-lost-ack",
            "1",
            "survives lost acknowledgement",
        )
        self.assert_worker(
            '(receipt "save-1" 0 1 18)',
            "commit",
            root,
            "none",
            "save-1",
            "0",
            "first durable text",
        )
        self.assert_worker(
            "(rejection operation-conflict 2)",
            "commit",
            root,
            "none",
            "save-lost-ack",
            "1",
            "changed retry",
        )
        self.assert_worker(
            "(rejection stale-version 2)",
            "commit",
            root,
            "none",
            "new-stale-operation",
            "1",
            "stale",
        )

        database = self.root / "book-state-v1.sqlite"
        self.assertEqual(database.stat().st_mode & 0o777, 0o600)
        self.assertEqual(database.stat().st_nlink, 1)
        self.assertEqual([path.name for path in self.root.iterdir()], [database.name])


if __name__ == "__main__":
    unittest.main(verbosity=2)
