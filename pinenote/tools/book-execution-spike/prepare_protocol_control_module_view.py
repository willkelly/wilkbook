#!/usr/bin/env python3
"""Create or verify the fixed Guix module view for the protocol-control image.

Guix's build-command ``-L`` option adds its argument to both ``%load-path``
and ``%package-module-path``.  Package lookup then recursively discovers and
loads every ``.scm`` below that path.  This view therefore contains symlinks to
the exact required Guix modules and no executable fixture/tool Scheme sources.

The CLI is deliberately closed: it operates only on the two fixed views below
and accepts exactly ``create``, ``create-package-view``, or ``check``.  Tests
may call the internal functions with temporary paths, but no caller can select
source identities.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import sys


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MODULE_VIEW = HERE / "build/protocol-control-guix-module-view-v1"
PACKAGE_DISCOVERY_VIEW = HERE / "build/protocol-control-guix-package-view-v1"
MANIFEST_NAME = "MODULES.sha256"
PACKAGE_MARKER_NAME = "EMPTY"

# Complete transitive set of repository modules imported by the accepted
# protocol-control system.  Local-file assets are intentionally absent.  The
# symlinks resolve to the original files, so Guile's current-source-directory
# keeps every relative local-file reference rooted at its reviewed source.
MODULES = {
    "pinenote/images/pinenote-bootloader.scm": (
        "eb22f49eb6e03da9eb8a3be3343fd52b593bdaf41131d9fe1af116a30a729e7b"
    ),
    "pinenote/images/pinenote-initramfs.scm": (
        "190f8aa4534c7e788dcf4b3dd18e50476c44f940f242261b4e4a6b80db9483c3"
    ),
    "pinenote/images/pinenote-partitions.scm": (
        "7e8afa07d48730124fc113c9d0ed6929fa5fe7b71470f12c13e00831e1b23daa"
    ),
    "pinenote/packages/boot.scm": (
        "2fa97c645ea5592e7529a5f3144d9304e66959e1eaf4893f24ea3b743f491aed"
    ),
    "pinenote/packages/cross-fixes.scm": (
        "26c15bd39ab83d6f8b9d4f6ec0bd7ed0970af1a83f321d34f6cf631b7e6ae843"
    ),
    "pinenote/packages/ebc-test.scm": (
        "7da8c2670b5262055324a2659a69f5b53331ddc9c1cc29c1255e5f8cacb5d37a"
    ),
    "pinenote/packages/firmware.scm": (
        "c346eddf55c274a9cf44347fdeda92fa1e2197c2d43571bc35d0fbfb5873f31d"
    ),
    "pinenote/packages/gvisor.scm": (
        "8455bc2df8e79e72fbef9a1b3da6430140fea83144e6619dfc1541e8e520866d"
    ),
    "pinenote/packages/gvisor-local-test-artifacts.scm": (
        "4e722eecd1db0a0f6c100e03690b22259c0e4bb2bd83b6fd433ad91c40b35a2b"
    ),
    "pinenote/packages/kernel.scm": (
        "699afd669c10908324847ba1802415563c77580f55edbca0cbebc4f1bfcf7106"
    ),
    "pinenote/packages/system-tools.scm": (
        "765da72035ec28bddc78de0d9965f0226f70b15dc909f49cdc078af0128fece6"
    ),
    "pinenote/services/diagnostics.scm": (
        "b0d5f8c83521b208068256587d0ea848b172dd4e91c6bbb36a252fbecce0618d"
    ),
    "pinenote/services/ebc.scm": (
        "966fe8ccbdc1966603d39518cb4928f07bf1cd1b6f3448f550c2058c05a946bc"
    ),
    "pinenote/services/state.scm": (
        "f1d2d1894cb277b8eba8a9f3bf9caae0ba7861d1bad3a10345b0350f337a761b"
    ),
    "pinenote/systems/base.scm": (
        "a83ccf2647b971e454e1a7b230b3ed39e6b2a9edbd1c68116c4fc48a7fe98658"
    ),
    "pinenote/systems/pinenote-book-execution-spike.scm": (
        "b56fafc9c64cf3ba816de85d6766b562fe1e62aac9956bfc2506af49c8336c09"
    ),
    "pinenote/systems/pinenote-book-execution-source-control.scm": (
        "341ca90202c24a2144087bf7f8e070880c0d27f08ad2240525ff303c1ea6a5c6"
    ),
    "pinenote/systems/pinenote-book-execution-protocol-control.scm": (
        "0191a7936200f465beb9014a1b2a7e7b1796de445a2bc0da68b1fb222fa03ee7"
    ),
    "pinenote/timezone.scm": (
        "dcf509a7770a42206109c708ff35e4e688c70af74a0003528a08eda1f7435b98"
    ),
}


class ModuleViewError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_module_name(relative: str) -> str:
    return " ".join(Path(relative).with_suffix("").parts)


def verify_source(path: Path, expected: str, relative: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ModuleViewError(f"module source is not a regular file: {relative}")
    actual = sha256(path)
    if actual != expected:
        raise ModuleViewError(
            f"module source hash mismatch: {relative}: expected {expected}, got {actual}"
        )
    source = path.read_text(encoding="utf-8")
    declaration = f"(define-module ({expected_module_name(relative)})"
    if declaration not in source:
        raise ModuleViewError(f"module declaration mismatch: {relative}")


def local_imports(path: Path) -> set[str]:
    source = path.read_text(encoding="utf-8")
    return {
        "pinenote/" + match.replace(" ", "/") + ".scm"
        for match in re.findall(r"#:use-module\s+\(pinenote\s+([^)]+)\)", source)
    }


def manifest_bytes() -> bytes:
    lines = [
        "schema=1",
        "role=protocol-control-guix-module-discovery-view",
        "module-count=19",
        "entry-kind=symlink-to-reviewed-original-source",
        "local-file-resolution=canonical-original-source-directory",
    ]
    lines.extend(
        f"sha256={expected} {relative}"
        for relative, expected in sorted(MODULES.items())
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


def package_marker_bytes() -> bytes:
    return (
        b"schema=1\n"
        b"role=empty-protocol-control-guix-package-discovery-view\n"
        b"scheme-files=0\n"
    )


def verify_sources() -> None:
    missing_imports: dict[str, list[str]] = {}
    for relative, expected in MODULES.items():
        source = REPO / relative
        verify_source(source, expected, relative)
        missing = sorted(local_imports(source) - MODULES.keys())
        if missing:
            missing_imports[relative] = missing
    if missing_imports:
        raise ModuleViewError(f"module whitelist misses local imports: {missing_imports}")


def view_scheme_files(view: Path) -> set[str]:
    return {
        path.relative_to(view).as_posix()
        for path in view.rglob("*.scm")
        if path.is_file()
    }


def verify_view(view: Path = MODULE_VIEW) -> None:
    verify_sources()
    if view.is_symlink() or not view.is_dir():
        raise ModuleViewError(f"module view is not a real directory: {view}")
    manifest = view / MANIFEST_NAME
    if manifest.is_symlink() or not manifest.is_file():
        raise ModuleViewError("module view manifest is not a regular file")
    if manifest.read_bytes() != manifest_bytes():
        raise ModuleViewError("module view manifest content mismatch")
    actual = view_scheme_files(view)
    expected = set(MODULES)
    if actual != expected:
        raise ModuleViewError(
            f"module view Scheme roster mismatch: missing={sorted(expected - actual)} "
            f"extra={sorted(actual - expected)}"
        )
    for relative in sorted(MODULES):
        link = view / relative
        source = (REPO / relative).resolve(strict=True)
        if not link.is_symlink():
            raise ModuleViewError(f"module view entry is not a symlink: {relative}")
        if link.resolve(strict=True) != source:
            raise ModuleViewError(f"module view target mismatch: {relative}")


def create_view(view: Path = MODULE_VIEW) -> None:
    verify_sources()
    if view.exists() or view.is_symlink():
        raise ModuleViewError(f"refusing existing module view: {view}")
    old_umask = os.umask(0o077)
    try:
        view.mkdir(mode=0o700, parents=False)
        for relative in sorted(MODULES):
            destination = view / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            destination.symlink_to((REPO / relative).resolve(strict=True))
        manifest = view / MANIFEST_NAME
        manifest.write_bytes(manifest_bytes())
        manifest.chmod(0o400)
    finally:
        os.umask(old_umask)
    verify_view(view)


def verify_package_view(view: Path = PACKAGE_DISCOVERY_VIEW) -> None:
    if view.is_symlink() or not view.is_dir():
        raise ModuleViewError(f"package-discovery view is not a real directory: {view}")
    entries = {path.name for path in view.iterdir()}
    if entries != {PACKAGE_MARKER_NAME}:
        raise ModuleViewError(
            f"package-discovery view is not empty of inputs: {sorted(entries)}"
        )
    marker = view / PACKAGE_MARKER_NAME
    if marker.is_symlink() or not marker.is_file():
        raise ModuleViewError("package-discovery marker is not a regular file")
    if marker.read_bytes() != package_marker_bytes():
        raise ModuleViewError("package-discovery marker content mismatch")
    if any(view.rglob("*.scm")):
        raise ModuleViewError("package-discovery view contains Scheme source")


def create_package_view(view: Path = PACKAGE_DISCOVERY_VIEW) -> None:
    if view.exists() or view.is_symlink():
        raise ModuleViewError(f"refusing existing package-discovery view: {view}")
    old_umask = os.umask(0o077)
    try:
        view.mkdir(mode=0o700, parents=False)
        marker = view / PACKAGE_MARKER_NAME
        marker.write_bytes(package_marker_bytes())
        marker.chmod(0o400)
    finally:
        os.umask(old_umask)
    verify_package_view(view)


def main(argv: list[str]) -> int:
    if argv == ["create"]:
        create_view()
        create_package_view()
    elif argv == ["create-package-view"]:
        create_package_view()
    elif argv == ["check"]:
        verify_view()
        verify_package_view()
    else:
        raise ModuleViewError(
            "usage: prepare_protocol_control_module_view.py "
            "create|create-package-view|check"
        )
    print(f"PASS: protocol-control Guix module view: {MODULE_VIEW}")
    print(
        "PASS: protocol-control empty package-discovery view: "
        f"{PACKAGE_DISCOVERY_VIEW}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ModuleViewError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
