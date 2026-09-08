#!/usr/bin/env python3
"""Copy only the canonical manifest roster into a review packet source view."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: SOURCE-VIEW-RECIPE.py REPOSITORY-ROOT EMPTY-PACKET-ROOT")
    repo = Path(sys.argv[1]).resolve(strict=True)
    packet = Path(sys.argv[2]).resolve(strict=True)
    tool = repo / "pinenote/tools/book-state-guest"
    manifest = tool / "SOURCE-MANIFEST.sha256"
    source_root = packet / "source"
    if source_root.exists() or any(packet.iterdir()):
        fail("packet root must exist and be empty")

    entries: list[tuple[str, Path, Path]] = []
    seen: set[Path] = set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        expected, relative = line.split("  ", 1)
        candidate = tool / relative
        lexical = Path(os.path.abspath(candidate))
        resolved = candidate.resolve(strict=True)
        try:
            repo_relative = resolved.relative_to(repo)
        except ValueError:
            fail(f"manifest source escapes repository: {relative}")
        if resolved != lexical:
            fail(f"manifest source traverses a symlink: {relative}")
        info = resolved.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            fail(f"manifest source is not a single-link regular file: {relative}")
        actual = hashlib.sha256(resolved.read_bytes()).hexdigest()
        if actual != expected:
            fail(f"source hash mismatch: {relative}")
        if repo_relative in seen:
            fail(f"duplicate source path: {repo_relative}")
        seen.add(repo_relative)
        entries.append((expected, resolved, repo_relative))
    if len(entries) != 45:
        fail(f"expected 45 canonical entries, found {len(entries)}")

    snapshot_members = entries + [
        (hashlib.sha256(manifest.read_bytes()).hexdigest(),
         manifest,
         manifest.relative_to(repo))
    ]
    lines: list[str] = []
    for expected, source, relative in sorted(snapshot_members,
                                              key=lambda item: str(item[2])):
        destination = source_root / relative
        destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        with source.open("rb") as input_port, destination.open("xb") as output_port:
            shutil.copyfileobj(input_port, output_port)
        os.chmod(destination, 0o444)
        lines.append(f"{expected}  source/{relative.as_posix()}\n")
    (packet / "SOURCE-SNAPSHOT.sha256").write_text("".join(lines), encoding="utf-8")
    for directory, children, _files in os.walk(source_root, topdown=False):
        for child in children:
            os.chmod(Path(directory) / child, 0o555)
        os.chmod(directory, 0o555)


if __name__ == "__main__":
    main()
