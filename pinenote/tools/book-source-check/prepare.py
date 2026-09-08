#!/usr/bin/env python3
"""Assemble finite, authenticated Book Computer source views.

The source map is part of the versioned publication boundary.  Expected
hashes are never accepted from argv or the environment.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import sys


MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_SOURCE_FILES = 1024
MAX_SOURCE_BYTES = 16 * 1024 * 1024
CONTROL_PATHS = (
    "pinenote/tools/book-source-check/SOURCE-MAP.tsv",
    "pinenote/tools/book-source-check/SOURCE-ROSTER.txt",
)
VIEW_PREFIXES = {
    "repo": "repo",
    "package": "package-view",
    "backend-v2": "views/backend-v2",
    "native-v2": "closure/native-v2",
    "observer-v1": "closure/observer-v1",
    "join-v2": "closure/join",
    "ui": "closure/ui",
}


class SourceError(Exception):
    pass


@dataclass(frozen=True)
class MapRow:
    view: str
    source: str
    destination: str
    sha256: str

    @property
    def prepared_path(self) -> str:
        return f"{VIEW_PREFIXES[self.view]}/{self.destination}"


def _relative_path(value: str, label: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or value != path.as_posix():
        raise SourceError(f"{label} is not a canonical relative path: {value!r}")
    if any(part in ("", ".", "..") for part in path.parts):
        raise SourceError(f"{label} escapes its root: {value!r}")
    return value


def parse_map(path: Path) -> list[MapRow]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise SourceError(f"cannot read source map: {error}") from error
    if not lines or lines[0] != "view\tsource_path\tdestination_path\tsha256":
        raise SourceError("source map has the wrong header")

    rows: list[MapRow] = []
    destinations: set[str] = set()
    source_hashes: dict[str, str] = {}
    for number, line in enumerate(lines[1:], 2):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise SourceError(f"source map line {number} does not have four fields")
        view, source, destination, digest = fields
        if view not in VIEW_PREFIXES:
            raise SourceError(f"source map line {number} has unknown view {view!r}")
        source = _relative_path(source, f"source map line {number} source")
        destination = _relative_path(
            destination, f"source map line {number} destination"
        )
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise SourceError(f"source map line {number} has an invalid SHA-256")
        prepared = f"{VIEW_PREFIXES[view]}/{destination}"
        if prepared in destinations:
            raise SourceError(f"source map has duplicate destination {prepared}")
        destinations.add(prepared)
        prior = source_hashes.setdefault(source, digest)
        if prior != digest:
            raise SourceError(f"source map gives conflicting hashes for {source}")
        rows.append(MapRow(view, source, destination, digest))
    if not rows:
        raise SourceError("source map is empty")
    return rows


def expected_source_roster(rows: list[MapRow]) -> list[str]:
    return sorted({row.source for row in rows}.union(CONTROL_PATHS))


def read_roster(path: Path) -> list[str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise SourceError(f"cannot read source roster: {error}") from error
    if not lines or any(not line or line.startswith("#") for line in lines):
        raise SourceError("source roster must contain only nonempty paths")
    checked = [_relative_path(line, "source roster path") for line in lines]
    if checked != sorted(set(checked)):
        raise SourceError("source roster is not sorted and unique")
    if len(checked) > MAX_SOURCE_FILES:
        raise SourceError(f"source roster exceeds {MAX_SOURCE_FILES} files")
    return checked


def canonical_root(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise SourceError(f"{label} must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise SourceError(f"cannot resolve {label}: {error}") from error
    if resolved != path:
        raise SourceError(f"{label} must be canonical: {path}")
    if not path.is_dir():
        raise SourceError(f"{label} is not a directory: {path}")
    return path


def empty_output(path: Path) -> Path:
    if not path.is_absolute():
        raise SourceError("output root must be absolute")
    if path.exists():
        if path.resolve(strict=True) != path or not path.is_dir():
            raise SourceError("existing output root must be a canonical directory")
        if any(path.iterdir()):
            raise SourceError(f"output root is not empty: {path}")
    else:
        path.mkdir(mode=0o700, parents=True)
        if path.resolve(strict=True) != path:
            raise SourceError("new output root must have a canonical path")
    return path


def scan_regular_tree(root: Path) -> list[str]:
    files: list[str] = []

    def visit(directory: Path) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            raise SourceError(f"cannot scan {directory}: {error}") from error
        for entry in entries:
            relative = Path(entry.path).relative_to(root).as_posix()
            if entry.is_symlink():
                raise SourceError(f"source tree contains a symlink: {relative}")
            if entry.is_dir(follow_symlinks=False):
                visit(Path(entry.path))
            elif entry.is_file(follow_symlinks=False):
                files.append(relative)
            else:
                raise SourceError(f"source tree contains a special file: {relative}")

    visit(root)
    return sorted(files)


def read_verified_file(root: Path, relative: str, expected: str | None) -> bytes:
    path = root / relative
    current = root
    for part in PurePosixPath(relative).parts[:-1]:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise SourceError(f"missing source path {relative}: {error}") from error
        if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode):
            raise SourceError(f"source path has a non-directory ancestor: {relative}")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise SourceError(f"cannot open source file {relative}: {error}") from error
    try:
        information = os.fstat(descriptor)
        if not stat.S_ISREG(information.st_mode):
            raise SourceError(f"source path is not a regular file: {relative}")
        if information.st_size > MAX_FILE_BYTES:
            raise SourceError(f"source file exceeds {MAX_FILE_BYTES} bytes: {relative}")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(MAX_FILE_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(data) > MAX_FILE_BYTES:
        raise SourceError(f"source file exceeds {MAX_FILE_BYTES} bytes: {relative}")
    actual = hashlib.sha256(data).hexdigest()
    if expected is not None and actual != expected:
        raise SourceError(
            f"source hash mismatch: {relative} (expected {expected}, got {actual})"
        )
    return data


def write_file(root: Path, relative: str, data: bytes, mode: int = 0o600) -> None:
    destination = root / relative
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with destination.open("xb") as output:
            output.write(data)
    except OSError as error:
        raise SourceError(f"cannot write prepared file {relative}: {error}") from error
    destination.chmod(mode)


def validate_control(source_root: Path) -> tuple[list[MapRow], list[str]]:
    map_path = source_root / CONTROL_PATHS[0]
    roster_path = source_root / CONTROL_PATHS[1]
    for path in (map_path, roster_path):
        try:
            mode = path.lstat().st_mode
        except OSError as error:
            raise SourceError(f"source control file is absent: {path}: {error}") from error
        if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
            raise SourceError(f"source control path is not a regular file: {path}")
    rows = parse_map(map_path)
    roster = read_roster(roster_path)
    required = expected_source_roster(rows)
    if not set(required).issubset(roster):
        missing = sorted(set(required) - set(roster))
        raise SourceError(
            f"source roster omits mapped or control files (missing={missing})"
        )
    return rows, roster


def verify_roster_sources(
    source_root: Path, rows: list[MapRow], roster: list[str]
) -> dict[str, bytes]:
    hashes = {row.source: row.sha256 for row in rows}
    data: dict[str, bytes] = {}
    total = 0
    for relative in roster:
        content = read_verified_file(source_root, relative, hashes.get(relative))
        total += len(content)
        if total > MAX_SOURCE_BYTES:
            raise SourceError(f"source roster exceeds {MAX_SOURCE_BYTES} bytes")
        data[relative] = content
    return data


def export_candidate(source_root: Path, output_root: Path) -> None:
    rows, roster = validate_control(source_root)
    data = verify_roster_sources(source_root, rows, roster)
    output_root = empty_output(output_root)
    for relative in roster:
        content = data[relative]
        mode = 0o755 if relative.endswith((".sh", ".py")) else 0o644
        write_file(output_root, relative, content, mode)
    print(f"CANDIDATE_SOURCE_ROOT={output_root}")
    map_digest = hashlib.sha256((source_root / CONTROL_PATHS[0]).read_bytes())
    roster_digest = hashlib.sha256((source_root / CONTROL_PATHS[1]).read_bytes())
    print(f"SOURCE_MAP_SHA256={map_digest.hexdigest()}")
    print(f"SOURCE_ROSTER_SHA256={roster_digest.hexdigest()}")
    print(f"CANDIDATE_SOURCE_FILES={len(roster)}")
    print(f"CANDIDATE_SOURCE_BYTES={sum(len(read_verified_file(output_root, p, None)) for p in roster)}")


def prepare_tree(
    source_root: Path,
    output_root: Path,
    rows: list[MapRow],
    roster: list[str],
    *,
    exact_source_tree: bool = True,
) -> None:
    if exact_source_tree:
        actual = scan_regular_tree(source_root)
        if actual != roster:
            missing = sorted(set(roster) - set(actual))
            extra = sorted(set(actual) - set(roster))
            raise SourceError(
                "candidate source tree has missing or unlisted files "
                f"(missing={missing}, extra={extra})"
            )
    data = verify_roster_sources(source_root, rows, roster)
    output_root = empty_output(output_root)

    origins = ["view\tdestination_path\tsource_path\tsha256"]
    for row in rows:
        write_file(output_root, row.prepared_path, data[row.source])
        origins.append(
            f"{row.view}\t{row.destination}\t{row.source}\t{row.sha256}"
        )
    origins_data = ("\n".join(origins) + "\n").encode("utf-8")
    write_file(output_root, "SOURCE-ORIGINS.tsv", origins_data)

    manifest_lines: list[str] = []
    for relative in scan_regular_tree(output_root):
        content = read_verified_file(output_root, relative, None)
        manifest_lines.append(f"{hashlib.sha256(content).hexdigest()}  {relative}")
    manifest = ("\n".join(manifest_lines) + "\n").encode("utf-8")
    write_file(output_root, "PREPARED-MANIFEST.sha256", manifest)

    for directory, subdirectories, filenames in os.walk(output_root, topdown=False):
        for filename in filenames:
            (Path(directory) / filename).chmod(0o400)
        for subdirectory in subdirectories:
            (Path(directory) / subdirectory).chmod(0o500)
        Path(directory).chmod(0o500)


def prepare(source_root: Path, output_root: Path) -> None:
    rows, roster = validate_control(source_root)
    prepare_tree(source_root, output_root, rows, roster)
    manifest = (output_root / "PREPARED-MANIFEST.sha256").read_bytes()
    origins = (output_root / "SOURCE-ORIGINS.tsv").read_bytes()
    print(f"PREPARED_SOURCE_ROOT={output_root}")
    print(f"PREPARED_SOURCE_MANIFEST={output_root / 'PREPARED-MANIFEST.sha256'}")
    print(f"PREPARED_SOURCE_ORIGINS={output_root / 'SOURCE-ORIGINS.tsv'}")
    print(f"PREPARED_MANIFEST_SHA256={hashlib.sha256(manifest).hexdigest()}")
    print(f"PREPARED_ORIGINS_SHA256={hashlib.sha256(origins).hexdigest()}")
    print(f"PREPARED_VIEW_FILES={len(rows)}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("export-candidate", "prepare"):
        child = subparsers.add_parser(command)
        child.add_argument("--source-root", type=Path, required=True)
        child.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        source_root = canonical_root(arguments.source_root, "source root")
        if arguments.command == "export-candidate":
            export_candidate(source_root, arguments.output)
        elif arguments.command == "prepare":
            prepare(source_root, arguments.output)
        else:  # pragma: no cover - argparse enforces the closed list.
            raise SourceError(f"unknown command: {arguments.command}")
    except SourceError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
