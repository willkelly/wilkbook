#!/usr/bin/env python3
"""Prepare the finite, read-only Book State guest source capsule."""

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
DEFAULT_ROSTER = HERE / "CAPSULE-ROSTER.tsv"
ROSTER_HEADER = "path\tsha256\tmode\trole"
ROLES = {"module", "asset", "check"}
START_MODULE = "pinenote/systems/pinenote-book-state-reader.scm"
SOURCE_MANIFEST = "pinenote/tools/book-state-guest/SOURCE-MANIFEST.sha256"
CAPSULE_ROSTER = "pinenote/tools/book-state-guest/CAPSULE-ROSTER.tsv"
REQUIRED_CONTROLS = {
    SOURCE_MANIFEST,
    "pinenote/tools/book-state-guest/check-module-origins.scm",
    "pinenote/tools/book-state-guest/check-source-capsule.py",
    "pinenote/tools/book-state-guest/check-system.scm",
    "pinenote/tools/book-state-guest/derive-system.scm",
    "pinenote/tools/book-state-guest/pinned-guix.sh",
    "pinenote/tools/book-state-guest/prepare-source-capsule.py",
    "pinenote/tools/book-state-guest/query-derivation-outputs.scm",
    "pinenote/tools/book-state-guest/run-prepared.sh",
    "pinenote/tools/book-state-guest/run-tests.sh",
    "pinenote/tools/book-state-guest/test-cache-boundary.sh",
    "pinenote/tools/book-state-guest/test-capture-relay-fixture.scm",
    "pinenote/tools/book-state-guest/test-guest-modules.scm",
    "pinenote/tools/book-state-guest/test-source-capsule.py",
    "pinenote/tools/book-state-guest/test_source.py",
}
FORBIDDEN_PARTS = {".git", "build", "source-packets", "__pycache__"}
GVISOR_TOOLS = "pinenote/tools/gvisor-package"
GVISOR_RECURSIVE_EXCLUDED = {
    "__pycache__",
    "bazel_bootstrap.py",
    "runtime-check.sh",
    "runtime_setup.py",
    "test_bazel_bootstrap.py",
    "test_runtime_setup.py",
}


