#!/usr/bin/env python3
"""Focused tests for the protocol-control Guix module discovery view."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import prepare_protocol_control_module_view as module_view


class ProtocolControlModuleViewTests(unittest.TestCase):
    def test_view_contains_only_reviewed_modules_pointing_to_originals(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-protocol-module-view.", dir="/tmp/opencode"
        ) as temporary:
            view = Path(temporary) / "view"
            module_view.create_view(view)
            module_view.verify_view(view)
            self.assertEqual(module_view.view_scheme_files(view), set(module_view.MODULES))
            self.assertFalse(any("/tools/" in name for name in module_view.MODULES))
            self.assertEqual(
                (view / module_view.MANIFEST_NAME).read_bytes(),
                module_view.manifest_bytes(),
            )

    def test_package_discovery_view_is_positive_empty_roster(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-protocol-package-view.", dir="/tmp/opencode"
        ) as temporary:
            view = Path(temporary) / "view"
            module_view.create_package_view(view)
            module_view.verify_package_view(view)
            self.assertEqual(
                list(path.name for path in view.iterdir()),
                [module_view.PACKAGE_MARKER_NAME],
            )
            self.assertEqual(list(view.rglob("*.scm")), [])

    def test_reviewed_module_mutation_fails_before_view_use(self) -> None:
        relative = "pinenote/systems/base.scm"
        expected = module_view.MODULES[relative]
        with tempfile.TemporaryDirectory(
            prefix="wilkbook-protocol-module-mutation.", dir="/tmp/opencode"
        ) as temporary:
            mutated = Path(temporary) / "base.scm"
            mutated.write_bytes((module_view.REPO / relative).read_bytes() + b"\n; mutation\n")
            with self.assertRaisesRegex(
                module_view.ModuleViewError,
                r"^module source hash mismatch: pinenote/systems/base\.scm:",
            ):
                module_view.verify_source(mutated, expected, relative)


if __name__ == "__main__":
    unittest.main(verbosity=2)
