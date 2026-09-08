#!/usr/bin/env python3
"""Assemble gVisor's fixed Bazel cache and local Go proxy without network."""

from __future__ import annotations

import argparse
import base64
import json
import shutil
import sys
from pathlib import Path

import vendor_manifest


class InputError(Exception):
    """A fixed input or assembly invariant was violated."""


def safe_relative(value: str, context: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise InputError(f"unsafe {context} path: {value}")
    return path


def copy_verified(source: Path, destination: Path, expected: str, context: str) -> None:
    if not source.is_file():
        raise InputError(f"missing fixed input {context}: {source}")
    actual = vendor_manifest.sha256_file(source)
    if actual != expected:
        raise InputError(f"fixed input hash mismatch for {context}: {actual}, expected {expected}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o444)


def write_verified(data: bytes, destination: Path, expected: str, context: str) -> None:
    actual = __import__("hashlib").sha256(data).hexdigest()
    if actual != expected:
        raise InputError(f"embedded metadata hash mismatch for {context}: {actual}, expected {expected}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    destination.chmod(0o444)


def write_cache_ids(directory: Path, item: dict) -> None:
    for cache_id in item.get("repository_cache_ids", []):
        path = directory / f"id-{cache_id}"
        path.touch()
        path.chmod(0o444)


def read_input_map(path: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise InputError(f"cannot read input map: {error}") from error
    for number, line in enumerate(lines, 1):
        fields = line.split("\t")
        if len(fields) != 2 or not fields[0] or not fields[1]:
            raise InputError(f"invalid input map line {number}")
        if fields[0] in result:
            raise InputError(f"duplicate fixed input id: {fields[0]}")
        result[fields[0]] = Path(fields[1])
    return result


def expected_input_ids(manifest: dict) -> set[str]:
    return {
        "bcr-snapshot",
        manifest["bootstrap"]["bazel"]["id"],
        *(item["id"] for item in manifest["archives"]),
        *(item["id"] for item in manifest["go_modules"]),
    }


def validate_artifacts(manifest: dict, artifacts: Path) -> None:
    files = {
        manifest["lock"]["file"]: manifest["lock"]["sha256"],
        manifest["packaging_transform"]["rules_go_patch"]: manifest["packaging_transform"]["rules_go_patch_sha256"],
    }
    for closure in manifest["closures"].values():
        files[closure["configured_labels_file"]] = closure["configured_labels_sha256"]
    for relative, digest in files.items():
        path = artifacts / safe_relative(relative, "artifact")
        if not path.is_file() or vendor_manifest.sha256_file(path) != digest:
            raise InputError(f"committed artifact hash mismatch: {relative}")


def check_manifest(manifest_path: Path, artifacts: Path | None) -> dict:
    manifest = vendor_manifest.read_json(manifest_path)
    vendor_manifest.validate_manifest(manifest)
    if artifacts is not None:
        validate_artifacts(manifest, artifacts)
    return manifest


def prepare_source(source: Path, sdk_patch: Path) -> None:
    module = source / "MODULE.bazel"
    pristine = "e3ccae67f0470c2332e600322e163d17fedfeedb99a2efbbe7d05a3ee63762c2"
    if vendor_manifest.sha256_file(module) != pristine:
        raise InputError("prepare-source requires the exact clean pinned MODULE.bazel")
    if vendor_manifest.sha256_file(sdk_patch) != vendor_manifest.EXPECTED_SDK_PATCH_HASH:
        raise InputError("offline SDK-index patch hash changed")
    old = '        "//tools:rules_go_sdk.patch",\n        "//tools:rules_cgo.patch",'
    new = '        "//tools:rules_go_sdk.patch",\n        "//tools:rules_go_offline_sdks.patch",\n        "//tools:rules_cgo.patch",'
    text = module.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise InputError("rules_go patch list is not the pinned declaration")
    module.write_text(text.replace(old, new), encoding="utf-8")
    shutil.copyfile(sdk_patch, source / "tools/rules_go_offline_sdks.patch")
    if vendor_manifest.sha256_file(module) != vendor_manifest.EXPECTED_SOURCE_MODULE_HASH:
        raise InputError("prepared MODULE.bazel did not reach the pinned identity")


def assemble(manifest_path: Path, artifacts: Path, input_map_path: Path, output: Path) -> None:
    manifest = check_manifest(manifest_path, artifacts)
    inputs = read_input_map(input_map_path)
    expected = expected_input_ids(manifest)
    missing = sorted(expected - inputs.keys())
    extra = sorted(inputs.keys() - expected)
    if missing:
        raise InputError(f"missing fixed input: {missing[0]}")
    if extra:
        raise InputError(f"undeclared fixed input: {extra[0]}")
    if output.exists() and any(output.iterdir()):
        raise InputError(f"output is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    cas = output / "repository-cache/content_addressable/sha256"
    proxy = output / "go-proxy"
    registry = output / "vendor-registry/bcr.bazel.build"
    share = output / "share/gvisor-release-vendor-inputs"
    bootstrap = output / "bootstrap"

    bcr = inputs["bcr-snapshot"]
    if not bcr.is_dir():
        raise InputError(f"BCR snapshot is not a directory: {bcr}")
    cas_records = manifest["registry_files"] + manifest["bcr_patches"]
    for item in cas_records:
        relative = safe_relative(item["path"], "BCR")
        directory = cas / item["sha256"]
        copy_verified(bcr / relative, directory / "file", item["sha256"], item["path"])
        write_cache_ids(directory, item)
    for item in manifest["registry_files"]:
        relative = safe_relative(item["path"], "BCR")
        copy_verified(bcr / relative, registry / relative, item["sha256"], item["path"])

    for item in manifest["archives"]:
        directory = cas / item["sha256"]
        copy_verified(
            inputs[item["id"]],
            directory / "file",
            item["sha256"],
            item["id"],
        )
        write_cache_ids(directory, item)

    for item in manifest["go_modules"]:
        base = proxy / safe_relative(item["proxy_path"], "Go proxy")
        zip_path = Path(str(base) + ".zip")
        mod_path = Path(str(base) + ".mod")
        info_path = Path(str(base) + ".info")
        copy_verified(inputs[item["id"]], zip_path, item["sha256"], item["id"])
        try:
            mod = base64.b64decode(item["mod_base64"], validate=True)
            info = base64.b64decode(item["info_base64"], validate=True)
        except ValueError as error:
            raise InputError(f"invalid embedded Go metadata for {item['id']}") from error
        write_verified(mod, mod_path, item["mod_sha256"], item["id"] + ".mod")
        write_verified(info, info_path, item["info_sha256"], item["id"] + ".info")

    bazel = manifest["bootstrap"]["bazel"]
    copy_verified(
        inputs[bazel["id"]],
        bootstrap / bazel["file_name"],
        bazel["sha256"],
        bazel["id"],
    )
    (bootstrap / bazel["file_name"]).chmod(0o555)

    share.mkdir(parents=True, exist_ok=True)
    for name in {
        manifest_path.name,
        manifest["lock"]["file"],
        manifest["packaging_transform"]["rules_go_patch"],
        *(item["configured_labels_file"] for item in manifest["closures"].values()),
    }:
        source = manifest_path if name == manifest_path.name else artifacts / name
        shutil.copyfile(source, share / name)
        (share / name).chmod(0o444)
    summary = {
        "bazel_canonical_id_markers": len(list(cas.glob("*/id-*"))),
        "bazel_cas_files": len(list(cas.glob("*/file"))),
        "fixed_input_ids": sorted(expected),
        "go_proxy_files": sum(1 for path in proxy.rglob("*") if path.is_file()),
        "network_access": False,
        "vendor_registry_files": sum(1 for path in registry.rglob("*") if path.is_file()),
    }
    (share / "assembly.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    (share / "assembly.json").chmod(0o444)
    if summary["bazel_cas_files"] != 359:
        raise InputError(f"assembled {summary['bazel_cas_files']} Bazel CAS files, expected 359")
    if summary["bazel_canonical_id_markers"] != 24:
        raise InputError(
            f"assembled {summary['bazel_canonical_id_markers']} canonical-ID markers, expected 24"
        )
    if summary["go_proxy_files"] != 273:
        raise InputError(f"assembled {summary['go_proxy_files']} Go proxy files, expected 273")
    if summary["vendor_registry_files"] != 319:
        raise InputError(
            f"assembled {summary['vendor_registry_files']} vendor registry files, expected 319"
        )
    for path in output.rglob("*"):
        if path.is_symlink():
            raise InputError(f"assembled output contains symlink: {path}")
        if path.is_dir():
            path.chmod(0o555)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check")
    check.add_argument("manifest", type=Path)
    check.add_argument("--artifacts", type=Path)
    prepare = subparsers.add_parser("prepare-source")
    prepare.add_argument("source", type=Path)
    prepare.add_argument("sdk_patch", type=Path)
    build = subparsers.add_parser("assemble")
    build.add_argument("manifest", type=Path)
    build.add_argument("--artifacts", type=Path, required=True)
    build.add_argument("--input-map", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "check":
            check_manifest(args.manifest, args.artifacts)
        elif args.command == "prepare-source":
            prepare_source(args.source, args.sdk_patch)
        else:
            assemble(args.manifest, args.artifacts, args.input_map, args.output)
    except (InputError, vendor_manifest.ManifestError, OSError, ValueError) as error:
        print(f"vendor inputs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
