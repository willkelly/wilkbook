#!/usr/bin/env python3
"""Focused tests for the reader-interaction Guix discovery views."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import prepare_reader_interaction_module_view as reader_view


class ReaderInteractionModuleViewTests(unittest.TestCase):
    def test_view_is_exact_accepted_nineteen_plus_reader_system(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-reader-module-view.", dir="/tmp/opencode"
        ) as temporary:
            view = Path(temporary) / "view"
            reader_view.create_view(view)
            reader_view.verify_view(view)
            self.assertEqual(len(reader_view.MODULES), 20)
            self.assertEqual(
                set(reader_view.MODULES) - {reader_view.READER_SYSTEM},
                set(reader_view.ACCEPTED_PROTOCOL_MODULES),
            )
            self.assertEqual(
                reader_view.MODULES[reader_view.PROTOCOL_SYSTEM],
                reader_view.PROTOCOL_SYSTEM_SHA256,
            )
            self.assertEqual(
                reader_view.MODULES[reader_view.READER_SYSTEM],
                reader_view.READER_SYSTEM_SHA256,
            )
            self.assertEqual(
                reader_view.base.view_scheme_files(view),
                set(reader_view.MODULES),
            )
            self.assertFalse(any("/tools/" in name for name in reader_view.MODULES))
            self.assertEqual(
                (view / reader_view.base.MANIFEST_NAME).read_bytes(),
                reader_view.manifest_bytes(),
            )

    def test_package_discovery_view_has_no_scheme_input(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-reader-package-view.", dir="/tmp/opencode"
        ) as temporary:
            view = Path(temporary) / "view"
            reader_view.create_package_view(view)
            reader_view.verify_package_view(view)
            self.assertEqual(
                [path.name for path in view.iterdir()],
                [reader_view.base.PACKAGE_MARKER_NAME],
            )
            self.assertEqual(list(view.rglob("*.scm")), [])

    def test_reader_system_drift_fails_before_view_use(self) -> None:
        relative = reader_view.READER_SYSTEM
        expected = reader_view.MODULES[relative]
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-reader-module-mutation.", dir="/tmp/opencode"
        ) as temporary:
            mutated = Path(temporary) / "reader.scm"
            mutated.write_bytes(
                (reader_view.base.REPO / relative).read_bytes() + b"\n; mutation\n"
            )
            with self.assertRaisesRegex(
                reader_view.base.ModuleViewError,
                r"^module source hash mismatch: "
                r"pinenote/systems/pinenote-book-execution-reader-interaction\.scm:",
            ):
                reader_view.base.verify_source(mutated, expected, relative)


if __name__ == "__main__":
    unittest.main(verbosity=2)
