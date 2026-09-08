#!/usr/bin/env python3
"""Unit tests for inventory.py; accepts its path as the sole argument."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


sys.dont_write_bytecode = True
TOOL = Path(sys.argv.pop(1) if len(sys.argv) > 1 else Path(__file__).with_name("inventory.py"))
SPEC = importlib.util.spec_from_file_location("gvisor_inventory", TOOL)
assert SPEC is not None and SPEC.loader is not None
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def test_starlark_repository_inventory_is_static_and_hash_aware(self) -> None:
        source = """
bazel_dep(name = "rules_go", version = "0.59.0", repo_name = "io_bazel_rules_go")
archive_override(
    module_name = "rules_go",
    integrity = "sha256-pynI7SRHyQ/hQAd2iQecoKz7dYDsQWN/MS1lDOnZPZY=",
    url = "https://example.invalid/rules_go.zip",
)
http_archive(
    name = "llvm-raw",
    sha256 = "e8ece380fdb57dc6f8e42df9db872a1ade5056c5379075e3e2f99c89200aea69",
    urls = ["https://example.invalid/{commit}.tar.gz".format(commit = "abc")],
)
http_file(name = "roots", urls = ["https://example.invalid/roots.pem"])
extension = use_extension("//tools:extension.bzl", "extension")
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "MODULE.bazel")
            path.write_text(source, encoding="utf-8")
            modules, extensions, downloads, _ = inventory.parse_starlark(
                path, "MODULE.bazel"
            )
        self.assertEqual(modules[0]["name"], "rules_go")
        self.assertEqual(modules[0]["repo_name"], "io_bazel_rules_go")
        self.assertEqual(extensions[0]["label"], "//tools:extension.bzl")
        self.assertEqual(len(downloads), 3)
        self.assertEqual(downloads[0]["digest"]["encoding"], "sri-base64")
        self.assertEqual(downloads[1]["urls"], ["https://example.invalid/abc.tar.gz"])
        self.assertIsNone(downloads[2]["digest"])

    def test_maybe_http_archive_is_inventoried(self) -> None:
        source = """
def extension(ctx):
    maybe(
        http_archive,
        name = "zlib",
        sha256 = "e36bb346c00472a1f9ff2a0a4643e590a254be6379da7cddd9daeb9a7f296731",
        urls = ["https://example.invalid/zlib.zip"],
    )
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "extension.bzl")
            path.write_text(source, encoding="utf-8")
            _, _, downloads, _ = inventory.parse_starlark(path, "extension.bzl")
        self.assertEqual([item["id"] for item in downloads], ["http_archive:zlib"])

    def test_selected_go_modules_require_both_sums(self) -> None:
        go_mod = """module example.invalid/root

go 1.26.3

require (
    example.invalid/direct v1.2.3
)

require (
    example.invalid/indirect v0.4.0 // indirect
)
"""
        go_sum = """example.invalid/direct v1.2.3 h1:content-a
example.invalid/direct v1.2.3/go.mod h1:gomod-a
example.invalid/indirect v0.4.0 h1:content-b
example.invalid/indirect v0.4.0/go.mod h1:gomod-b
example.invalid/old v0.1.0/go.mod h1:old
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "go.mod").write_text(go_mod, encoding="utf-8")
            (root / "go.sum").write_text(go_sum, encoding="utf-8")
            version, modules, counts = inventory.parse_go_metadata(
                root / "go.mod", root / "go.sum"
            )
        self.assertEqual(version, "1.26.3")
        self.assertEqual(len(modules), 2)
        self.assertFalse(modules[0]["indirect"])
        self.assertTrue(modules[1]["indirect"])
        self.assertEqual(counts, {"total": 5, "content": 2, "go_mod": 3})

    def test_nonliteral_repository_url_is_rejected(self) -> None:
        source = "http_file(name = \"mutable\", urls = [some_url])\n"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "MODULE.bazel")
            path.write_text(source, encoding="utf-8")
            with self.assertRaises(inventory.InventoryError):
                inventory.parse_starlark(path, "MODULE.bazel")

    def test_bad_integrity_length_is_rejected(self) -> None:
        with self.assertRaises(inventory.InventoryError):
            inventory._digest_record({"integrity": "sha256-YQ=="})

    def test_bazel_version_is_hashed_and_must_exist(self) -> None:
        content = b"8.3.1\n"
        expected = hashlib.sha256(content).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".bazelversion"
            path.write_bytes(content)
            self.assertEqual(
                inventory.validate_file_hashes(root, {".bazelversion": expected}),
                {".bazelversion": expected},
            )
            self.assertEqual(inventory.parse_bazel_version(path), "8.3.1")
            path.write_text("9.0.0\n", encoding="utf-8")
            with self.assertRaisesRegex(inventory.InventoryError, "hash changed"):
                inventory.validate_file_hashes(root, {".bazelversion": expected})
            path.unlink()
            with self.assertRaisesRegex(inventory.InventoryError, "is missing"):
                inventory.validate_file_hashes(root, {".bazelversion": expected})

    def test_bazel_version_rejects_multiple_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, ".bazelversion")
            path.write_text("8.3.1\n9.0.0\n", encoding="utf-8")
            with self.assertRaisesRegex(inventory.InventoryError, "one numeric"):
                inventory.parse_bazel_version(path)

    def test_custom_repository_rule_is_rejected(self) -> None:
        source = """
def _impl(ctx):
    pass

custom_repo = repository_rule(implementation = _impl)
custom_repo(name = "downloaded")
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "extension.bzl")
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(inventory.InventoryError, "repository_rule"):
                inventory.parse_starlark(path, "extension.bzl")

    def test_repository_context_download_is_rejected(self) -> None:
        source = """
