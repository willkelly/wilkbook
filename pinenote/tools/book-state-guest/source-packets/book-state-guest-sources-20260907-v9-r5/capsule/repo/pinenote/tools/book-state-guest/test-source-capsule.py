#!/usr/bin/env python3
"""Negative completeness tests for the finite source capsule."""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


TOOL_RELATIVE = Path("pinenote/tools/book-state-guest")
MISSING_CASES = (
    "pinenote/packages/gvisor-dependencies.scm",
    "pinenote/packages/kernel.scm",
    "pinenote/systems/base.scm",
    "pinenote/patches/linux-pinenote-7.0-forward-port.patch",
)


def make_writable(path: Path) -> None:
    if not path.exists():
        return
    for directory, names, files in os.walk(path, topdown=False):
        for name in files:
            (Path(directory) / name).chmod(0o600)
        for name in names:
            (Path(directory) / name).chmod(0o700)
        Path(directory).chmod(0o700)


def explicit_projection(repo: Path, output: Path) -> None:
    roster = repo / TOOL_RELATIVE / "CAPSULE-ROSTER.tsv"
    paths = []
    for line in roster.read_text(encoding="utf-8").splitlines()[1:]:
        paths.append(line.split("\t", 1)[0])
    paths.append((TOOL_RELATIVE / "CAPSULE-ROSTER.tsv").as_posix())
    output.mkdir(mode=0o700)
    for relative in paths:
        source = repo / relative
        destination = output / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o600)


def expect_prepare_failure(candidate: Path, output: Path, label: str) -> None:
    preparer = candidate / TOOL_RELATIVE / "prepare-source-capsule.py"
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            "-S",
            "-B",
            str(preparer),
            "--source-root",
            str(candidate),
            "--output",
            str(output),
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if completed.returncode == 0 or output.exists():
        raise RuntimeError(f"negative capsule preparation succeeded: {label}\n{completed.stdout}")
    print(f"PASS: source preparer rejects {label}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("capsule", type=Path)
    arguments = parser.parse_args(argv)
    capsule = arguments.capsule.resolve(strict=True)
    repo = capsule / "repo"
    with tempfile.TemporaryDirectory(prefix="book-state-capsule-negative.") as raw:
        scratch = Path(raw)
        for index, relative in enumerate(MISSING_CASES):
            candidate = scratch / f"missing-{index}"
            explicit_projection(repo, candidate)
            (candidate / relative).unlink()
            expect_prepare_failure(candidate, scratch / f"missing-output-{index}", relative)

        candidate = scratch / "manifest-tamper"
        explicit_projection(repo, candidate)
        manifest = candidate / TOOL_RELATIVE / "SOURCE-MANIFEST.sha256"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        expect_prepare_failure(candidate, scratch / "manifest-output", "source-manifest tamper")

        candidate = scratch / "linked-source"
        explicit_projection(repo, candidate)
        patch = candidate / MISSING_CASES[-1]
        saved = patch.with_name("saved.patch")
        patch.rename(saved)
        patch.symlink_to(saved.name)
        expect_prepare_failure(candidate, scratch / "linked-output", "symlinked project input")

        candidate = scratch / "special-source"
        explicit_projection(repo, candidate)
        special = candidate / MISSING_CASES[-1]
        special.unlink()
        os.mkfifo(special, 0o600)
        expect_prepare_failure(candidate, scratch / "special-output", "special project input")

        # Deterministically mutate one source after its accepted first read.
        # The whole-capture second sweep must reject it and remove the output.
        candidate = scratch / "changing-source"
        explicit_projection(repo, candidate)
        preparer_path = candidate / TOOL_RELATIVE / "prepare-source-capsule.py"
        specification = importlib.util.spec_from_file_location(
            "book_state_unstable_preparer", preparer_path
        )
        if specification is None or specification.loader is None:
            raise RuntimeError("cannot load source preparer for changing-source test")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        original_stable_file = module.stable_file
        changed_relative = (TOOL_RELATIVE / "CONTRACT.md").as_posix()
        seen = 0

        def changing_stable_file(root_fd: int, relative: str):
            nonlocal seen
            result = original_stable_file(root_fd, relative)
            if relative == changed_relative:
                seen += 1
                if seen == 1:
                    changed = candidate / relative
                    changed.write_bytes(changed.read_bytes() + b"\n")
            return result

        module.stable_file = changing_stable_file
        changing_output = scratch / "changing-output"
        try:
            module.prepare(candidate.resolve(), changing_output, preparer_path.with_name("CAPSULE-ROSTER.tsv"))
        except module.PreparationError:
            pass
        else:
            raise RuntimeError("source preparer accepted a source changed during capture")
        if changing_output.exists():
            raise RuntimeError("changing-source failure left a partial capsule")
        print("PASS: source preparer rejects a source changed during capture")

        copied = scratch / "capsule-with-extra"
        shutil.copytree(capsule, copied)
        extra_parent = copied / "module-view/pinenote/packages"
        extra_parent.chmod(0o755)
        (extra_parent / "unlisted.scm").write_text("(error \"unlisted\")\n", encoding="utf-8")
        checker = copied / "repo" / TOOL_RELATIVE / "check-source-capsule.py"
        completed = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(checker), str(copied)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if completed.returncode == 0:
            raise RuntimeError("capsule checker accepted unlisted Scheme code")
        print("PASS: capsule checker rejects unlisted Scheme code")
        make_writable(copied)
    print("PASS: missing, manifest, link, special, changing, and unlisted-code gates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
