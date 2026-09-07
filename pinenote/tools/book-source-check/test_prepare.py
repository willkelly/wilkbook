#!/usr/bin/env python3
"""Fail-closed unit tests for the public source-view preparer."""

from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest


PREPARE_PATH = Path(__file__).resolve().with_name("prepare.py")
PREPARE_SPEC = importlib.util.spec_from_file_location("book_source_prepare", PREPARE_PATH)
if PREPARE_SPEC is None or PREPARE_SPEC.loader is None:
    raise RuntimeError(f"cannot load source preparer: {PREPARE_PATH}")
sys.dont_write_bytecode = True
prepare = importlib.util.module_from_spec(PREPARE_SPEC)
sys.modules[PREPARE_SPEC.name] = prepare
PREPARE_SPEC.loader.exec_module(prepare)


class PrepareTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="book-source-prepare-test.", dir="/tmp/opencode"
        )
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "component").mkdir()
        (self.source / "publication").mkdir()
        self.payload = b"accepted source\n"
        (self.source / "component/module.scm").write_bytes(self.payload)
        self.helper = b"#!/bin/sh\nexit 0\n"
        (self.source / "component/runner.sh").write_bytes(self.helper)
        (self.source / "publication/review.md").write_text("mutable prose\n")
        digest = hashlib.sha256(self.payload).hexdigest()
        helper_digest = hashlib.sha256(self.helper).hexdigest()
        self.rows = [
            prepare.MapRow("repo", "component/module.scm", "module.scm", digest),
            prepare.MapRow("repo", "component/runner.sh", "runner.sh", helper_digest),
        ]
        self.roster = [
            "component/module.scm",
            "component/runner.sh",
            "publication/review.md",
        ]

    def tearDown(self) -> None:
        for directory, subdirectories, filenames in os.walk(
            self.root, topdown=False
        ):
            for name in filenames:
                path = Path(directory, name)
                if not path.is_symlink():
                    path.chmod(0o600)
            for name in subdirectories:
                Path(directory, name).chmod(0o700)
        self.root.chmod(0o700)
        self.temporary.cleanup()

    def prepare(self) -> Path:
        output = self.root / "output"
        prepare.prepare_tree(self.source, output, self.rows, self.roster)
        return output

    def test_valid_source_becomes_private_read_only_view(self) -> None:
        output = self.prepare()
        copied = output / "repo/module.scm"
        self.assertEqual(copied.read_bytes(), self.payload)
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o400)
        self.assertEqual(stat.S_IMODE((output / "repo").stat().st_mode), 0o500)
        self.assertFalse((output / "publication").exists())

    def test_unmapped_publication_prose_is_not_an_execution_input(self) -> None:
        (self.source / "publication/review.md").write_text("honest append\n")
        output = self.prepare()
        self.assertFalse((output / "publication").exists())

    def test_missing_source_is_rejected(self) -> None:
        (self.source / "component/module.scm").unlink()
        with self.assertRaisesRegex(prepare.SourceError, "missing or unlisted"):
            self.prepare()

    def test_changed_source_is_rejected(self) -> None:
        (self.source / "component/module.scm").write_text("changed\n")
        with self.assertRaisesRegex(prepare.SourceError, "hash mismatch"):
            self.prepare()

    def test_mutable_helper_substitution_is_rejected(self) -> None:
        canary = self.root / "helper-substitution-canary"
        (self.source / "component/runner.sh").write_text(
            f"#!/bin/sh\ntouch {canary}\n"
        )
        with self.assertRaisesRegex(prepare.SourceError, "hash mismatch"):
            self.prepare()
        self.assertFalse(canary.exists())

    def test_symlink_source_is_rejected(self) -> None:
        (self.source / "component/module.scm").unlink()
        (self.source / "component/module.scm").symlink_to("elsewhere")
        with self.assertRaisesRegex(prepare.SourceError, "symlink"):
            self.prepare()

    def test_special_source_is_rejected(self) -> None:
        (self.source / "component/module.scm").unlink()
        os.mkfifo(self.source / "component/module.scm")
        with self.assertRaisesRegex(prepare.SourceError, "special file"):
            self.prepare()

    def test_unlisted_shadow_module_is_rejected(self) -> None:
        (self.source / "component/book-state.scm").write_text("shadow\n")
        with self.assertRaisesRegex(prepare.SourceError, "unlisted files"):
            self.prepare()

    def test_nonempty_output_is_rejected(self) -> None:
        output = self.root / "output"
        output.mkdir()
        (output / "old.log").write_text("old\n")
        with self.assertRaisesRegex(prepare.SourceError, "not empty"):
            prepare.prepare_tree(self.source, output, self.rows, self.roster)

    def test_map_rejects_duplicate_destination_and_traversal(self) -> None:
        map_file = self.root / "map.tsv"
        digest = hashlib.sha256(self.payload).hexdigest()
        map_file.write_text(
            "view\tsource_path\tdestination_path\tsha256\n"
            f"repo\tcomponent/module.scm\tmodule.scm\t{digest}\n"
            f"repo\tcomponent/module.scm\tmodule.scm\t{digest}\n"
        )
        with self.assertRaisesRegex(prepare.SourceError, "duplicate destination"):
            prepare.parse_map(map_file)
        map_file.write_text(
            "view\tsource_path\tdestination_path\tsha256\n"
            f"repo\t../module.scm\tmodule.scm\t{digest}\n"
        )
        with self.assertRaisesRegex(prepare.SourceError, "escapes"):
            prepare.parse_map(map_file)


if __name__ == "__main__":
    unittest.main(verbosity=2)
