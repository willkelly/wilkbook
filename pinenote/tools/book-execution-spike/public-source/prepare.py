#!/usr/bin/env python3
"""Prepare the finite public Book-execution system source view."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys


HERE = Path(__file__).resolve().parent
DEFAULT_MAP = HERE / "SOURCE-MAP.tsv"
MAP_HEADER = "path\tsha256\trole"
ROLES = {"module", "asset", "check"}
START_SYSTEMS = {
    "pinenote/systems/pinenote-book-execution-source-control.scm",
    "pinenote/systems/pinenote-book-execution-diagnostic.scm",
    "pinenote/systems/pinenote-book-execution-protocol-control.scm",
    "pinenote/systems/pinenote-book-execution-reader-interaction.scm",
}
FORBIDDEN_PUBLIC_PATHS = {
    "pinenote/packages/gvisor-local-test-artifacts.scm",
}
FORBIDDEN_MODULE_TEXT = (
    "gvisor-local-test-artifacts",
    "gvisor-v12-control-local-test-artifact",
    "gvisor-v12-diagnostic-local-test-artifact",
    "/tmp/opencode/wilkbook-gvisor-v6-source-build-v12",
)


class PreparationError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(raw: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        raise PreparationError(f"unsafe source-map path: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise PreparationError(f"unsafe source-map path: {raw!r}")
    canonical = path.as_posix()
    if canonical != raw:
        raise PreparationError(f"non-canonical source-map path: {raw!r}")
    return canonical


def load_map(path: Path = DEFAULT_MAP) -> list[tuple[str, str, str]]:
    if path.is_symlink() or not path.is_file():
        raise PreparationError(f"source map is not a regular file: {path}")
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != MAP_HEADER:
        raise PreparationError("source map has the wrong header")
    result: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != 3:
            raise PreparationError(f"source map line {number} is malformed")
        relative, expected, role = fields
        relative = safe_relative(relative)
        if relative in seen:
            raise PreparationError(f"duplicate source-map path: {relative}")
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise PreparationError(f"invalid SHA-256 for {relative}")
        if role not in ROLES:
            raise PreparationError(f"invalid role for {relative}: {role}")
        seen.add(relative)
        result.append((relative, expected, role))
    if not result:
        raise PreparationError("source map is empty")
    forbidden = seen & FORBIDDEN_PUBLIC_PATHS
    if forbidden:
        raise PreparationError(f"local-only source entered public map: {sorted(forbidden)}")
    return result


def require_regular_beneath(root: Path, relative: str) -> Path:
    current = root
    for part in PurePosixPath(relative).parts:
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError as error:
            raise PreparationError(f"mapped source is missing: {relative}") from error
        if stat.S_ISLNK(info.st_mode):
            raise PreparationError(f"mapped source traverses a symlink: {relative}")
    if not stat.S_ISREG(current.lstat().st_mode):
        raise PreparationError(f"mapped source is not a regular file: {relative}")
    return current


def local_imports(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return {
        "pinenote/" + match.replace(" ", "/") + ".scm"
        for match in re.findall(r"#:use-module\s+\(pinenote\s+([^)]+)\)", text)
    }


def expected_module_name(relative: str) -> str:
    return " ".join(PurePosixPath(relative).with_suffix("").parts)


def validate_sources(
    root: Path, entries: list[tuple[str, str, str]]
) -> dict[str, Path]:
    files: dict[str, Path] = {}
    modules = {relative for relative, _, role in entries if role == "module"}
    if not START_SYSTEMS <= modules:
        raise PreparationError(
            f"source map omits public systems: {sorted(START_SYSTEMS - modules)}"
        )
    for relative, expected, role in entries:
        source = require_regular_beneath(root, relative)
        actual = sha256(source)
        if actual != expected:
            raise PreparationError(
                f"mapped source hash mismatch: {relative}: expected {expected}, got {actual}"
            )
        if role == "module":
            text = source.read_text(encoding="utf-8")
            declaration = f"(define-module ({expected_module_name(relative)})"
            if declaration not in text:
                raise PreparationError(f"module declaration mismatch: {relative}")
            for forbidden in FORBIDDEN_MODULE_TEXT:
                if forbidden in text:
                    raise PreparationError(
                        f"public module retains local-only input {forbidden!r}: {relative}"
                    )
            missing = local_imports(source) - modules
            if missing:
                raise PreparationError(
                    f"module map misses imports from {relative}: {sorted(missing)}"
                )
        files[relative] = source
    return files


def require_empty_destination(output: Path) -> None:
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not output.is_dir():
            raise PreparationError(f"output is not a real directory: {output}")
        if next(output.iterdir(), None) is not None:
            raise PreparationError(f"output directory is not empty: {output}")
    else:
        output.mkdir(mode=0o700, parents=True)


def make_read_only(root: Path) -> None:
    for directory, names, files in os.walk(root, topdown=False, followlinks=False):
        current = Path(directory)
        for name in files:
            path = current / name
            if not path.is_symlink():
                mode = path.stat().st_mode
                path.chmod(0o555 if mode & 0o111 else 0o444)
        for name in names:
            path = current / name
            if not path.is_symlink():
                path.chmod(0o555)
        current.chmod(0o555)


def prepare(
    source_root: Path, output: Path, map_path: Path = DEFAULT_MAP
) -> tuple[Path, Path, Path]:
    source_root = source_root.resolve(strict=True)
    if not source_root.is_dir():
        raise PreparationError(f"source root is not a directory: {source_root}")
    entries = load_map(map_path)
    sources = validate_sources(source_root, entries)
    require_empty_destination(output)
    repo = output / "repo"
    module_view = output / "module-view"
    package_view = output / "package-view"
    metadata = output / "metadata"
    for directory in (repo, module_view, package_view, metadata):
        directory.mkdir(mode=0o700)

    for relative, _, role in entries:
        destination = repo / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with sources[relative].open("rb") as source, destination.open("xb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        source_mode = sources[relative].stat().st_mode
        destination.chmod(0o555 if source_mode & 0o111 else 0o444)
        if role == "module":
            link = module_view / relative
            link.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            link.symlink_to(destination)

    (package_view / "EMPTY").write_text(
        "schema=1\nrole=empty-public-book-execution-package-discovery-view\n"
        "scheme-files=0\n",
        encoding="utf-8",
    )
    shutil.copyfile(map_path, metadata / "SOURCE-MAP.tsv")
    (metadata / "PREPARED.txt").write_text(
        "schema=1\n"
        f"source-map-sha256={sha256(map_path)}\n"
        f"mapped-files={len(entries)}\n"
        f"module-files={sum(role == 'module' for _, _, role in entries)}\n"
        "local-wrapper=excluded\n"
        "generated-build-inputs=excluded\n",
        encoding="utf-8",
    )
    make_read_only(repo)
    make_read_only(module_view)
    make_read_only(package_view)
    make_read_only(metadata)
    return repo, module_view, package_view


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-map", type=Path, default=DEFAULT_MAP)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    if not arguments.source_root.is_absolute() or not arguments.output.is_absolute():
        raise PreparationError("source root and output must be absolute")
    repo, module_view, package_view = prepare(
        arguments.source_root, arguments.output, arguments.source_map
    )
    print(f"PUBLIC_SOURCE_REPO={repo}")
    print(f"PUBLIC_SOURCE_MODULE_VIEW={module_view}")
    print(f"PUBLIC_SOURCE_PACKAGE_VIEW={package_view}")
    print("PASS: finite public Book-execution source prepared read-only")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PreparationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
