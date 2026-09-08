#!/usr/bin/env python3
"""Focused tests for the finite public source preparer."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("public_source_prepare", HERE / "prepare.py")
assert SPEC and SPEC.loader
prepare_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare_module)


class PreparationTests(unittest.TestCase):
    source_root: Path
    source_map: Path

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wilkbook-public-source-test.", dir="/tmp/opencode"
        )
        self.top = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_real_map_prepares_only_finite_regular_sources(self) -> None:
        output = self.top / "capsule"
        repo, module_view, package_view = prepare_module.prepare(
            self.source_root, output, self.source_map
        )
        entries = prepare_module.load_map(self.source_map)
        mapped = {relative for relative, _, _ in entries}
        actual = {
            path.relative_to(repo).as_posix()
            for path in repo.rglob("*")
            if path.is_file()
        }
        self.assertEqual(actual, mapped)
        for relative in mapped:
            source_mode = (self.source_root / relative).stat().st_mode
            copied_mode = (repo / relative).stat().st_mode
            self.assertEqual(copied_mode & 0o222, 0, relative)
            self.assertEqual(
                copied_mode & 0o111,
                0o111 if source_mode & 0o111 else 0,
                relative,
            )
        self.assertFalse((repo / "pinenote/packages/gvisor-local-test-artifacts.scm").exists())
        self.assertFalse(any("/build/" in f"/{relative}/" for relative in actual))
        module_files = {
            path.relative_to(module_view).as_posix()
            for path in module_view.rglob("*.scm")
            if path.is_symlink()
        }
        self.assertEqual(
            module_files,
            {relative for relative, _, role in entries if role == "module"},
        )
        self.assertEqual(list(package_view.rglob("*.scm")), [])

    def test_hash_mismatch_fails_closed(self) -> None:
        source = self.top / "source"
        source.mkdir()
        (source / "file").write_text("wrong\n", encoding="utf-8")
        entries = [("file", "0" * 64, "asset")]
        original = prepare_module.START_SYSTEMS
        try:
            prepare_module.START_SYSTEMS = set()
            with self.assertRaisesRegex(prepare_module.PreparationError, "hash mismatch"):
                prepare_module.validate_sources(source, entries)
        finally:
            prepare_module.START_SYSTEMS = original

    def test_symlink_input_fails_closed(self) -> None:
        source = self.top / "source"
        source.mkdir()
        target = source / "target"
        target.write_text("data\n", encoding="utf-8")
        (source / "file").symlink_to(target)
        expected = hashlib.sha256(b"data\n").hexdigest()
        original = prepare_module.START_SYSTEMS
        try:
            prepare_module.START_SYSTEMS = set()
            with self.assertRaisesRegex(prepare_module.PreparationError, "symlink"):
                prepare_module.validate_sources(source, [("file", expected, "asset")])
        finally:
            prepare_module.START_SYSTEMS = original

    def test_unsafe_map_path_is_rejected(self) -> None:
        with self.assertRaisesRegex(prepare_module.PreparationError, "unsafe"):
            prepare_module.safe_relative("../outside")

    def test_nonempty_output_is_rejected(self) -> None:
        output = self.top / "output"
        output.mkdir()
        (output / "unexpected").write_text("x", encoding="ascii")
        with self.assertRaisesRegex(prepare_module.PreparationError, "not empty"):
            prepare_module.require_empty_destination(output)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-map", type=Path, required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_arguments()
    PreparationTests.source_root = arguments.source_root
    PreparationTests.source_map = arguments.source_map
    unittest.main(argv=[__file__], verbosity=2)