class PreparationError(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_relative(raw: str) -> str:
    if not raw or "\\" in raw or "\x00" in raw:
        raise PreparationError(f"unsafe roster path: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise PreparationError(f"unsafe roster path: {raw!r}")
    if path.as_posix() != raw:
        raise PreparationError(f"non-canonical roster path: {raw!r}")
    if FORBIDDEN_PARTS.intersection(path.parts):
        raise PreparationError(f"forbidden mutable path in roster: {raw}")
    return raw


def stable_file(root_fd: int, relative: str) -> tuple[bytes, os.stat_result]:
    """Read RELATIVE without following links and reject a changing source."""
    parts = PurePosixPath(relative).parts
    directory_fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(
            parts[-1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        try:
            before = os.fstat(file_fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
                raise PreparationError(
                    f"source is not a single-link regular file: {relative}"
                )
            blocks: list[bytes] = []
            while True:
                block = os.read(file_fd, 1024 * 1024)
                if not block:
                    break
                blocks.append(block)
            after = os.fstat(file_fd)
        finally:
            os.close(file_fd)
    except (FileNotFoundError, NotADirectoryError, OSError) as error:
        raise PreparationError(f"source is missing, linked, or special: {relative}") from error
    finally:
        os.close(directory_fd)
    identity = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_mode,
        item.st_nlink,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
    )
    if identity(before) != identity(after):
        raise PreparationError(f"source changed while being read: {relative}")
    return b"".join(blocks), after


def parse_roster(data: bytes) -> list[tuple[str, str, int, str]]:
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise PreparationError("capsule roster is not UTF-8") from error
    if not lines or lines[0] != ROSTER_HEADER:
        raise PreparationError("capsule roster has the wrong header")
    entries: list[tuple[str, str, int, str]] = []
    seen: set[str] = set()
    for number, line in enumerate(lines[1:], 2):
        fields = line.split("\t")
        if len(fields) != 4:
            raise PreparationError(f"capsule roster line {number} is malformed")
        relative, expected, raw_mode, role = fields
        relative = safe_relative(relative)
        if relative in seen:
            raise PreparationError(f"duplicate capsule path: {relative}")
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise PreparationError(f"invalid SHA-256 for {relative}")
        if raw_mode not in ("0444", "0555"):
            raise PreparationError(f"invalid capsule mode for {relative}: {raw_mode}")
        if role not in ROLES:
            raise PreparationError(f"invalid capsule role for {relative}: {role}")
        seen.add(relative)
        entries.append((relative, expected, int(raw_mode, 8), role))
    if [entry[0] for entry in entries] != sorted(seen):
        raise PreparationError("capsule roster paths are not strictly sorted")
    if not REQUIRED_CONTROLS <= seen:
        raise PreparationError(
            f"capsule roster omits controls: {sorted(REQUIRED_CONTROLS - seen)}"
        )
    return entries


def parse_source_manifest(data: bytes) -> dict[str, str]:
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise PreparationError("source manifest is not UTF-8") from error
    result: dict[str, str] = {}
    for number, line in enumerate(lines, 1):
        fields = line.split("  ", 1)
        if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
            raise PreparationError(f"source manifest line {number} is malformed")
        relative = safe_relative(fields[1])
        if relative in result:
            raise PreparationError(f"duplicate source-manifest path: {relative}")
        result[relative] = fields[0]
    if list(result) != sorted(result):
        raise PreparationError("source manifest paths are not strictly sorted")
    return result


def local_imports(text: str) -> set[str]:
    return {
        "pinenote/" + match.replace(" ", "/") + ".scm"
        for match in re.findall(r"#:use-module\s+\(pinenote\s+([^)]+)\)", text)
    }


def expected_module_name(relative: str) -> str:
    return " ".join(PurePosixPath(relative).with_suffix("").parts)


def validate_semantics(
    entries: list[tuple[str, str, int, str]], contents: dict[str, bytes]
) -> None:
    roster = {relative: (expected, mode, role) for relative, expected, mode, role in entries}
    source_manifest = parse_source_manifest(contents[SOURCE_MANIFEST])
    expected_source_paths = set(roster) - {SOURCE_MANIFEST}
    if set(source_manifest) != expected_source_paths:
        missing = sorted(expected_source_paths - set(source_manifest))
        extra = sorted(set(source_manifest) - expected_source_paths)
        raise PreparationError(
            f"source manifest and capsule roster differ: missing={missing} extra={extra}"
        )
    for relative, expected in source_manifest.items():
        if roster[relative][0] != expected:
            raise PreparationError(f"manifest/roster hash disagreement: {relative}")

    modules = {relative for relative, _, _, role in entries if role == "module"}
    discovered: set[str] = set()
    pending = [START_MODULE]
    while pending:
        relative = pending.pop()
        if relative in discovered:
            continue
        if relative not in modules:
            raise PreparationError(f"module closure is missing: {relative}")
        text = contents[relative].decode("utf-8")
        declaration = f"(define-module ({expected_module_name(relative)})"
        if declaration not in text:
            raise PreparationError(f"module declaration mismatch: {relative}")
        discovered.add(relative)
        pending.extend(sorted(local_imports(text) - discovered))
    if discovered != modules:
        raise PreparationError(
            f"unreachable project modules entered capsule: {sorted(modules - discovered)}"
        )

    local_inputs: set[str] = set()
    recursive_roots: set[str] = set()
    for relative in sorted(modules):
        text = contents[relative].decode("utf-8")
        parent = PurePosixPath(relative).parent
        for raw in re.findall(r'\(local-file\s+"([^"]+)"', text):
            resolved = (parent / raw)
            normalized = os.path.normpath(resolved.as_posix())
            safe_relative(normalized)
            if normalized == GVISOR_TOOLS:
                recursive_roots.add(normalized)
            else:
                local_inputs.add(normalized)
    assets = {relative for relative, _, _, role in entries if role == "asset"}
    missing_inputs = local_inputs - (assets | modules)
    if missing_inputs:
        raise PreparationError(
            f"local-file inputs are absent from asset roster: {sorted(missing_inputs)}"
        )
    if recursive_roots != {GVISOR_TOOLS}:
        raise PreparationError("unexpected recursive local-file root")
    recursive_assets = {
        relative
        for relative in assets
        if PurePosixPath(relative).parent.as_posix() == GVISOR_TOOLS
        and PurePosixPath(relative).name not in GVISOR_RECURSIVE_EXCLUDED
    }
    if not recursive_assets:
        raise PreparationError("recursive gVisor tool input is empty")
    unused_assets = assets - local_inputs - recursive_assets
    if unused_assets:
        raise PreparationError(
            f"asset roster contains inputs unused by module graph: {sorted(unused_assets)}"
        )


def require_empty_output(output: Path) -> None:
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not output.is_dir():
            raise PreparationError(f"output is not a real directory: {output}")
        if next(output.iterdir(), None) is not None:
            raise PreparationError(f"output directory is not empty: {output}")
    else:
        output.mkdir(mode=0o700, parents=True)


def write_file(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as target:
        target.write(data)
        target.flush()
        os.fsync(target.fileno())
    path.chmod(mode)


def make_directories_read_only(root: Path) -> None:
    for directory, names, _files in os.walk(root, topdown=False, followlinks=False):
        current = Path(directory)
        for name in names:
            child = current / name
            if child.is_symlink():
                raise PreparationError(f"prepared capsule contains a symlink: {child}")
        current.chmod(0o555)


def prepare(source_root: Path, output: Path, roster_path: Path = DEFAULT_ROSTER) -> None:
    if not source_root.is_absolute() or not output.is_absolute():
        raise PreparationError("source root and output must be absolute")
    canonical_source = source_root.resolve(strict=True)
    if canonical_source != source_root or not canonical_source.is_dir():
        raise PreparationError("source root must be a canonical real directory")
    canonical_output_parent = output.parent.resolve(strict=True)
    output = canonical_output_parent / output.name
    if output == canonical_source or canonical_source in output.parents:
        raise PreparationError("output must be outside the source root")
    if output in canonical_source.parents:
        raise PreparationError("source root must not be inside output")

    roster_relative = CAPSULE_ROSTER
    expected_roster_path = canonical_source / roster_relative
    if roster_path.resolve(strict=True) != expected_roster_path:
        raise PreparationError("only the candidate's canonical capsule roster is accepted")
    root_fd = os.open(canonical_source, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        roster_data, roster_stat = stable_file(root_fd, roster_relative)
        entries = parse_roster(roster_data)
        contents: dict[str, bytes] = {}
        identities: dict[str, tuple[int, ...]] = {}
        for relative, expected, _mode, _role in entries:
            data, info = stable_file(root_fd, relative)
            if digest(data) != expected:
                raise PreparationError(f"source hash mismatch: {relative}")
            contents[relative] = data
            identities[relative] = (
                info.st_dev,
                info.st_ino,
                info.st_mode,
                info.st_nlink,
                info.st_size,
                info.st_mtime_ns,
                info.st_ctime_ns,
            )
        validate_semantics(entries, contents)
        require_empty_output(output)
        repo = output / "repo"
        module_view = output / "module-view"
        package_view = output / "package-view"
        metadata = output / "metadata"
        for directory in (repo, module_view, package_view, metadata):
            directory.mkdir(mode=0o700)

        for relative, _expected, mode, role in entries:
            write_file(repo / relative, contents[relative], 0o444)
            if role in {"module", "asset"}:
                write_file(module_view / relative, contents[relative], mode)
        write_file(repo / CAPSULE_ROSTER, roster_data, 0o444)
        write_file(metadata / "CAPSULE-ROSTER.tsv", roster_data, 0o444)
        write_file(
            package_view / "EMPTY.txt",
            b"schema=1\nrole=zero-Scheme-package-discovery-view\nscheme-files=0\n",
            0o444,
        )
        prepared = (
            "schema=1\n"
            f"capsule-roster-sha256={digest(roster_data)}\n"
            f"source-files={len(entries)}\n"
            f"module-files={sum(role == 'module' for _, _, _, role in entries)}\n"
            f"asset-files={sum(role == 'asset' for _, _, _, role in entries)}\n"
            f"check-files={sum(role == 'check' for _, _, _, role in entries)}\n"
            "module-load-view=positive-explicit-modules-and-relative-local-file-assets\n"
            "package-discovery-view=zero-Scheme-files\n"
            "ambient-repository-fallback=forbidden\n"
        ).encode("utf-8")
        write_file(metadata / "PREPARED.txt", prepared, 0o444)

        # Re-read every candidate input after all copies are complete.  This is
        # the whole-capture guard, not merely a per-file pre-copy hash check.
        roster_again, roster_after = stable_file(root_fd, roster_relative)
        if roster_again != roster_data or (
            roster_after.st_dev,
            roster_after.st_ino,
            roster_after.st_mode,
            roster_after.st_nlink,
            roster_after.st_size,
            roster_after.st_mtime_ns,
            roster_after.st_ctime_ns,
        ) != (
            roster_stat.st_dev,
            roster_stat.st_ino,
            roster_stat.st_mode,
            roster_stat.st_nlink,
            roster_stat.st_size,
            roster_stat.st_mtime_ns,
            roster_stat.st_ctime_ns,
        ):
            raise PreparationError("capsule roster changed during capture")
        for relative in sorted(contents):
            data, info = stable_file(root_fd, relative)
            identity = (
                info.st_dev,
                info.st_ino,
                info.st_mode,
                info.st_nlink,
                info.st_size,
                info.st_mtime_ns,
                info.st_ctime_ns,
            )
            if data != contents[relative] or identity != identities[relative]:
                raise PreparationError(f"source changed during capsule capture: {relative}")

        make_directories_read_only(output)
    except Exception:
        if output.exists() and output != canonical_source:
            for directory, names, files in os.walk(output, topdown=False):
                for name in files:
                    (Path(directory) / name).chmod(0o600)
                for name in names:
                    (Path(directory) / name).chmod(0o700)
                Path(directory).chmod(0o700)
            shutil.rmtree(output)
        raise
    finally:
        os.close(root_fd)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    prepare(arguments.source_root, arguments.output)
    print(f"BOOK_STATE_CAPSULE={arguments.output}")
    print("PASS: finite Book State guest source capsule prepared read-only")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PreparationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
