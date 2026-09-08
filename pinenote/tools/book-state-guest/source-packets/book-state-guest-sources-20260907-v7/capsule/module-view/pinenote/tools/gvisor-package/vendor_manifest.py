#!/usr/bin/env python3
"""Generate and validate the fixed //:release dependency manifest.

Generation consumes the isolated output of vendor-discover.sh.  It does not
download anything or evaluate Bazel; the generated manifest is the boundary
between network-authorized discovery and ordinary networkless Guix builds.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SCHEMA = 1
EXPECTED_COMMIT = "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
EXPECTED_RELEASE = "release-20260831.0"
EXPECTED_LOCK_HASH = "8402c7beb4baf2c666f4b78e400ea3f15514b56117598c2cb5411d6a35208d34"
EXPECTED_BAZEL_HASH = "17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c"
EXPECTED_BCR_COMMIT = "a5e087e21fcac28ff105ffc5eaeca966e61057af"
EXPECTED_BCR_NAR_HASH = "057akiiiqiigylnrsi7bqyrdkfhq1h1xpsblrpyni6p614wz8paz"
EXPECTED_BCR_NAR_HASH_HEX = "5f5df43909e69a68fdcd74e9db030c18bad9b2c7eb449d2df52f461c639cea14"
EXPECTED_SDK_PATCH_HASH = "e04ae0d3acf5502887130edd7651393fb15aa20ed3fdc19cdf9530f12555c460"
EXPECTED_SOURCE_MODULE_HASH = "11413ed198eff2b36dcd5692e6d84f9d343a24b2c56ecaad9026864cc51d08f8"
EXPECTED_CLOSURE_HASHES = {
    "native-x86_64": "9412d5a8944f727ca402d864f2504de30809df71e9d0fabd307b9b6c837e573f",
    "aarch64": "60473defe06cb496ad55ebac640e21a1799444441c5111c2c8df4655dd0f4777",
}
EXPECTED_VENDOR_MEMBERS_HASH = "8d9c258d3ae97d468d2d83dc0d781824a4171eecad50e849a1bcce9fd6d0df2c"
EXPECTED_CACHE_ID_MAPPING_HASH = "29acb447986ca0c9e5b9ec29abf7305c082b5ce52a06ba50c24ec6c788129715"
EXPECTED_RELATIONSHIPS_HASH = "f1f8cc762586e9b2ad662c508815223d7f8609b076949d4d1c953c331a4bc3dc"
EXPECTED_UNKNOWN_LICENSE_REPOSITORIES = {"rules_kotlin+"}
LICENSE_EXPRESSIONS = {
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "CC-BY-SA-4.0",
    "ISC",
    "MIT",
    "MPL-2.0",
    "Zlib",
}
GO_SDK_INDEX = [
    ("1.23.0", "905a297f19ead44780548933e0ff1a1b86e8327bb459e92f9c0012569f76f5e3"),
    ("1.24.0", "dea9ca38a0b852a74e81c26134671af7c0fbe65d81b0dc1c5bfe22cf7d4c8858"),
    ("1.24.6", "bbca37cc395c974ffa4893ee35819ad23ebb27426df87af92e93a9ec66ef8712"),
    ("1.25.0", "2852af0cb20a13139b3448992e69b868e50ed0f8a1e5940ee1de9e19a123b613"),
    ("1.26.3", "2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556"),
]
EXPECTED_COUNTS = {
    "archives": 25,
    "bcr_patches": 15,
    "go_modules": 91,
    "registry_files": 319,
    "repositories": 129,
    "vendor_members": 261,
    "native_labels": 18812,
    "aarch64_labels": 18791,
    "repository_cache_ids": 24,
}
NIX_BASE32 = "0123456789abcdfghijklmnpqrsvwxyz"


class ManifestError(Exception):
    """A discovery or fixed-input invariant was violated."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def nix_base32(hex_digest: str) -> str:
    raw = bytes.fromhex(hex_digest)
    result = []
    for n in range((len(raw) * 8 - 1) // 5, -1, -1):
        bit = n * 5
        index = bit // 8
        value = raw[index] >> (bit % 8)
        if index + 1 < len(raw):
            value |= raw[index + 1] << (8 - bit % 8)
        result.append(NIX_BASE32[value & 0x1F])
    return "".join(result)


def digest_from_integrity(value: str) -> str:
    if value.startswith("sha256-"):
        raw = base64.b64decode(value.removeprefix("sha256-"), validate=True)
        if len(raw) != 32:
            raise ManifestError(f"invalid SHA-256 integrity: {value}")
        return raw.hex()
    if re.fullmatch(r"[0-9a-f]{64}", value):
        return value
    raise ManifestError(f"unsupported digest: {value}")


def safe_id(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not result:
        raise ManifestError(f"cannot derive input id from {value!r}")
    return result


def go_unescape(value: str) -> str:
    result = []
    index = 0
    while index < len(value):
        if value[index] == "!":
            if index + 1 == len(value) or not value[index + 1].islower():
                raise ManifestError(f"invalid Go proxy escape: {value}")
            result.append(value[index + 1].upper())
            index += 2
        else:
            result.append(value[index])
            index += 1
    return "".join(result)


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as source:
            value = json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"expected JSON object in {path}")
    return value


def license_expression(data: bytes) -> str | None:
    text = data.decode("utf-8", errors="ignore").lower()
    if "apache license" in text and "version 2.0" in text:
        return "Apache-2.0"
    if "mozilla public license version 2.0" in text:
        return "MPL-2.0"
    if "permission is hereby granted, free of charge" in text:
        return "MIT"
    if "redistribution and use in source and binary forms" in text:
        return "BSD-3-Clause" if "neither the name" in text else "BSD-2-Clause"
    if "permission to use, copy, modify, and/or distribute" in text:
        return "ISC"
    if "this software is provided 'as-is'" in text and "altered source versions" in text:
        return "Zlib"
    if "attribution-sharealike 4.0 international" in text:
        return "CC-BY-SA-4.0"
    return None


def license_evidence(repository: Path) -> dict[str, Any]:
    candidates: list[Path] = []
    for path in repository.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(repository)
        if len(relative.parts) > 3:
            continue
        name = path.name.lower()
        if re.match(r"^(license|licence|copying)(\.|$|-)", name):
            candidates.append(path)
    if not candidates:
        return {"evidence": [], "spdx": [], "status": "missing"}
    depth = min(len(path.relative_to(repository).parts) for path in candidates)
    candidates = [
        path
        for path in sorted(candidates)
        if len(path.relative_to(repository).parts) == depth
    ]
    evidence = []
    expressions = set()
    for path in candidates:
        data = path.read_bytes()
        expression = license_expression(data)
        if expression:
            expressions.add(expression)
        evidence.append(
            {
                "path": str(path.relative_to(repository)),
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "spdx": expression,
            }
        )
    return {
        "evidence": evidence,
        "spdx": sorted(expressions),
        "status": "recorded" if all(item["spdx"] for item in evidence) else "partial",
    }


def module_name(repository: Path) -> str | None:
    path = repository / "MODULE.bazel"
    if not path.is_file():
        return None
    match = re.search(r"\bmodule\s*\(.*?\bname\s*=\s*\"([^\"]+)\"", path.read_text(), re.S)
    return match.group(1) if match else None


def source_record(source_json: Path) -> dict[str, Any]:
    value = read_json(source_json)
    digest = digest_from_integrity(value.get("integrity") or value.get("sha256", ""))
    urls = value.get("urls") or value.get("url")
    if isinstance(urls, str):
        urls = [urls]
    if not isinstance(urls, list) or not all(isinstance(item, str) for item in urls):
        raise ManifestError(f"invalid URLs in {source_json}")
    relative = source_json.parent.parts
    return {
        "identity": f"{relative[-2]}@{relative[-1]}",
        "kind": "bcr-module",
        "module": relative[-2],
        "version": relative[-1],
        "sha256": digest,
        "urls": urls,
    }


def find_bcr_files_by_hash(root: Path) -> dict[str, list[Path]]:
    result: dict[str, list[Path]] = {}
    for path in root.rglob("*"):
        if path.is_file():
            result.setdefault(sha256_file(path), []).append(path)
    return result


def repository_cache_ids(cache: Path, digest: str) -> list[str]:
    """Return Bazel's canonical-ID markers for one content hash."""
    result = []
    for path in (cache / digest).glob("id-*"):
        value = path.name.removeprefix("id-")
        if not re.fullmatch(r"[0-9a-f]{64}", value) or path.stat().st_size != 0:
            raise ManifestError(f"invalid repository cache canonical-ID marker: {path}")
        result.append(value)
    return sorted(result)


def default_http_canonical_id(urls: list[str]) -> str:
    """Return Bazel http rules' default canonical-ID marker identity.

    Bazel keys the marker by SHA-256 of its canonical ID.  When no explicit
    canonical_id is set, the HTTP repository rules use the space-joined URL
    list as that canonical ID.
    """
    return hashlib.sha256(" ".join(urls).encode("utf-8")).hexdigest()


def cache_id_mapping_hash(archives: list[dict[str, Any]]) -> str:
    rows = sorted(
        f"{item['sha256']}\t{cache_id}"
        for item in archives
        for cache_id in item.get("repository_cache_ids", [])
    )
    return hashlib.sha256(("\n".join(rows) + "\n").encode("utf-8")).hexdigest()


def relationship_hash(manifest: dict[str, Any]) -> str:
    projection = {
        "archives": [
            {
                key: item[key]
                for key in (
                    "id",
                    "identity",
                    "kind",
                    "sha256",
                    "urls",
                    "used_by_repositories",
                )
            }
            for item in manifest["archives"]
        ],
        "go_modules": [
            {
                key: item[key]
                for key in (
                    "h1",
                    "h1_source",
                    "id",
                    "license",
                    "module",
                    "repository",
                    "sha256",
                    "urls",
                    "version",
                )
            }
            for item in manifest["go_modules"]
        ],
        "repositories": manifest["repositories"],
    }
    encoded = json.dumps(projection, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def selected_cache_hashes(
    cache: Path, locked_hashes: set[str], bcr_by_hash: dict[str, list[Path]]
) -> tuple[set[str], set[str]]:
    """Classify the target cache without retaining unrelated metadata."""
    archive_hashes = set()
    patch_hashes = set()
    for directory in cache.iterdir():
        source = directory / "file"
        if not source.is_file() or directory.name in locked_hashes:
            continue
        if zipfile.is_zipfile(source) or tarfile.is_tarfile(source):
            archive_hashes.add(directory.name)
        if any("/patches/" in path.as_posix() for path in bcr_by_hash.get(directory.name, [])):
            patch_hashes.add(directory.name)
    return archive_hashes, patch_hashes


MANUAL_ARCHIVES = {
    "a729c8ed2447c90fe140077689079ca0acfb7580ec41637f312d650ce9d93d96": {
        "identity": "rules_go-override@0.57.0",
        "kind": "root-archive-override",
        "module": "rules_go",
        "version": "0.57.0",
        "urls": ["https://github.com/bazel-contrib/rules_go/releases/download/v0.57.0/rules_go-v0.57.0.zip"],
    },
    "31d6c01c3bfa0a3584532665715e487703eb10d76bb30b4875e57d139c13bbf9": {
        "identity": "grpc-override@1.75.0",
        "kind": "root-archive-override",
        "module": "grpc",
        "version": "1.75.0",
        "urls": ["https://github.com/grpc/grpc/archive/refs/tags/v1.75.0.tar.gz"],
    },
    "f86d488ca353c5ee99187579fe408adb73e9f2bb1d69c6e3a42ffb904ce3ba01": {
        "identity": "google-coral-crosstool@8e885509123395299bed6a5f9529fdc1b9751599",
        "kind": "root-module-extension",
        "urls": ["https://github.com/google-coral/crosstool/archive/8e885509123395299bed6a5f9529fdc1b9751599.tar.gz"],
    },
    "2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556": {
        "identity": "go-sdk@1.26.3-linux-amd64",
        "kind": "prebuilt-tool-bootstrap",
        "version": "1.26.3",
        "urls": ["https://dl.google.com/go/go1.26.3.linux-amd64.tar.gz"],
    },
}


def generate(args: argparse.Namespace) -> dict[str, Any]:
    clean_source = args.source.resolve()
    work = args.workspace.resolve()
    bcr = args.bcr.resolve()
    native = work / "native"
    aarch64 = work / "aarch64"
    cache = native / "repository-cache/content_addressable/sha256"

    if sha256_file(work / "tools/bazel-8.3.1-linux-x86_64") != EXPECTED_BAZEL_HASH:
        raise ManifestError("Bazel bootstrap hash changed")
    if sha256_file(work / "rules_go_offline_sdks.patch") != EXPECTED_SDK_PATCH_HASH:
        raise ManifestError("offline SDK-index patch hash changed")
    for architecture in (native, aarch64):
        if sha256_file(architecture / "MODULE.bazel.lock") != EXPECTED_LOCK_HASH:
            raise ManifestError(f"resolved lock changed: {architecture}")
        if sha256_file(architecture / "source/MODULE.bazel") != EXPECTED_SOURCE_MODULE_HASH:
            raise ManifestError(f"prepared MODULE.bazel changed: {architecture}")
    if (native / "MODULE.bazel.lock").read_bytes() != (aarch64 / "MODULE.bazel.lock").read_bytes():
        raise ManifestError("native and AArch64 resolved different lock files")

    lock = read_json(native / "MODULE.bazel.lock")
    registry_records = []
    for url, digest in sorted(lock["registryFileHashes"].items()):
        prefix = "https://bcr.bazel.build/"
        if not url.startswith(prefix):
            raise ManifestError(f"unexpected registry URL: {url}")
        relative = url.removeprefix(prefix)
        path = bcr / relative
        if not path.is_file() or sha256_file(path) != digest:
            raise ManifestError(f"BCR snapshot mismatch: {relative}")
        record = {
            "path": relative,
            "sha256": digest,
            "size": path.stat().st_size,
            "url": url,
        }
        cache_ids = repository_cache_ids(cache, digest)
        if cache_ids:
            record["repository_cache_ids"] = cache_ids
        registry_records.append(record)
    if len(registry_records) != EXPECTED_COUNTS["registry_files"]:
        raise ManifestError(f"expected 319 registry files, got {len(registry_records)}")

    locked_hashes = {item["sha256"] for item in registry_records}
    bcr_by_hash = find_bcr_files_by_hash(bcr)
    archive_hashes, patch_hashes = selected_cache_hashes(cache, locked_hashes, bcr_by_hash)
    other_cache = aarch64 / "repository-cache/content_addressable/sha256"
    other_archives, other_patches = selected_cache_hashes(
        other_cache, locked_hashes, bcr_by_hash
    )
    if archive_hashes != other_archives or patch_hashes != other_patches:
        raise ManifestError("native and AArch64 selected different fixed cache inputs")
    for digest in archive_hashes | patch_hashes:
        if repository_cache_ids(cache, digest) != repository_cache_ids(other_cache, digest):
            raise ManifestError(f"native and AArch64 canonical cache IDs differ: {digest}")
    patch_records = []
    for digest in sorted(patch_hashes):
        candidates = [path for path in bcr_by_hash[digest] if "/patches/" in path.as_posix()]
        candidates = [
            path
            for path in candidates
            if "protoc-gen-validate/1.3.3/" not in path.as_posix()
        ]
        if len(candidates) != 1:
            raise ManifestError(f"ambiguous BCR patch {digest}: {candidates}")
        path = candidates[0]
        relative = str(path.relative_to(bcr))
        record = {
            "path": relative,
            "sha256": digest,
            "size": path.stat().st_size,
            "url": f"https://bcr.bazel.build/{relative}",
        }
        cache_ids = repository_cache_ids(cache, digest)
        if cache_ids:
            record["repository_cache_ids"] = cache_ids
        patch_records.append(record)
    if len(patch_records) != EXPECTED_COUNTS["bcr_patches"]:
        raise ManifestError(f"expected 15 BCR patches, got {len(patch_records)}")

    bcr_sources: dict[str, dict[str, Any]] = {}
    for path in bcr.glob("modules/*/*/source.json"):
        value = read_json(path)
        declared_digest = value.get("integrity") or value.get("sha256", "")
        if not (declared_digest.startswith("sha256-") or re.fullmatch(r"[0-9a-f]{64}", declared_digest)):
            continue
        record = source_record(path)
        bcr_sources[record["sha256"]] = record
    archives = []
    for digest in sorted(archive_hashes):
        source_path = cache / digest / "file"
        if not source_path.is_file() or sha256_file(source_path) != digest:
            raise ManifestError(f"missing archive cache input: {digest}")
        record = dict(MANUAL_ARCHIVES.get(digest) or bcr_sources.get(digest) or {})
        if not record:
            raise ManifestError(f"archive has no source provenance: {digest}")
        filename = Path(urlparse(record["urls"][0]).path).name
        record.update(
            {
                "file_name": f"{digest[:16]}-{filename}",
                "guix_base32": nix_base32(digest),
                "id": "archive-" + safe_id(record["identity"]),
                "sha256": digest,
                "size": source_path.stat().st_size,
                "used_by_repositories": [],
            }
        )
        cache_ids = repository_cache_ids(cache, digest)
        if record["identity"] == "go-sdk@1.26.3-linux-amd64":
            if cache_ids:
                raise ManifestError("rules_go Go SDK unexpectedly has a canonical-ID marker")
            record["repository_cache_id_basis"] = (
                "none: rules_go repository_ctx.download_and_extract uses checksum-only caching"
            )
        else:
            expected_cache_id = default_http_canonical_id(record["urls"])
            if cache_ids != [expected_cache_id]:
                raise ManifestError(
                    f"canonical-ID marker does not match archive URLs: {record['identity']}"
                )
            record["repository_cache_id_basis"] = "sha256(space-joined URLs)"
        if cache_ids:
            record["repository_cache_ids"] = cache_ids
        archives.append(record)
    if len(archives) != EXPECTED_COUNTS["archives"]:
        raise ManifestError(f"expected 25 archives, got {len(archives)}")
    archive_by_module = {
        item["module"]: item for item in archives if item.get("module")
    }
    archive_by_identity = {item["identity"]: item for item in archives}

    proxy = native / "vendor/gazelle++non_module_deps+bazel_gazelle_go_repository_cache/pkg/mod/cache/download"
    go_sums: dict[tuple[str, str], tuple[str, str]] = {}
    for source_name, path in [
        ("gvisor/go.sum", clean_source / "go.sum"),
        ("rules_go/go.sum", native / "vendor/rules_go+/go.sum"),
    ]:
        for number, line in enumerate(path.read_text().splitlines(), 1):
            fields = line.split()
            if len(fields) == 3 and not fields[1].endswith("/go.mod"):
                go_sums[(fields[0], fields[1])] = (fields[2], f"{source_name}:{number}")
    go_modules = []
    go_by_repository: dict[str, dict[str, Any]] = {}
    for zip_path in sorted(proxy.rglob("*.zip")):
        relative = zip_path.relative_to(proxy)
        at_v = relative.parts.index("@v")
        module_path = go_unescape("/".join(relative.parts[:at_v]))
        version = go_unescape(zip_path.stem)
        mod_path = zip_path.with_suffix(".mod")
        info_path = zip_path.with_suffix(".info")
        hash_path = zip_path.with_suffix(".ziphash")
        for path in (mod_path, info_path, hash_path):
            if not path.is_file():
                raise ManifestError(f"incomplete Go proxy entry: {path}")
        repository = None
        purl = f"pkg:golang/{module_path}@{version}"
        for directory in native.joinpath("vendor").glob("gazelle++go_deps+*"):
            build = directory / "BUILD.bazel"
            if build.is_file() and f'purl = "{purl}"' in build.read_text(errors="ignore"):
                repository = directory.name
                break
        if repository is None:
            raise ManifestError(f"Go module has no canonical repository: {purl}")
        digest = sha256_file(zip_path)
        sum_record = go_sums.get((module_path, version))
        h1 = hash_path.read_text().strip()
        record = {
            "file_name": f"{digest[:16]}-{zip_path.name}",
            "guix_base32": nix_base32(digest),
            "h1": h1,
            "h1_source": sum_record[1] if sum_record and sum_record[0] == h1 else None,
            "id": "go-module-" + safe_id(repository.removeprefix("gazelle++go_deps+")),
            "info_base64": base64.b64encode(info_path.read_bytes()).decode("ascii"),
            "info_sha256": sha256_file(info_path),
            "license": license_evidence(native / "vendor" / repository),
            "mod_base64": base64.b64encode(mod_path.read_bytes()).decode("ascii"),
            "mod_sha256": sha256_file(mod_path),
            "module": module_path,
            "proxy_path": str(relative.with_suffix("")),
            "repository": repository,
            "sha256": digest,
            "size": zip_path.stat().st_size,
            "urls": [f"https://proxy.golang.org/{relative.as_posix()}"],
            "version": version,
        }
        go_modules.append(record)
        go_by_repository[repository] = record
    if len(go_modules) != EXPECTED_COUNTS["go_modules"]:
        raise ManifestError(f"expected 91 Go modules, got {len(go_modules)}")
    other_proxy = aarch64 / "vendor/gazelle++non_module_deps+bazel_gazelle_go_repository_cache/pkg/mod/cache/download"
    proxy_files = {
        str(path.relative_to(proxy)): sha256_file(path)
        for path in proxy.rglob("*")
        if path.is_file() and path.suffix in (".zip", ".mod", ".info")
    }
    other_proxy_files = {
        str(path.relative_to(other_proxy)): sha256_file(path)
        for path in other_proxy.rglob("*")
        if path.is_file() and path.suffix in (".zip", ".mod", ".info")
    }
    if proxy_files != other_proxy_files:
        raise ManifestError("native and AArch64 selected different Go proxy inputs")

    vendor_members = (native / "vendor-members.txt").read_text().splitlines()
    if len(vendor_members) != EXPECTED_COUNTS["vendor_members"]:
        raise ManifestError(f"expected 261 stable vendor members, got {len(vendor_members)}")
    if vendor_members != (aarch64 / "vendor-members.txt").read_text().splitlines():
        raise ManifestError("native and AArch64 vendor member sets differ")
    markers = sorted(name[1:-7] for name in vendor_members if name.startswith("@") and name.endswith(".marker"))
    if len(markers) != EXPECTED_COUNTS["repositories"]:
        raise ManifestError(f"expected 129 canonical repositories, got {len(markers)}")

    repositories = []
    for canonical in markers:
        directory = native / "vendor" / canonical
        if not directory.is_dir():
            raise ManifestError(f"vendored repository has no directory: {canonical}")
        license_record = license_evidence(directory)
        provenance: dict[str, Any]
        if canonical in go_by_repository:
            item = go_by_repository[canonical]
            provenance = {"input": item["id"], "kind": "go-module", "urls": item["urls"]}
        elif canonical == "+coral_crosstool_extension+coral_crosstool":
            item = archive_by_identity["google-coral-crosstool@8e885509123395299bed6a5f9529fdc1b9751599"]
            provenance = {"input": item["id"], "kind": item["kind"], "urls": item["urls"]}
            item["used_by_repositories"].append(canonical)
        elif canonical == "rules_go++go_sdk+main___download_0":
            item = archive_by_identity["go-sdk@1.26.3-linux-amd64"]
            provenance = {"input": item["id"], "kind": item["kind"], "urls": item["urls"]}
            item["used_by_repositories"].append(canonical)
        else:
            name = module_name(directory)
            if name is None and canonical.endswith("+") and "++" not in canonical:
                name = canonical[:-1]
            item = archive_by_module.get(name or "")
            if item:
                provenance = {"input": item["id"], "kind": item["kind"], "urls": item["urls"]}
                item["used_by_repositories"].append(canonical)
            elif "++" in canonical:
                generator = canonical.split("++", 1)[0] + "+"
                provenance = {
                    "generated_by": generator,
                    "kind": "generated-repository",
                    "omission": "no independent downloaded source",
                }
                license_record = {
                    "evidence": [],
                    "inherits_from": generator,
                    "spdx": [],
                    "status": "generated-no-independent-license",
                }
            else:
                raise ManifestError(f"cannot attribute repository provenance: {canonical}")
        repositories.append(
            {
                "canonical_name": canonical,
                "license": license_record,
                "provenance": provenance,
                "reachability": "vendored by bazel vendor //:release",
            }
        )
    unused_archives = [item["identity"] for item in archives if not item["used_by_repositories"]]
    if unused_archives:
        raise ManifestError(f"fixed archives are outside //:release: {unused_archives}")

    closures = {}
    for name, directory, config, expected in (
        ("native-x86_64", native, "x86_64", EXPECTED_COUNTS["native_labels"]),
        ("aarch64", aarch64, "aarch64", EXPECTED_COUNTS["aarch64_labels"]),
    ):
        cquery = directory / "cquery.txt"
        lines = cquery.read_text().splitlines()
        if len(lines) != expected:
            raise ManifestError(f"{name} closure has {len(lines)} labels, expected {expected}")
        referenced = sorted(
            {
                match.group(1)
                for line in lines
                if (match := re.match(r"@(@?[^/]+)//", line))
            }
        )
        closures[name] = {
            "bazel_config": config,
            "build_settings": {
                "@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc": False,
            },
            "canonical_repositories": markers,
            "configured_label_count": len(lines),
            "configured_labels_file": f"release-closure-{name}.txt",
            "configured_labels_sha256": sha256_file(cquery),
            "referenced_repository_spellings": referenced,
            "vendor_member_count": len(vendor_members),
            "vendor_members": vendor_members,
            "vendor_members_sha256": sha256_file(directory / "vendor-members.txt"),
        }

    missing_h1 = [f"{item['module']}@{item['version']}" for item in go_modules if item["h1_source"] is None]
    manifest = {
        "schema": SCHEMA,
        "source": {
            "commit": EXPECTED_COMMIT,
            "default_source_clean": True,
            "guix_recursive_sha256": "12hyhw15k4z8xy01ybq26bcbq41rmybzg91iz84hm5ng35x5vpiy",
            "release": EXPECTED_RELEASE,
        },
        "bootstrap": {
            "bazel": {
                "embedded_java": "24",
                "file_name": "bazel-8.3.1-linux-x86_64",
                "guix_base32": nix_base32(EXPECTED_BAZEL_HASH),
                "id": "bazel-bootstrap-8.3.1-linux-x86_64",
                "prebuilt": True,
                "sha256": EXPECTED_BAZEL_HASH,
                "size": (work / "tools/bazel-8.3.1-linux-x86_64").stat().st_size,
                "urls": ["https://github.com/bazelbuild/bazel/releases/download/8.3.1/bazel-8.3.1-linux-x86_64"],
                "version": "8.3.1",
            },
            "go_sdk_selected": "archive-go-sdk-1-26-3-linux-amd64",
            "label": "prebuilt-tool-bootstrap",
        },
        "bcr_snapshot": {
            "commit": EXPECTED_BCR_COMMIT,
            "discovery_archive_sha256": "c92bc8507886ad000356f719cf1b00cd89fe1e571b692a1ec35b895a2387daff",
            "discovery_archive_url": f"https://github.com/bazelbuild/bazel-central-registry/archive/{EXPECTED_BCR_COMMIT}.tar.gz",
            "guix_recursive_sha256": EXPECTED_BCR_NAR_HASH,
            "recursive_sha256_hex": EXPECTED_BCR_NAR_HASH_HEX,
            "repository": "https://github.com/bazelbuild/bazel-central-registry.git",
        },
        "packaging_transform": {
            "go_release_index_snapshot": {
                "sha256": "1ed915f72633d0a72eaa2f462740153db4fe347cb56f7d1e25ec44868568f13e",
                "urls": [
                    "https://go.dev/dl/?mode=json&include=all",
                    "https://golang.google.cn/dl/?mode=json&include=all",
                ],
            },
            "go_sdk_index": [
                {
                    "selected_archive": version == "1.26.3",
                    "sha256": digest,
                    "url": f"https://dl.google.com/go/go{version}.linux-amd64.tar.gz",
                    "version": version,
                }
                for version, digest in GO_SDK_INDEX
            ],
            "prepared_module_sha256": EXPECTED_SOURCE_MODULE_HASH,
            "rules_go_patch": "rules_go_offline_sdk_index.patch",
            "rules_go_patch_sha256": EXPECTED_SDK_PATCH_HASH,
            "scope": "replace mutable Go release-index query with selected-graph static hashes",
        },
        "lock": {
            "file": "release-MODULE.bazel.lock",
            "lock_file_version": lock["lockFileVersion"],
            "sha256": EXPECTED_LOCK_HASH,
        },
        "closures": closures,
        "registry_files": registry_records,
        "bcr_patches": patch_records,
        "archives": sorted(archives, key=lambda item: item["id"]),
        "go_modules": sorted(go_modules, key=lambda item: item["id"]),
        "repositories": repositories,
        "excluded_declared_downloads": [
            {
                "id": "http_file:google_root_pem",
                "reason": "absent from both //:release vendor closures; upstream declaration is unhashed",
                "url": "https://pki.goog/roots.pem",
            },
            {"id": "http_archive:llvm-raw", "reason": "absent from both //:release vendor closures"},
            {"id": "http_archive:kythe_release", "reason": "absent from both //:release vendor closures"},
            {
                "id": "protobuf++protoc+prebuilt_protoc.linux_x86_64",
                "reason": "explicitly disabled; protoc is built from the fixed protobuf source archive",
            },
        ],
        "provenance_omissions": {
            "go_h1_not_in_selected_source_sums": missing_h1,
            "license": [
                "rules_kotlin@1.9.6 source archive contains no license file",
                "generated repositories contain no independent source or license",
            ],
            "release_tag": "upstream release tag is unsigned; trust is commit plus content hash",
        },
        "proof": {
            "canonical_id_mapping_sha256": EXPECTED_CACHE_ID_MAPPING_HASH,
            "negative_missing_input": "rules_go++go_sdk+main___download_0 removed; fresh analysis failed with downloads disabled",
            "networkless_replay": "empty output/vendor state regenerated from 359 Bazel CAS inputs and 91 local Go proxy modules",
            "repository_relationships_sha256": EXPECTED_RELATIONSHIPS_HASH,
            "runtime_compilation_actions": 0,
        },
        "packaging": {
            "fixed_input_graph_closed": True,
            "networkless_analysis_proven": True,
            "runtime_package_defined": False,
        },
    }
    validate_manifest(manifest)
    return manifest


def validate_sha(value: Any, context: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ManifestError(f"invalid SHA-256 for {context}: {value!r}")


def validate_url(value: Any, context: str) -> None:
    if not isinstance(value, str) or not value.startswith("https://"):
        raise ManifestError(f"non-HTTPS or invalid URL for {context}: {value!r}")


def validate_license_record(
    record: Any, repository: str, inherited_from: str | None = None
) -> None:
    if not isinstance(record, dict):
        raise ManifestError(f"invalid license record for {repository}")
    status = record.get("status")
    if inherited_from is not None:
        if record != {
            "evidence": [],
            "inherits_from": inherited_from,
            "spdx": [],
            "status": "generated-no-independent-license",
        }:
            raise ManifestError(f"generated license relationship changed: {repository}")
        return
    if repository in EXPECTED_UNKNOWN_LICENSE_REPOSITORIES:
        if record != {
            "evidence": [],
            "spdx": [],
            "status": "missing",
        }:
            raise ManifestError(f"documented unknown license was replaced: {repository}")
        return
    if status == "missing":
        raise ManifestError(f"unexpected unknown license: {repository}")
    if status != "recorded" or set(record) != {"evidence", "spdx", "status"}:
        raise ManifestError(f"invalid direct license status for {repository}: {status}")
    evidence = record.get("evidence")
    expressions = record.get("spdx")
    if (
        not isinstance(evidence, list)
        or not evidence
        or not isinstance(expressions, list)
        or not expressions
        or not all(isinstance(item, str) and item in LICENSE_EXPRESSIONS for item in expressions)
        or expressions != sorted(set(expressions))
    ):
        raise ManifestError(f"incomplete license evidence for {repository}")
    paths = []
    for item in evidence:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "size", "spdx"}:
            raise ManifestError(f"invalid license evidence shape for {repository}")
        if not isinstance(item["path"], str):
            raise ManifestError(f"invalid license evidence path for {repository}")
        path = Path(item["path"])
        if path.is_absolute() or not path.parts or ".." in path.parts:
            raise ManifestError(f"unsafe license evidence path for {repository}: {path}")
        validate_sha(item["sha256"], f"license:{repository}:{path}")
        if not isinstance(item["size"], int) or item["size"] <= 0:
            raise ManifestError(f"invalid license evidence size for {repository}: {path}")
        if not isinstance(item["spdx"], str) or item["spdx"] not in expressions:
            raise ManifestError(f"license evidence expression is not declared for {repository}: {path}")
        paths.append(str(path))
    if len(paths) != len(set(paths)):
        raise ManifestError(f"duplicate license evidence path for {repository}")


def validate_repository_relationships(manifest: dict[str, Any]) -> None:
    archives = {item["id"]: item for item in manifest["archives"]}
    go_modules = {item["id"]: item for item in manifest["go_modules"]}
    fixed_inputs = {**archives, **go_modules}
    repositories = {item["canonical_name"]: item for item in manifest["repositories"]}
    archive_backlinks: dict[str, list[str]] = {item: [] for item in archives}
    go_backlinks: dict[str, list[str]] = {item: [] for item in go_modules}

    for name, repository in repositories.items():
        provenance = repository.get("provenance")
        if not isinstance(provenance, dict):
            raise ManifestError(f"invalid repository provenance: {name}")
        if "input" in provenance:
            if set(provenance) != {"input", "kind", "urls"}:
                raise ManifestError(f"invalid fixed-input provenance shape: {name}")
            input_id = provenance["input"]
            if not isinstance(input_id, str):
                raise ManifestError(f"invalid fixed-input provenance ID: {name}")
            source = fixed_inputs.get(input_id)
            if source is None:
                raise ManifestError(f"repository provenance names nonexistent input: {name}")
            expected_kind = "go-module" if input_id in go_modules else source["kind"]
            if provenance["kind"] != expected_kind or provenance["urls"] != source["urls"]:
                raise ManifestError(f"repository provenance does not match fixed input: {name}")
            if input_id in archives:
                archive_backlinks[input_id].append(name)
            else:
                go_backlinks[input_id].append(name)
                if source["repository"] != name or repository["license"] != source["license"]:
                    raise ManifestError(f"Go repository source/license relationship changed: {name}")
            validate_license_record(repository.get("license"), name)
        elif "generated_by" in provenance:
            if set(provenance) != {"generated_by", "kind", "omission"}:
                raise ManifestError(f"invalid generated provenance shape: {name}")
            generator = provenance["generated_by"]
            if not isinstance(generator, str):
                raise ManifestError(f"invalid generated repository alias: {name}")
            expected_generator = name.split("++", 1)[0] + "+"
            if (
                provenance["kind"] != "generated-repository"
                or provenance["omission"] != "no independent downloaded source"
                or generator != expected_generator
                or generator == name
                or generator not in repositories
                or "input" not in repositories[generator].get("provenance", {})
            ):
                raise ManifestError(f"generated repository alias is invalid: {name}")
            validate_license_record(repository.get("license"), name, generator)
        else:
            raise ManifestError(f"repository has no source relationship: {name}")

    for input_id, source in archives.items():
        expected = sorted(archive_backlinks[input_id])
        actual = source.get("used_by_repositories")
        if (
            len(expected) != 1
            or not isinstance(actual, list)
            or not all(isinstance(item, str) for item in actual)
            or actual != expected
            or len(actual) != len(set(actual))
        ):
            raise ManifestError(f"archive repository backlinks changed: {input_id}")
    for input_id, source in go_modules.items():
        expected = go_backlinks[input_id]
        if expected != [source["repository"]]:
            raise ManifestError(f"Go repository backlink changed: {input_id}")

    if relationship_hash(manifest) != EXPECTED_RELATIONSHIPS_HASH:
        raise ManifestError("repository provenance/license relationship seal changed")


def validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema") != SCHEMA:
        raise ManifestError(f"unsupported manifest schema: {manifest.get('schema')}")
    if manifest.get("source", {}).get("commit") != EXPECTED_COMMIT:
        raise ManifestError("manifest source commit changed")
    if manifest.get("source", {}).get("release") != EXPECTED_RELEASE:
        raise ManifestError("manifest source release changed")
    if manifest.get("bcr_snapshot", {}).get("commit") != EXPECTED_BCR_COMMIT:
        raise ManifestError("manifest BCR commit changed")
    if manifest.get("bcr_snapshot", {}).get("guix_recursive_sha256") != EXPECTED_BCR_NAR_HASH:
        raise ManifestError("manifest BCR recursive hash changed")
    if manifest.get("lock", {}).get("sha256") != EXPECTED_LOCK_HASH:
        raise ManifestError("manifest lock hash changed")
    transform = manifest.get("packaging_transform", {})
    if transform.get("rules_go_patch_sha256") != EXPECTED_SDK_PATCH_HASH:
        raise ManifestError("manifest SDK-index patch hash changed")
    if transform.get("prepared_module_sha256") != EXPECTED_SOURCE_MODULE_HASH:
        raise ManifestError("manifest prepared MODULE.bazel hash changed")
    expected_sdk_index = [
        {
            "selected_archive": version == "1.26.3",
            "sha256": digest,
            "url": f"https://dl.google.com/go/go{version}.linux-amd64.tar.gz",
            "version": version,
        }
        for version, digest in GO_SDK_INDEX
    ]
    if transform.get("go_sdk_index") != expected_sdk_index:
        raise ManifestError("manifest static Go SDK index changed")
    index_snapshot = transform.get("go_release_index_snapshot", {})
    if index_snapshot.get("sha256") != "1ed915f72633d0a72eaa2f462740153db4fe347cb56f7d1e25ec44868568f13e":
        raise ManifestError("Go release-index snapshot hash changed")
    expected_index_urls = [
        "https://go.dev/dl/?mode=json&include=all",
        "https://golang.google.cn/dl/?mode=json&include=all",
    ]
    if index_snapshot.get("urls") != expected_index_urls:
        raise ManifestError("Go release-index snapshot URLs changed")
    for url in index_snapshot["urls"]:
        validate_url(url, "Go release-index snapshot")
    ids = []
    for group in ("archives", "go_modules"):
        values = manifest.get(group)
        if not isinstance(values, list) or len(values) != EXPECTED_COUNTS[group]:
            raise ManifestError(f"unexpected {group} count")
        for item in values:
            ids.append(item["id"])
            validate_sha(item.get("sha256"), item["id"])
            if item.get("guix_base32") != nix_base32(item["sha256"]):
                raise ManifestError(f"Guix hash mismatch for {item['id']}")
            urls = item.get("urls")
            if not isinstance(urls, list) or not urls:
                raise ManifestError(f"invalid URL list for {item['id']}")
            for url in urls:
                validate_url(url, item["id"])
            for cache_id in item.get("repository_cache_ids", []):
                validate_sha(cache_id, item["id"] + ":repository-cache-id")
    bazel = manifest.get("bootstrap", {}).get("bazel", {})
    ids.append(bazel.get("id"))
    validate_sha(bazel.get("sha256"), "Bazel bootstrap")
    if bazel.get("sha256") != EXPECTED_BAZEL_HASH or bazel.get("version") != "8.3.1":
        raise ManifestError("Bazel bootstrap identity changed")
    if len(ids) != len(set(ids)):
        raise ManifestError("fixed input ids are not unique")
    for group in ("registry_files", "bcr_patches"):
        values = manifest.get(group)
        expected = EXPECTED_COUNTS[group]
        if not isinstance(values, list) or len(values) != expected:
            raise ManifestError(f"unexpected {group} count")
        for item in values:
            validate_sha(item.get("sha256"), f"{group}:{item.get('path')}")
            validate_url(item.get("url"), f"{group}:{item.get('path')}")
            for cache_id in item.get("repository_cache_ids", []):
                validate_sha(cache_id, f"{group}:{item.get('path')}:repository-cache-id")
            path = Path(item.get("path", ""))
            if path.is_absolute() or ".." in path.parts:
                raise ManifestError(f"unsafe registry path: {path}")
    cache_id_count = sum(
        len(item.get("repository_cache_ids", []))
        for item in manifest["registry_files"]
        + manifest["bcr_patches"]
        + manifest["archives"]
    )
    if cache_id_count != EXPECTED_COUNTS["repository_cache_ids"]:
        raise ManifestError(f"unexpected repository cache canonical-ID count: {cache_id_count}")
    for item in manifest["registry_files"] + manifest["bcr_patches"]:
        if item.get("repository_cache_ids"):
            raise ManifestError(f"unexpected non-archive canonical-ID marker: {item['path']}")
    for item in manifest["archives"]:
        cache_ids = item.get("repository_cache_ids", [])
        if item["id"] == "archive-go-sdk-1-26-3-linux-amd64":
            expected_ids = []
            expected_basis = (
                "none: rules_go repository_ctx.download_and_extract uses checksum-only caching"
            )
        else:
            expected_ids = [default_http_canonical_id(item["urls"])]
            expected_basis = "sha256(space-joined URLs)"
        if cache_ids != expected_ids or item.get("repository_cache_id_basis") != expected_basis:
            raise ManifestError(f"archive canonical-ID relationship changed: {item['id']}")
    if cache_id_mapping_hash(manifest["archives"]) != EXPECTED_CACHE_ID_MAPPING_HASH:
        raise ManifestError("canonical-ID mapping seal changed")
    repositories = manifest.get("repositories")
    if not isinstance(repositories, list) or len(repositories) != EXPECTED_COUNTS["repositories"]:
        raise ManifestError("unexpected repository count")
    names = [item.get("canonical_name") for item in repositories]
    if names != sorted(names) or len(names) != len(set(names)):
        raise ManifestError("canonical repositories are not unique and sorted")
    if any("prebuilt_protoc" in name for name in names):
        raise ManifestError("prebuilt protoc is reachable from the source-build closure")
    if any(item.get("reachability") != "vendored by bazel vendor //:release" for item in repositories):
        raise ManifestError("repository reachability classification changed")
    validate_repository_relationships(manifest)
    for architecture, count in (("native-x86_64", 18812), ("aarch64", 18791)):
        closure = manifest.get("closures", {}).get(architecture, {})
        if closure.get("configured_label_count") != count:
            raise ManifestError(f"unexpected {architecture} label count")
        if closure.get("configured_labels_sha256") != EXPECTED_CLOSURE_HASHES[architecture]:
            raise ManifestError(f"unexpected {architecture} closure hash")
        if closure.get("canonical_repositories") != names:
            raise ManifestError(f"{architecture} repository closure differs from manifest")
        if closure.get("build_settings") != {
            "@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc": False,
        }:
            raise ManifestError(f"{architecture} source-protoc setting changed")
        members = closure.get("vendor_members", [])
        if closure.get("vendor_member_count") != EXPECTED_COUNTS["vendor_members"]:
            raise ManifestError(f"unexpected {architecture} vendor member count")
        if len(members) != EXPECTED_COUNTS["vendor_members"] or members != sorted(members):
            raise ManifestError(f"invalid {architecture} vendor member inventory")
        if "bazel-external" not in members or "_registries" not in members:
            raise ManifestError(f"{architecture} path-sensitive vendor members are not explicit")
        if closure.get("vendor_members_sha256") != EXPECTED_VENDOR_MEMBERS_HASH:
            raise ManifestError(f"unexpected {architecture} vendor-member hash")
    packaging = manifest.get("packaging", {})
    if packaging != {
        "fixed_input_graph_closed": True,
        "networkless_analysis_proven": True,
        "runtime_package_defined": False,
    }:
        raise ManifestError("packaging readiness statement changed")
    proof = manifest.get("proof", {})
    if proof.get("canonical_id_mapping_sha256") != EXPECTED_CACHE_ID_MAPPING_HASH:
        raise ManifestError("manifest canonical-ID mapping proof changed")
    if proof.get("repository_relationships_sha256") != EXPECTED_RELATIONSHIPS_HASH:
        raise ManifestError("manifest repository relationship proof changed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("--source", type=Path, required=True)
    generate_parser.add_argument("--workspace", type=Path, required=True)
    generate_parser.add_argument("--bcr", type=Path, required=True)
    generate_parser.add_argument("--output", type=Path, required=True)
    check_parser = subparsers.add_parser("check")
    check_parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "generate":
            manifest = generate(args)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        else:
            validate_manifest(read_json(args.manifest))
    except (ManifestError, OSError, ValueError) as error:
        print(f"vendor manifest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
