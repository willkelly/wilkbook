#!/usr/bin/env python3
"""Static closure proof for the minimal startup bootstrap."""

from __future__ import annotations

import ast
import hashlib
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = {
    "TIMEOUT-CONTRACT.scm",
    "accepted/state-reader/fixture/bookstatereader.koplugin/_meta.lua",
    "accepted/state-reader/fixture/bookstatereader.koplugin/main.lua",
    "accepted/state-reader/fixture/bookstatereader.koplugin/state_channel.lua",
    "accepted/state-reader/fixture/bookstatereader.koplugin/ui_audit.lua",
    "bootstrap-main.scm",
    "candidate/qemu-state-coordinator.scm",
    "check-evidence.py",
    "modules/book-state-qemu/qemu-graph.scm",
    "modules/book-state-qemu/state-volume.scm",
    "modules/disposable-qemu.scm",
    "modules/guest-console-assertions.scm",
    "modules/reader-qemu-graph.scm",
    "modules/two-boot/bundle.scm",
    "modules/two-boot/fd-handoff.scm",
    "modules/two-boot/graph.scm",
    "modules/two-boot/image-binding.scm",
    "modules/two-boot/sequential.scm",
    "modules/two-boot/source-gate.scm",
    "modules/two-boot/timeout-contract.scm",
    "modules/two-boot/ui-proxy.scm",
    "one-boot.scm",
    "run-two-boot.scm",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def python_constant(path: Path, name: str) -> str:
    tree = ast.parse(path.read_bytes(), filename=str(path))
    for node in tree.body:
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(isinstance(target, ast.Name) and target.id == name
                   for target in targets):
                value = ast.literal_eval(node.value)
                if not isinstance(value, str):
                    raise AssertionError(f"{name} is not a string")
                return value
    raise AssertionError(f"missing bootstrap constant: {name}")


def shell_value(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=([^\n]+)$", text, re.MULTILINE)
    if match is None:
        raise AssertionError(f"missing launcher pin: {name}")
    return match.group(1)


def main() -> int:
    complete_manifest = ROOT / "SOURCE-MANIFEST.sha256"
    complete_entries = {
        raw[66:].decode("utf-8")
        for raw in complete_manifest.read_bytes().splitlines()
    }
    observed_sources = {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    expected_sources = complete_entries | {"SOURCE-MANIFEST.sha256"}
    if observed_sources != expected_sources:
        raise AssertionError(
            "complete source inventory differs: "
            f"missing={sorted(expected_sources-observed_sources)} "
            f"extra={sorted(observed_sources-expected_sources)}")

    manifest = ROOT / "RUNTIME-SOURCE-MANIFEST.sha256"
    data = manifest.read_bytes()
    manifest_hash = hashlib.sha256(data).hexdigest()
    if python_constant(ROOT / "bootstrap.py",
                       "EXPECTED_RUNTIME_MANIFEST_SHA256") != manifest_hash:
        raise AssertionError("bootstrap does not pin the current runtime manifest")
    entries: dict[str, str] = {}
    prior: str | None = None
    for raw in data.splitlines():
        if len(raw) < 67 or raw[64:66] != b"  ":
            raise AssertionError("malformed runtime manifest line")
        expected = raw[:64].decode("ascii")
        relative = raw[66:].decode("utf-8")
        if (re.fullmatch(r"[0-9a-f]{64}", expected) is None or
                relative.startswith("/") or ".." in relative.split("/") or
                prior is not None and prior >= relative):
            raise AssertionError("unsafe or unsorted runtime manifest")
        entries[relative] = expected
        prior = relative
    if set(entries) != RUNTIME:
        raise AssertionError(
            f"runtime closure differs: missing={sorted(RUNTIME-set(entries))} "
            f"extra={sorted(set(entries)-RUNTIME)}")
    for relative, expected in entries.items():
        path = ROOT / relative
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise AssertionError(f"runtime source identity differs: {relative}")

    launcher = (ROOT / "run-two-boot.sh").read_text()
    if shell_value(launcher, "BOOTSTRAP_PY_SHA256") != digest(ROOT / "bootstrap.py"):
        raise AssertionError("launcher does not pin current bootstrap.py bytes")
    boundary = "done < /proc/self/environ"
    first_dynamic = 'output=$($SHA256SUM -- "$1")'
    if launcher.index(boundary) > launcher.index(first_dynamic):
        raise AssertionError("inherited environment survives until a dynamic utility")
    fixed = {
        "BASH": "/gnu/store/bcxav86yvf57pxf4jazqm695r61dzaai-bash-static-5.2.37/bin/bash",
        "COREUTILS": "/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1",
        "PYTHON": "/gnu/store/c9ga6sl21sy1cbxdllvxkj6qlnk4yzbh-python-3.11.14/bin/python3.11",
        "GUILE": "/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile",
        "GCRYPT": "/gnu/store/yj7cgbs9d4qc93v93h63kpmdq0vm5k2i-guile-gcrypt-0.5.0",
        "GUIX_MODULES": "/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules",
    }
    for name, expected in fixed.items():
        if shell_value(launcher, name) != expected:
            raise AssertionError(f"launcher {name} pin differs")
    for required in (
        "bin/bash -p", "unset BASH_ENV ENV CDPATH GLOBIGNORE", "$ENV -i",
        "invocation_working_directory=$PWD",
        "while IFS= read -r -d '' inherited_entry", boundary,
        '[[ $inherited_name =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]',
        'unset -v "$inherited_name"', "export LANG=C LC_ALL=C",
        "GUILE_LOAD_PATH=", "GUILE_LOAD_COMPILED_PATH=",
        "GUILE_EXTENSIONS_PATH=", "XDG_CACHE_HOME=", "XDG_CONFIG_HOME=",
        "XDG_DATA_HOME=", "XDG_STATE_HOME=", "XDG_RUNTIME_DIR=",
        '"$bootstrap_root/bootstrap.py"', "-- \"$@\"",
    ):
        if required not in launcher:
            raise AssertionError(f"launcher lacks isolated boundary: {required}")

    bootstrap_main = (ROOT / "bootstrap-main.scm").read_text()
    guard = bootstrap_main.index("(start-run-root-guardian")
    campaign_load = bootstrap_main.index("(primitive-load")
    if not guard < campaign_load:
        raise AssertionError("campaign source loads before accepted root guardian starts")
    for relative in ("one-boot.scm", "run-two-boot.scm",
                     "modules/disposable-qemu.scm"):
        if "module-set!" in (ROOT / relative).read_text():
            raise AssertionError(f"production global mutation remains: {relative}")
    runner = (ROOT / "run-two-boot.scm").read_text()
    for forbidden in ("authorization-sha256", "bundle-manifest-sha256 HASH",
                      "authenticate-two-boot-authorization"):
        if forbidden in runner:
            raise AssertionError(f"caller authority remains in production: {forbidden}")
    if "(authenticate-production-two-boot-bundle bundle-root)" not in runner:
        raise AssertionError("production does not consume the source-pinned binding")
    one_boot = (ROOT / "one-boot.scm").read_text()
    staged_start = one_boot.index("(define coordinator-sources")
    staged_end = one_boot.index("(define (stage-coordinator!", staged_start)
    staged = one_boot[staged_start:staged_end]
    for dependency in ("modules/disposable-qemu.scm",
                       "modules/guest-console-assertions.scm"):
        if f'"{dependency}"' not in staged:
            raise AssertionError(
                f"staged coordinator omits graph dependency: {dependency}")
    archive_start = one_boot.index("(define (copy-bounded-file!")
    archive_end = one_boot.index("(define archive-roster", archive_start)
    archive_copy = one_boot[archive_start:archive_end]
    if ('"wbx"' in archive_copy or
            any(flag not in archive_copy
                for flag in ("O_EXCL", "O_NOFOLLOW", "O_CLOEXEC"))):
        raise AssertionError(
            "evidence archive does not use the exclusive descriptor path")
    print("PASS: 23-file authenticated runtime closure and pinned isolated bootstrap")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
