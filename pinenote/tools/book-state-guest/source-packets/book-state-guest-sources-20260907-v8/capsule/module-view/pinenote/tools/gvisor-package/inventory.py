#!/usr/bin/env python3
"""Inventory the network-facing inputs declared by the pinned gVisor tree.

This is deliberately a source-preparation tool, not a Bazel downloader.  It
reads source metadata without evaluating Starlark, records the content
identities that upstream provides, and makes unresolved Bzlmod work visible.
"""

from __future__ import annotations

import argparse
import ast
import base64
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCHEMA = 1
EXPECTED_COMMIT = "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
EXPECTED_RELEASE = "release-20260831.0"
EXPECTED_GUIX_SOURCE_HASH = "12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy"
EXPECTED_GO_VERSION = "1.26.3"
EXPECTED_FILE_HASHES = {
    ".bazelversion": "ae67852a5438406008e522aa560f339ddd42665d68cc2560b711cba082b074bb",
    "LICENSE": "0fbab5c58efbdf6d31e8085214f2dd821659c03d73cff3ed2b08e98826ea1cd9",
    "MODULE.bazel": "e3ccae67f0470c2332e600322e163d17fedfeedb99a2efbbe7d05a3ee63762c2",
    "go.mod": "2003903d9f23d5bcc09493b6e3178f3224fbdad74ba12e3adf3699637285120c",
    "go.sum": "5d3c42a2456135454d8db74aeed5f20f2ef3f6f7cc5a5d652c07a6c871fb3ba4",
}
EXPECTED_LOCAL_EXTENSION_HASHES = {
    "tools/bazeldefs/extensions/coral_crosstool.bzl": (
        "7f4b83da54fc611e5616a113754184546c4694687eb7d2c68f10d40e5fa1a126"
    ),
    "tools/bazeldefs/extensions/crosstool.bzl": (
        "e5b34fbb1c15f0411e2979e3f7acae9445cec0f56f310d1b97efd6ad7d1dbcb8"
    ),
    "tools/bazeldefs/extensions/llvm_zlib.bzl": (
        "384f6525628e193879ab166df3c2d4194e2849840ef58b73825bc4345c31ac05"
    ),
}


class InventoryError(Exception):
    """A source invariant or inventory invariant was violated."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_file_hashes(source: Path, expected_hashes: dict[str, str]) -> dict[str, str]:
    actual_hashes: dict[str, str] = {}
    for relative, expected in expected_hashes.items():
        path = source / relative
        if not path.is_file():
            raise InventoryError(f"pinned source file is missing: {relative}")
        actual = sha256_file(path)
        if actual != expected:
            raise InventoryError(
                f"pinned source file hash changed: {relative}: {actual}, expected {expected}"
            )
        actual_hashes[relative] = actual
    return dict(sorted(actual_hashes.items()))


def parse_bazel_version(path: Path) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise InventoryError(f"cannot read .bazelversion: {error}") from error
    if len(lines) != 1 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", lines[0]):
        raise InventoryError(".bazelversion must contain one numeric version line")
    return lines[0]


def _call_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        parent = _call_name(node.value)
        return f"{parent}.{node.attr}" if parent else node.attr
    return None


def _static_value(node: ast.AST) -> Any:
    """Evaluate the small literal subset used by gVisor repository rules."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_static_value(item) for item in node.elts]
    if isinstance(node, ast.Dict):
        return {
            _static_value(key): _static_value(value)
            for key, value in zip(node.keys, node.values)
        }
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "format"
    ):
        template = _static_value(node.func.value)
        if not isinstance(template, str):
            raise InventoryError("format receiver is not a literal string")
        args = [_static_value(arg) for arg in node.args]
        kwargs = {
            keyword.arg: _static_value(keyword.value)
            for keyword in node.keywords
            if keyword.arg is not None
        }
        if len(kwargs) != len(node.keywords):
            raise InventoryError("** expansion is not allowed in a repository URL")
        return template.format(*args, **kwargs)
    raise InventoryError(
        f"repository identity is not a static literal at line "
        f"{getattr(node, 'lineno', '?')}"
    )


