#!/usr/bin/env python3
"""Bounded BEP-1 caller-cache and compiled-path regression."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


class IsolationError(RuntimeError):
    pass


def require_real_directory(path: Path) -> None:
    if not path.is_dir() or path.is_symlink():
        raise IsolationError(f"not a real directory: {path}")


def private_environment(home: Path, cache: Path | None) -> dict[str, str]:
    require_real_directory(home)
    environment = {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": str(home / "empty-path"),
        "GUILE_AUTO_COMPILE": "0",
        "GUILE_LOAD_PATH": "",
        "GUILE_LOAD_COMPILED_PATH": "",
        "GUILE_EXTENSIONS_PATH": "",
    }
    (home / "empty-path").mkdir(mode=0o700, exist_ok=True)
    if cache is not None:
        require_real_directory(cache)
        environment["XDG_CACHE_HOME"] = str(cache)
    return environment


def run(
    command: list[str],
    environment: dict[str, str],
    stdout: Path,
    stderr: Path,
) -> None:
    with stdout.open("xb") as output, stderr.open("xb") as errors:
        result = subprocess.run(command, env=environment, stdout=output, stderr=errors)
    if result.returncode != 0:
        raise IsolationError(f"command failed with status {result.returncode}: {command}")


def compiled_file_name(
    guile: Path, source: Path, home: Path, cache: Path | None, output: Path
) -> Path:
    expression = (
        "(use-modules (system base compile)) "
        f"(display (compiled-file-name {json.dumps(str(source))}))"
    )
    result = subprocess.run(
        [str(guile), "--no-auto-compile", "-c", expression],
        env=private_environment(home, cache),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    output.write_text(result.stdout + "\n", encoding="utf-8")
    return Path(result.stdout)


def poison_command_source(path: Path, marker: Path) -> None:
    path.write_text(
        "(begin\n"
        f"  (call-with-output-file {json.dumps(str(marker))}\n"
        "    (lambda (port) (display \"BEP1_CALLER_CACHE_EXECUTED\\n\" port)))\n"
        "  (display \"FORGED_GUIX_OUTPUT\\n\"))\n",
        encoding="utf-8",
    )


def compile_command_poison(
    guild: Path,
    guile: Path,
    guix: Path,
    source: Path,
    marker: Path,
    home: Path,
    cache: Path | None,
    compiler_home: Path,
    compiler_cache: Path,
    log_root: Path,
    label: str,
) -> Path:
    target = compiled_file_name(
        guile, guix, home, cache, log_root / f"{label}-cache-target.txt"
    )
    expected_root = cache if cache is not None else home / ".cache"
    try:
        target.relative_to(expected_root)
    except ValueError as error:
        raise IsolationError(f"compiled cache escaped {expected_root}: {target}") from error
    poison_command_source(source, marker)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    run(
        [str(guild), "compile", "-W0", "-o", str(target), str(source)],
        private_environment(compiler_home, compiler_cache),
        log_root / f"{label}-compile.stdout",
        log_root / f"{label}-compile.stderr",
    )
    target.chmod(0o600)
    for parent in target.parents:
        if parent == expected_root.parent:
            break
        if parent.exists():
            parent.chmod(0o700)
    return target


def launcher_command(arguments: argparse.Namespace, *command: str) -> list[str]:
    return [
        str(arguments.launcher),
        str(arguments.private_root),
        str(arguments.module_view),
        str(arguments.channels),
        str(arguments.bootstrap_guix),
        *command,
    ]


def poisoned_caller_environment(
    home: Path, cache: Path | None, compiled_path: Path | None = None
) -> dict[str, str]:
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    if cache is None:
        environment.pop("XDG_CACHE_HOME", None)
    else:
        environment["XDG_CACHE_HOME"] = str(cache)
    if compiled_path is not None:
        environment["GUILE_LOAD_COMPILED_PATH"] = str(compiled_path)
    environment["GUILE_LOAD_PATH"] = "/caller/poison/load-path"
    environment["GUILE_EXTENSIONS_PATH"] = "/caller/poison/extensions"
    environment["GUILE_AUTO_COMPILE"] = "fresh"
    environment["GUIX_PACKAGE_PATH"] = "/caller/poison/packages"
    environment["GUIX_BUILD_OPTIONS"] = "--max-jobs=999"
    environment["GUIX_ENVIRONMENT"] = "/caller/poison/environment"
    return environment


def require_marker_absent(marker: Path, label: str) -> None:
    if marker.exists() or marker.is_symlink():
        raise IsolationError(f"{label} poison executed before rejection: {marker}")


def prepare_directories(root: Path) -> dict[str, Path]:
    if root.exists() or root.is_symlink():
        raise IsolationError(f"isolation output already exists: {root}")
    root.mkdir(mode=0o700)
    names = (
        "compiler-home",
        "compiler-cache",
        "default-home",
        "xdg-home",
        "xdg-cache",
        "compiled-path",
        "safe-source",
        "sources",
    )
    result = {name: root / name for name in names}
    for path in result.values():
        path.mkdir(mode=0o700)
    return result


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap-guix", type=Path, required=True)
    parser.add_argument("--bootstrap-guile", type=Path, required=True)
    parser.add_argument("--bootstrap-guild", type=Path, required=True)
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--private-root", type=Path, required=True)
    parser.add_argument("--module-view", type=Path, required=True)
    parser.add_argument("--channels", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    for path in (
        arguments.bootstrap_guix,
        arguments.bootstrap_guile,
        arguments.bootstrap_guild,
        arguments.launcher,
        arguments.channels,
    ):
        if not path.is_file() or path.is_symlink():
            raise IsolationError(f"not a regular fixed input: {path}")
    for path in (arguments.private_root, arguments.module_view):
        require_real_directory(path)

    paths = prepare_directories(arguments.output)
    default_marker = arguments.output / "default-cache-marker"
    xdg_marker = arguments.output / "xdg-cache-marker"
    compiled_marker = arguments.output / "compiled-path-marker"

    default_target = compile_command_poison(
        arguments.bootstrap_guild,
        arguments.bootstrap_guile,
        arguments.bootstrap_guix,
        paths["sources"] / "default-guix-command.scm",
        default_marker,
        paths["default-home"],
        None,
        paths["compiler-home"],
        paths["compiler-cache"],
        arguments.output,
        "default",
    )
    xdg_target = compile_command_poison(
        arguments.bootstrap_guild,
        arguments.bootstrap_guile,
        arguments.bootstrap_guix,
        paths["sources"] / "xdg-guix-command.scm",
        xdg_marker,
        paths["xdg-home"],
        paths["xdg-cache"],
        paths["compiler-home"],
        paths["compiler-cache"],
        arguments.output,
        "xdg",
    )

    for label, home, cache, marker in (
        ("default", paths["default-home"], None, default_marker),
        ("xdg", paths["xdg-home"], paths["xdg-cache"], xdg_marker),
    ):
        run(
            launcher_command(arguments, "--version"),
            poisoned_caller_environment(home, cache),
            arguments.output / f"{label}-probe.stdout",
            arguments.output / f"{label}-probe.stderr",
        )
        require_marker_absent(marker, label)

    safe_module = paths["safe-source"] / "bep1" / "compiled-probe.scm"
    safe_module.parent.mkdir(mode=0o700)
    safe_module.write_text(
        "(define-module (bep1 compiled-probe) #:export (probe-value))\n"
        "(define probe-value \"SAFE\")\n",
        encoding="utf-8",
    )
    poison_module = paths["sources"] / "compiled-probe.scm"
    poison_module.write_text(
        "(define-module (bep1 compiled-probe) #:export (probe-value))\n"
        f"(call-with-output-file {json.dumps(str(compiled_marker))}\n"
        "  (lambda (port) (display \"BEP1_COMPILED_PATH_EXECUTED\\n\" port)))\n"
        "(define probe-value \"POISON\")\n",
        encoding="utf-8",
    )
    poison_go = paths["compiled-path"] / "bep1" / "compiled-probe.go"
    poison_go.parent.mkdir(mode=0o700)
    run(
        launcher_command(
            arguments,
            "shell",
            "guile@3.0.9",
            "--",
            "guild",
            "compile",
            "-W0",
            "-o",
            str(poison_go),
            str(poison_module),
        ),
        poisoned_caller_environment(paths["xdg-home"], paths["xdg-cache"]),
        arguments.output / "compiled-path-compile.stdout",
        arguments.output / "compiled-path-compile.stderr",
    )
    future = max(safe_module.stat().st_mtime, poison_go.stat().st_mtime) + 60
    os.utime(poison_go, (future, future))
    run(
        launcher_command(
            arguments,
            "shell",
            "guile@3.0.9",
            "--",
            "guile",
            "--no-auto-compile",
            "-L",
            str(paths["safe-source"]),
            "-c",
            "(use-modules (bep1 compiled-probe)) "
            "(unless (string=? probe-value \"SAFE\") (error \"poison\")) "
            "(display \"SAFE_COMPILED_PATH_PROBE\\n\")",
        ),
        poisoned_caller_environment(
            paths["xdg-home"], paths["xdg-cache"], paths["compiled-path"]
        ),
        arguments.output / "compiled-path-probe.stdout",
        arguments.output / "compiled-path-probe.stderr",
    )
    require_marker_absent(compiled_marker, "compiled-path")

    (arguments.output / "POISON-PATHS.txt").write_text(
        "schema=1\n"
        f"default-home={paths['default-home']}\n"
        f"default-cache-target={default_target}\n"
        f"default-marker={default_marker}\n"
        f"xdg-home={paths['xdg-home']}\n"
        f"xdg-cache={paths['xdg-cache']}\n"
        f"xdg-cache-target={xdg_target}\n"
        f"xdg-marker={xdg_marker}\n"
        f"compiled-path={paths['compiled-path']}\n"
        f"compiled-marker={compiled_marker}\n",
        encoding="utf-8",
    )
    print("PASS: caller HOME default Guile cache poison remained unexecuted")
    print("PASS: caller XDG Guile cache poison remained unexecuted")
    print("PASS: caller GUILE_LOAD_COMPILED_PATH poison remained unexecuted")
    print("PASS: isolated pinned Guix and nested Guile probes completed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (IsolationError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