def _impl(ctx):
    ctx.download(
        url = "https://example.invalid/source.tar.gz",
        output = "source.tar.gz",
    )
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "extension.bzl")
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(inventory.InventoryError, "ctx.download"):
                inventory.parse_starlark(path, "extension.bzl")

    def test_local_loads_are_traversed_and_hashed(self) -> None:
        extension = 'load(":nested.bzl", "nested_repo")\n'
        nested = """
http_file(
    name = "nested",
    sha256 = "e8ece380fdb57dc6f8e42df9db872a1ade5056c5379075e3e2f99c89200aea69",
    urls = ["https://example.invalid/nested"],
)
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "tools"
            package.mkdir()
            (package / "extension.bzl").write_text(extension, encoding="utf-8")
            (package / "nested.bzl").write_text(nested, encoding="utf-8")
            downloads, traversed = inventory.traverse_local_extensions(
                root,
                [{"label": "//tools:extension.bzl"}],
            )
        self.assertEqual([item["id"] for item in downloads], ["http_file:nested"])
        self.assertEqual(
            [item["path"] for item in traversed],
            ["tools/extension.bzl", "tools/nested.bzl"],
        )
        self.assertEqual(
            traversed[1]["sha256"], hashlib.sha256(nested.encode()).hexdigest()
        )

    def test_dynamic_repository_in_transitive_local_load_is_rejected(self) -> None:
        extension = 'load(":nested.bzl", "nested_repo")\n'
        nested = """
def _impl(ctx):
    ctx.download("https://example.invalid/source.tar.gz", "source.tar.gz")

nested_repo = repository_rule(implementation = _impl)
"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "tools"
            package.mkdir()
            (package / "extension.bzl").write_text(extension, encoding="utf-8")
            (package / "nested.bzl").write_text(nested, encoding="utf-8")
            with self.assertRaisesRegex(
                inventory.InventoryError, "tools/nested.bzl"
            ):
                inventory.traverse_local_extensions(
                    root,
                    [{"label": "//tools:extension.bzl"}],
                )

    def test_traversed_extension_hash_drift_is_rejected(self) -> None:
        traversed = [{"path": "tools/extension.bzl", "sha256": "actual"}]
        with self.assertRaisesRegex(inventory.InventoryError, "hash changed"):
            inventory.validate_traversed_hashes(
                traversed, {"tools/extension.bzl": "expected"}
            )
        with self.assertRaisesRegex(inventory.InventoryError, "set changed"):
            inventory.validate_traversed_hashes(traversed, {})

    def test_lock_summary_has_file_identity_and_resolution_counts(self) -> None:
        lock = """{
  "lockFileVersion": 21,
  "registryFileHashes": {
    "https://bcr.invalid/modules/a/1.0/MODULE.bazel": "sha256-a"
  },
  "moduleExtensions": {
    "@@rules_go//go:extensions.bzl%go_sdk": {}
  }
}
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary, "MODULE.bazel.lock")
            path.write_text(lock, encoding="utf-8")
            summary = inventory.read_lock(path)
        self.assertEqual(summary["sha256"], hashlib.sha256(lock.encode()).hexdigest())
        self.assertEqual(summary["lock_file_version"], 21)
        self.assertEqual(summary["registry_file_hash_count"], 1)
        self.assertEqual(summary["module_extension_count"], 1)


if __name__ == "__main__":
    unittest.main()