def _call_keywords(call: ast.Call) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for keyword in call.keywords:
        if keyword.arg is None:
            raise InventoryError(
                f"repository call uses ** expansion at line {call.lineno}"
            )
        result[keyword.arg] = _static_value(keyword.value)
    return result


def _digest_record(fields: dict[str, Any]) -> dict[str, str] | None:
    sha256 = fields.get("sha256")
    integrity = fields.get("integrity")
    if sha256 and integrity:
        raise InventoryError("repository declares both sha256 and integrity")
    if sha256:
        if not isinstance(sha256, str) or len(sha256) != 64:
            raise InventoryError(f"invalid hexadecimal SHA-256: {sha256!r}")
        try:
            bytes.fromhex(sha256)
        except ValueError as error:
            raise InventoryError(f"invalid hexadecimal SHA-256: {sha256!r}") from error
        return {"algorithm": "sha256", "encoding": "hex", "value": sha256}
    if integrity:
        if not isinstance(integrity, str) or not integrity.startswith("sha256-"):
            raise InventoryError(f"unsupported integrity digest: {integrity!r}")
        try:
            decoded = base64.b64decode(integrity.removeprefix("sha256-"), validate=True)
        except ValueError as error:
            raise InventoryError(f"invalid SHA-256 integrity digest: {integrity!r}") from error
        if len(decoded) != 32:
            raise InventoryError(f"invalid SHA-256 integrity length: {integrity!r}")
        return {
            "algorithm": "sha256",
            "encoding": "sri-base64",
            "value": integrity,
        }
    return None


