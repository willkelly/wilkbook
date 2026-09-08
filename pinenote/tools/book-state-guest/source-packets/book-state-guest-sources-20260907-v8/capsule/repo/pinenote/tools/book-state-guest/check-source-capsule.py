#!/usr/bin/env python3
"""Verify a prepared Book State guest capsule without ambient source access."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys


CAPSULE_ROSTER = "pinenote/tools/book-state-guest/CAPSULE-ROSTER.tsv"
HEADER = "path\tsha256\tmode\trole"


class CheckError(RuntimeError):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)
    print(f"PASS: {message}")


def regular(path: Path, mode: int) -> bool:
    info = path.lstat()
    return stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == mode


def files_beneath(root: Path) -> set[str]:
    result: set[str] = set()
    for directory, names, files in os.walk(root, followlinks=False):
        current = Path(directory)
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise CheckError(f"capsule directory is special: {current}")
        if stat.S_IMODE(current.lstat().st_mode) != 0o555:
            raise CheckError(f"capsule directory is not mode 0555: {current}")
        for name in names:
            path = current / name
            if path.is_symlink() or not path.is_dir():
                raise CheckError(f"linked/special capsule directory: {path}")
        for name in files:
            path = current / name
            if path.is_symlink() or not path.is_file():
                raise CheckError(f"linked/special capsule file: {path}")
            result.add(path.relative_to(root).as_posix())
    return result


def load_roster(path: Path) -> list[tuple[str, str, int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != HEADER:
        raise CheckError("prepared capsule roster has the wrong header")
    result = []
    for line in lines[1:]:
        relative, expected, raw_mode, role = line.split("\t")
        result.append((relative, expected, int(raw_mode, 8), role))
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capsule", type=Path)
    arguments = parser.parse_args(argv)
    capsule = arguments.capsule.resolve(strict=True)
    check(capsule == arguments.capsule, "capsule path is canonical")
    repo = capsule / "repo"
    module_view = capsule / "module-view"
    package_view = capsule / "package-view"
    metadata = capsule / "metadata"
    check(
        set(path.name for path in capsule.iterdir())
        == {"repo", "module-view", "package-view", "metadata"},
        "capsule top level has only four fixed views",
    )
    roster_path = metadata / "CAPSULE-ROSTER.tsv"
    check(regular(roster_path, 0o444), "metadata roster is read-only regular data")
    entries = load_roster(roster_path)
    roster = {relative: (expected, mode, role) for relative, expected, mode, role in entries}
    check(len(roster) == len(entries), "capsule roster paths are unique")
    check(list(roster) == sorted(roster), "capsule roster paths are sorted")
    check(
        (repo / CAPSULE_ROSTER).read_bytes() == roster_path.read_bytes(),
        "repo and metadata carry the same capsule roster",
    )

    expected_repo = set(roster) | {CAPSULE_ROSTER}
    check(files_beneath(repo) == expected_repo, "repo contains exactly rostered source plus its roster")
    for relative, (expected, _mode, _role) in roster.items():
        path = repo / relative
        if not regular(path, 0o444):
            raise CheckError(f"repo source mode/type is wrong: {relative}")
        if digest(path) != expected:
            raise CheckError(f"repo source hash is wrong: {relative}")
    check(True, "every repo source is mode 0444 with its rostered hash")
    check(regular(repo / CAPSULE_ROSTER, 0o444), "repo roster is immutable regular data")

    expected_module_view = {
        relative for relative, (_expected, _mode, role) in roster.items()
        if role in {"module", "asset"}
    }
    check(
        files_beneath(module_view) == expected_module_view,
        "positive module view contains exactly modules and relative local-file assets",
    )
    for relative in sorted(expected_module_view):
        expected, mode, _role = roster[relative]
        path = module_view / relative
        if not regular(path, mode):
            raise CheckError(f"module-view source mode/type is wrong: {relative}")
        if digest(path) != expected:
            raise CheckError(f"module-view source hash is wrong: {relative}")
    check(True, "every module/local-file copy has its exact rostered mode and hash")

    check(
        files_beneath(package_view) == {"EMPTY.txt"},
        "package discovery view contains one non-Scheme marker",
    )
    check(regular(package_view / "EMPTY.txt", 0o444), "package marker is read-only")
    check(
        not any(path.suffix == ".scm" for path in package_view.rglob("*")),
        "package discovery view contains zero Scheme files",
    )
    check(
        files_beneath(metadata) == {"CAPSULE-ROSTER.tsv", "PREPARED.txt"},
        "metadata view contains only fixed preparation records",
    )
    prepared = (metadata / "PREPARED.txt").read_text(encoding="utf-8")
    check(
        f"capsule-roster-sha256={digest(roster_path)}" in prepared,
        "preparation record binds capsule roster",
    )
    print("PASS: prepared capsule has no symlink, special, or unlisted source")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (CheckError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
