#!/usr/bin/env python3
"""Focused tests for the gVisor release-vendor boundary."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


MANIFEST_TOOL = Path(sys.argv[1]).resolve()
INPUT_TOOL = Path(sys.argv[2]).resolve()
GOLDEN = Path(sys.argv[3]).resolve()
EMITTER = Path(sys.argv[4]).resolve()
GUIX_INPUTS = Path(sys.argv[5]).resolve()
ARTIFACTS = GOLDEN.parent
OFFLINE_CHECK = ARTIFACTS / "offline-check.sh"
NETWORK_TOOL = ARTIFACTS / "network_namespace.py"
vendor_manifest = load_module("vendor_manifest", MANIFEST_TOOL)
vendor_inputs = load_module("vendor_inputs", INPUT_TOOL)
emit_guix_inputs = load_module("emit_guix_inputs", EMITTER)


class VendorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(GOLDEN.read_text())

    def test_nix_base32_matches_guix(self):
        self.assertEqual(
            vendor_manifest.nix_base32(
                "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
            ),
            "020ay2q1av2xs4n842rb3d7vz8qms1dcb87a5yd6azaci20x11lz",
        )

    def test_go_proxy_escape(self):
        self.assertEqual(
            vendor_manifest.go_unescape("github.com/!google!cloud!platform/project"),
            "github.com/GoogleCloudPlatform/project",
        )
        with self.assertRaises(vendor_manifest.ManifestError):
            vendor_manifest.go_unescape("bad!Escape")

    def test_license_classification(self):
        self.assertEqual(
            vendor_manifest.license_expression(
                b"Apache License\nVersion 2.0, January 2004"
            ),
            "Apache-2.0",
        )
        self.assertEqual(
            vendor_manifest.license_expression(
                b"Permission is hereby granted, free of charge, to any person"
            ),
            "MIT",
        )
        self.assertEqual(
            vendor_manifest.license_expression(
                b"This software is provided 'as-is'. Altered source versions must be marked."
            ),
            "Zlib",
        )

    def test_golden_and_artifacts(self):
        vendor_manifest.validate_manifest(self.manifest)
        vendor_inputs.validate_artifacts(self.manifest, ARTIFACTS)
        self.assertEqual(len(self.manifest["repositories"]), 129)
        self.assertEqual(len(self.manifest["go_modules"]), 91)
        self.assertEqual(
            sum(
                len(item.get("repository_cache_ids", []))
                for group in ("registry_files", "bcr_patches", "archives")
                for item in self.manifest[group]
            ),
            24,
        )

    def test_canonical_id_valid_looking_substitution_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["archives"][0]["repository_cache_ids"][0] = "0" * 64
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "canonical-ID relationship"):
            vendor_manifest.validate_manifest(changed)

    def test_canonical_id_swap_rejected(self):
        changed = copy.deepcopy(self.manifest)
        left, right = changed["archives"][:2]
        left["repository_cache_ids"], right["repository_cache_ids"] = (
            right["repository_cache_ids"],
            left["repository_cache_ids"],
        )
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "canonical-ID relationship"):
            vendor_manifest.validate_manifest(changed)

    def test_reviewer_provenance_counterexample_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["repositories"][0]["provenance"] = {
            "input": "archive-does-not-exist",
            "kind": "unrelated-kind",
            "urls": ["https://example.invalid/unrelated.tar.gz"],
        }
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "nonexistent input"):
            vendor_manifest.validate_manifest(changed)

    def test_provenance_kind_and_url_must_match_input(self):
        for field, value in (
            ("kind", "wrong-kind"),
            ("urls", ["https://example.invalid/wrong-origin.tar.gz"]),
        ):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.manifest)
                changed["repositories"][0]["provenance"][field] = value
                with self.assertRaisesRegex(vendor_manifest.ManifestError, "does not match fixed input"):
                    vendor_manifest.validate_manifest(changed)

    def test_archive_backlink_permutation_rejected(self):
        changed = copy.deepcopy(self.manifest)
        left, right = changed["archives"][:2]
        left["used_by_repositories"], right["used_by_repositories"] = (
            right["used_by_repositories"],
            left["used_by_repositories"],
        )
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "archive repository backlinks"):
            vendor_manifest.validate_manifest(changed)

    def test_go_repository_link_permutation_rejected(self):
        changed = copy.deepcopy(self.manifest)
        left, right = changed["go_modules"][:2]
        left["repository"], right["repository"] = right["repository"], left["repository"]
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "Go repository source/license relationship"):
            vendor_manifest.validate_manifest(changed)

    def test_generated_alias_and_license_inheritance_are_tied(self):
        generated = next(
            index
            for index, item in enumerate(self.manifest["repositories"])
            if "generated_by" in item["provenance"]
        )
        for mutate, expected in (
            (
                lambda item: item["provenance"].update(generated_by="rules_go+"),
                "generated repository alias is invalid",
            ),
            (
                lambda item: item["license"].update(inherits_from="rules_go+"),
                "generated license relationship changed",
            ),
        ):
            with self.subTest(expected=expected):
                changed = copy.deepcopy(self.manifest)
                mutate(changed["repositories"][generated])
                with self.assertRaisesRegex(vendor_manifest.ManifestError, expected):
                    vendor_manifest.validate_manifest(changed)

    def test_unsafe_license_evidence_path_rejected(self):
        changed = copy.deepcopy(self.manifest)
        repository = next(
            item
            for item in changed["repositories"]
            if item["license"]["status"] == "recorded"
        )
        repository["license"]["evidence"][0]["path"] = "../fabricated-license"
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "unsafe license evidence path"):
            vendor_manifest.validate_manifest(changed)

    def test_documented_unknown_license_cannot_be_fabricated(self):
        changed = copy.deepcopy(self.manifest)
        repository = next(
            item for item in changed["repositories"] if item["canonical_name"] == "rules_kotlin+"
        )
        repository["license"] = copy.deepcopy(
            next(
                item["license"]
                for item in changed["repositories"]
                if item["license"]["status"] == "recorded"
            )
        )
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "documented unknown license was replaced"):
            vendor_manifest.validate_manifest(changed)

    def test_license_artifact_permutation_rejected(self):
        changed = copy.deepcopy(self.manifest)
        direct = [
            item
            for item in changed["repositories"]
            if "input" in item["provenance"] and item["license"]["status"] == "recorded"
        ]
        direct[0]["license"], direct[1]["license"] = direct[1]["license"], direct[0]["license"]
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "relationship seal"):
            vendor_manifest.validate_manifest(changed)

    def test_http_origin_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["archives"][0]["urls"][0] = "http://example.invalid/source.tar.gz"
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "non-HTTPS"):
            vendor_manifest.validate_manifest(changed)

    def test_duplicate_input_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["go_modules"][0]["id"] = changed["archives"][0]["id"]
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "not unique"):
            vendor_manifest.validate_manifest(changed)

    def test_registry_traversal_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["registry_files"][0]["path"] = "../escape"
        with self.assertRaisesRegex(vendor_manifest.ManifestError, "unsafe registry path"):
            vendor_manifest.validate_manifest(changed)

    def test_missing_input_is_named(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mapping = root / "inputs.tsv"
            mapping.write_text("")
            result = subprocess.run(
                [
                    sys.executable,
                    str(INPUT_TOOL),
                    "assemble",
                    str(GOLDEN),
                    "--artifacts",
                    str(ARTIFACTS),
                    "--input-map",
                    str(mapping),
                    "--output",
                    str(root / "out"),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing fixed input:", result.stderr)

    def test_tools_have_no_downloader(self):
        for path in (MANIFEST_TOOL, INPUT_TOOL, EMITTER):
            text = path.read_text()
            self.assertNotIn("urllib.request", text)
            self.assertNotIn("requests.get", text)
            self.assertNotIn("curl ", text)

    def test_guix_origin_table_is_generated(self):
        self.assertEqual(emit_guix_inputs.emit(self.manifest), GUIX_INPUTS.read_text())

    def test_offline_check_has_both_negative_boundaries(self):
        text = OFFLINE_CHECK.read_text()
        self.assertIn("rules_go++go_sdk+main___download_0", text)
        self.assertIn("offline analysis accepted a removed required vendor input", text)
        self.assertIn("vendor operation downloaded a removed fixed archive", text)
        self.assertGreaterEqual(text.count("--repository_disable_download"), 4)
        self.assertGreaterEqual(text.count("0 total actions"), 2)
        self.assertIn("GVISOR_OUTER_NETNS_SNAPSHOT is required", text)
        self.assertIn("network_namespace.py\" exec", text)
        self.assertNotIn("curl ", text)
        self.assertNotIn("wget ", text)

    def test_nonisolated_network_namespace_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outer = root / "outer.json"
            evidence = root / "evidence.json"
            subprocess.run(
                [sys.executable, str(NETWORK_TOOL), "capture", "--output", str(outer)],
                check=True,
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(NETWORK_TOOL),
                    "assert-isolated",
                    "--outer",
                    str(outer),
                    "--evidence",
                    str(evidence),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("network namespace did not change", result.stderr)
            self.assertFalse(evidence.exists())


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