def parse_starlark(
    path: Path, display_path: str
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, str]],
]:
    """Return directly visible modules, extensions, downloads, and loads."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=display_path)
    except SyntaxError as error:
        raise InventoryError(f"cannot parse {display_path}: {error}") from error

    modules: list[dict[str, Any]] = []
    extensions: list[dict[str, Any]] = []
    downloads: list[dict[str, Any]] = []
    loads: list[dict[str, str]] = []
    for call in sorted(
        (node for node in ast.walk(tree) if isinstance(node, ast.Call)),
        key=lambda node: (node.lineno, node.col_offset),
    ):
        name = _call_name(call.func)
        declaration = f"{display_path}:{call.lineno}"
        primitive = name.rsplit(".", 1)[-1] if name else None
        if primitive in {"download", "download_and_extract", "repository_rule"}:
            raise InventoryError(
                f"unsupported dynamic repository primitive {name} at {declaration}"
            )
        if name == "load":
            if not call.args:
                raise InventoryError(f"load has no label at {declaration}")
            label = _static_value(call.args[0])
            if not isinstance(label, str):
                raise InventoryError(f"non-static load label at {declaration}")
            loads.append({"label": label, "declaration": declaration})
            continue
        if name == "bazel_dep":
            fields = _call_keywords(call)
            record = {
                "name": fields.get("name"),
                "version": fields.get("version"),
                "declaration": declaration,
            }
            if fields.get("repo_name"):
                record["repo_name"] = fields["repo_name"]
            if not isinstance(record["name"], str) or not isinstance(record["version"], str):
                raise InventoryError(f"non-static bazel_dep at {declaration}")
            modules.append(record)
            continue
        if name == "use_extension":
            if len(call.args) < 2:
                raise InventoryError(f"incomplete use_extension at {declaration}")
            label = _static_value(call.args[0])
            extension = _static_value(call.args[1])
            if not isinstance(label, str) or not isinstance(extension, str):
                raise InventoryError(f"non-static use_extension at {declaration}")
            extensions.append(
                {"label": label, "extension": extension, "declaration": declaration}
            )
            continue

        rule = name
        args = list(call.args)
        if name == "maybe" and args and _call_name(args[0]) == "http_archive":
            rule = "http_archive"
            args = args[1:]
        if rule not in {"archive_override", "http_archive", "http_file"}:
            continue
        if args:
            raise InventoryError(
                f"positional repository arguments are not supported at {declaration}"
            )
        fields = _call_keywords(call)
        identity_key = "module_name" if rule == "archive_override" else "name"
        identity = fields.get(identity_key)
        if not isinstance(identity, str):
            raise InventoryError(f"repository has no static identity at {declaration}")
        urls = fields.get("urls")
        if urls is None and "url" in fields:
            urls = [fields["url"]]
        if not isinstance(urls, list) or not urls or not all(
            isinstance(url, str) for url in urls
        ):
            raise InventoryError(f"repository has no static URL list at {declaration}")
        record = {
            "id": f"{rule}:{identity}",
            "rule": rule,
            "name": identity,
            "urls": urls,
            "digest": _digest_record(fields),
            "declaration": declaration,
        }
        if isinstance(fields.get("strip_prefix"), str):
            record["strip_prefix"] = fields["strip_prefix"]
        downloads.append(record)
    return modules, extensions, downloads, loads


def local_label_path(label: str, importer: str | None = None) -> str | None:
    if label.startswith("@//"):
        label = label[1:]
    if label.startswith("@"):
        return None
    if label.startswith("//"):
        body = label[2:]
        if ":" in body:
            package, filename = body.split(":", 1)
            relative = Path(package, filename)
        else:
            relative = Path(body)
    elif label.startswith(":") and importer is not None:
        relative = Path(importer).parent / label[1:]
    else:
        return None
    if not relative.name.endswith(".bzl") or ".." in relative.parts:
        raise InventoryError(f"unsafe local extension label: {label}")
    return str(relative)


def traverse_local_extensions(
    source: Path, extensions: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Parse local use_extension roots and their transitively local loads."""
    queue: list[str] = []
    for extension in extensions:
        relative = local_label_path(extension["label"])
        if relative is not None:
            queue.append(relative)

    visited: set[str] = set()
    downloads: list[dict[str, Any]] = []
    traversed: list[dict[str, str]] = []
    while queue:
        relative = queue.pop(0)
        if relative in visited:
            continue
        visited.add(relative)
        path = source / relative
        if not path.is_file():
            raise InventoryError(f"local Starlark dependency is missing: {relative}")
        modules, nested_extensions, nested_downloads, loads = parse_starlark(
            path, relative
        )
        if modules:
            raise InventoryError(f"bazel_dep is invalid in local extension: {relative}")
        if nested_extensions:
            raise InventoryError(f"nested use_extension is not inventoried: {relative}")
        traversed.append({"path": relative, "sha256": sha256_file(path)})
        downloads.extend(nested_downloads)
        for load in loads:
            loaded = local_label_path(load["label"], relative)
            if loaded is not None and loaded not in visited:
                queue.append(loaded)
    traversed.sort(key=lambda item: item["path"])
    return downloads, traversed


def validate_traversed_hashes(
    traversed: list[dict[str, str]], expected_hashes: dict[str, str]
) -> None:
    actual = {item["path"]: item["sha256"] for item in traversed}
    if set(actual) != set(expected_hashes):
        added = sorted(set(actual) - set(expected_hashes))
        missing = sorted(set(expected_hashes) - set(actual))
        raise InventoryError(
            f"traversed local extension set changed: added={added!r}, missing={missing!r}"
        )
    for relative, expected in expected_hashes.items():
        if actual[relative] != expected:
            raise InventoryError(
                f"traversed local extension hash changed: {relative}: "
                f"{actual[relative]}, expected {expected}"
            )


def parse_go_metadata(go_mod: Path, go_sum: Path) -> tuple[str, list[dict[str, Any]], dict[str, int]]:
    go_version: str | None = None
    selected: list[dict[str, Any]] = []
    in_require = False
    for line_number, line in enumerate(go_mod.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("go ") and not in_require:
            fields = stripped.split()
            if len(fields) == 2:
                go_version = fields[1]
        if stripped == "require (":
            in_require = True
            continue
        if in_require and stripped == ")":
            in_require = False
            continue
        if not in_require or not stripped or stripped.startswith("//"):
            continue
        requirement, _, comment = stripped.partition("//")
        fields = requirement.split()
        if len(fields) != 2:
            raise InventoryError(f"cannot parse go.mod requirement at line {line_number}")
        selected.append(
            {
                "path": fields[0],
                "version": fields[1],
                "indirect": comment.strip() == "indirect",
            }
        )
    if go_version is None:
        raise InventoryError("go.mod has no Go language version")

    sums: dict[tuple[str, str], str] = {}
    content_lines = 0
    go_mod_lines = 0
    total_lines = 0
    for line_number, line in enumerate(go_sum.read_text(encoding="utf-8").splitlines(), 1):
        if not line:
            continue
        fields = line.split()
        if len(fields) != 3 or not fields[2].startswith("h1:"):
            raise InventoryError(f"cannot parse go.sum at line {line_number}")
        key = (fields[0], fields[1])
        if key in sums:
            raise InventoryError(f"duplicate go.sum identity: {fields[0]} {fields[1]}")
        sums[key] = fields[2]
        total_lines += 1
        if fields[1].endswith("/go.mod"):
            go_mod_lines += 1
        else:
            content_lines += 1

    seen: set[tuple[str, str]] = set()
    for module in selected:
        identity = (module["path"], module["version"])
        if identity in seen:
            raise InventoryError(f"duplicate selected Go module: {identity!r}")
        seen.add(identity)
        content_sum = sums.get(identity)
        metadata_sum = sums.get((identity[0], identity[1] + "/go.mod"))
        if content_sum is None or metadata_sum is None:
            raise InventoryError(
                f"selected Go module lacks content or go.mod sum: {identity[0]} {identity[1]}"
            )
        module["go_content_sum"] = content_sum
        module["go_mod_sum"] = metadata_sum
    selected.sort(key=lambda module: (module["path"], module["version"]))
    return go_version, selected, {
        "total": total_lines,
        "content": content_lines,
        "go_mod": go_mod_lines,
    }


def detect_commit(source: Path, supplied: str | None) -> str:
    if supplied is not None:
        return supplied
    try:
        result = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        status = subprocess.run(
            [
                "git",
                "-C",
                str(source),
                "status",
                "--porcelain",
                "--untracked-files=all",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        raise InventoryError(
            "source has no Git identity; pass --source-commit from its fixed origin"
        ) from error
    if status.stdout:
        raise InventoryError("Git source tree is not clean")
    return result.stdout.strip()


def read_lock(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise InventoryError(f"cannot read Bazel lock {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise InventoryError("Bazel lock root is not an object")
    registry_hashes = parsed.get("registryFileHashes", {})
    extensions = parsed.get("moduleExtensions", {})
    return {
        "sha256": sha256_file(path),
        "lock_file_version": parsed.get("lockFileVersion"),
        "registry_file_hash_count": len(registry_hashes)
        if isinstance(registry_hashes, dict)
        else None,
        "module_extension_count": len(extensions)
        if isinstance(extensions, dict)
        else None,
    }


def inventory(source: Path, supplied_commit: str | None, lock: Path | None) -> dict[str, Any]:
    source = source.resolve()
    metadata_hashes = validate_file_hashes(source, EXPECTED_FILE_HASHES)
    bazel_version = parse_bazel_version(source / ".bazelversion")
    commit = detect_commit(source, supplied_commit)
    if commit != EXPECTED_COMMIT:
        raise InventoryError(f"wrong gVisor commit: {commit}, expected {EXPECTED_COMMIT}")

    modules, extensions, downloads, root_loads = parse_starlark(
        source / "MODULE.bazel", "MODULE.bazel"
    )
    local_root_loads = [
        load for load in root_loads if local_label_path(load["label"], "MODULE.bazel")
    ]
    if local_root_loads:
        raise InventoryError(
            "local load from MODULE.bazel is unsupported: "
            + ", ".join(load["label"] for load in local_root_loads)
        )
    nested_downloads, traversed = traverse_local_extensions(source, extensions)
    validate_traversed_hashes(traversed, EXPECTED_LOCAL_EXTENSION_HASHES)
    downloads.extend(nested_downloads)

    modules.sort(key=lambda module: module["name"])
    extensions.sort(key=lambda item: (item["label"], item["extension"]))
    downloads.sort(key=lambda item: item["id"])
    duplicate_downloads = [
        downloads[index]["id"]
        for index in range(1, len(downloads))
        if downloads[index - 1]["id"] == downloads[index]["id"]
    ]
    if duplicate_downloads:
        raise InventoryError(f"duplicate explicit repositories: {duplicate_downloads!r}")

    go_version, go_modules, go_sum_counts = parse_go_metadata(
        source / "go.mod", source / "go.sum"
    )
    if go_version != EXPECTED_GO_VERSION:
        raise InventoryError(
            f"wrong Go language/toolchain version: {go_version}, expected {EXPECTED_GO_VERSION}"
        )
    lock_record = read_lock(lock)
    unhashed = [download["id"] for download in downloads if download["digest"] is None]
    blockers = []
    if lock_record is None:
        blockers.append(
            "MODULE.bazel.lock is absent; BCR modules and extension-generated repositories are unresolved"
        )
    else:
        blockers.append(
            "the Bazel lock identifies resolution results but resolved archives are not yet separate Guix fixed-output inputs"
        )
    if unhashed:
        blockers.append(
            "explicit HTTP repositories without a digest: " + ", ".join(unhashed)
        )
    blockers.append(
        "Go h1 sums authenticate module contents but are not recorded Guix origin hashes for fetched archives"
    )
    blockers.append(
        "Bazel 8.3.1 and the Go 1.26.3 SDK bootstrap inputs are not defined by this source inventory"
    )

    return {
        "schema": SCHEMA,
        "source": {
            "project": "gVisor",
            "release": EXPECTED_RELEASE,
            "commit": commit,
            "source_date_epoch": 1788467832,
            "guix_recursive_sha256_base32": EXPECTED_GUIX_SOURCE_HASH,
            "metadata_sha256": metadata_hashes,
        },
        "bazel": {
            "required_version": bazel_version,
            "direct_modules": modules,
            "module_extensions": extensions,
            "traversed_local_extensions": traversed,
            "explicit_http_downloads": downloads,
            "lock": lock_record,
        },
        "go": {
            "required_version": go_version,
            "selected_modules": go_modules,
            "go_sum_line_counts": go_sum_counts,
            "checksum_scope": (
                "Go h1 directory checksums from go.sum; these are dependency "
                "identities, not Guix fixed-output archive SHA-256 values"
            ),
        },
        "packaging": {
            "ready_for_networkless_source_build": False,
            "blockers": blockers,
            "explicit_download_count": len(downloads),
            "explicit_content_addressed_count": len(downloads) - len(unhashed),
            "explicit_unhashed_ids": unhashed,
        },
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="pinned gVisor source tree")
    parser.add_argument(
        "--source-commit",
        help="commit asserted by the enclosing fixed-output origin when .git is absent",
    )
    parser.add_argument("--lock", type=Path, help="generated MODULE.bazel.lock")
    parser.add_argument("--output", type=Path, help="write JSON here instead of stdout")
    parser.add_argument(
        "--require-lock",
        action="store_true",
        help="fail if no generated Bazel lock was supplied",
    )
    parser.add_argument(
        "--require-explicit-hashes",
        action="store_true",
        help="fail if any explicit http_archive/http_file lacks a digest",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        result = inventory(args.source, args.source_commit, args.lock)
        if args.require_lock and result["bazel"]["lock"] is None:
            raise InventoryError("a generated MODULE.bazel.lock is required")
        unhashed = result["packaging"]["explicit_unhashed_ids"]
        if args.require_explicit_hashes and unhashed:
            raise InventoryError(
                "explicit repositories lack hashes: " + ", ".join(unhashed)
            )
    except InventoryError as error:
        print(f"gvisor-source-inventory: {error}", file=sys.stderr)
        return 2

    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
