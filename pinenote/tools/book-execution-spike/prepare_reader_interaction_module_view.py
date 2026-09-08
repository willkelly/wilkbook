#!/usr/bin/env python3
"""Create or verify the fixed 20-module reader-interaction Guix view."""

from __future__ import annotations

from pathlib import Path
import sys

import prepare_protocol_control_module_view as base


HERE = Path(__file__).resolve().parent
MODULE_VIEW = HERE / "build/reader-interaction-guix-module-view-v1"
PACKAGE_DISCOVERY_VIEW = HERE / "build/reader-interaction-guix-package-view-v1"
PROTOCOL_SYSTEM = "pinenote/systems/pinenote-book-execution-protocol-control.scm"
PROTOCOL_SYSTEM_SHA256 = (
    "81276943c553efdf6d0cfed9b12b2ed591b86c8e11415f252861d367eb5c1047"
)
READER_SYSTEM = "pinenote/systems/pinenote-book-execution-reader-interaction.scm"
READER_SYSTEM_SHA256 = (
    "eba953b32744304221537e2bc1d990c0ad18ca9d56a35afb92b1137acc88f6e8"
)

# Reuse the exercised symlink/source-identity implementation without changing
# any historical 19-module view.  The only roster addition is the new system;
# the accepted protocol system is advanced to its already-frozen v4 identity.
ACCEPTED_PROTOCOL_MODULES = dict(base.MODULES)
ACCEPTED_PROTOCOL_MODULES[PROTOCOL_SYSTEM] = PROTOCOL_SYSTEM_SHA256
MODULES = dict(ACCEPTED_PROTOCOL_MODULES)
MODULES[READER_SYSTEM] = READER_SYSTEM_SHA256
base.MODULES = MODULES


def manifest_bytes() -> bytes:
    lines = [
        "schema=1",
        "role=reader-interaction-guix-module-discovery-view",
        "module-count=20",
        "base=accepted-protocol-control-v4-19-module-view",
        "delta=add-pinenote-book-execution-reader-interaction",
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
        b"role=empty-reader-interaction-guix-package-discovery-view\n"
        b"scheme-files=0\n"
    )


# base.create/verify resolve these globals at call time.  Keep the historical
# helper and views byte-for-byte unchanged while giving this sibling its own
# exact manifest role and count.
base.manifest_bytes = manifest_bytes
base.package_marker_bytes = package_marker_bytes


def create_view(view: Path = MODULE_VIEW) -> None:
    base.create_view(view)


def verify_view(view: Path = MODULE_VIEW) -> None:
    base.verify_view(view)


def create_package_view(view: Path = PACKAGE_DISCOVERY_VIEW) -> None:
    base.create_package_view(view)


def verify_package_view(view: Path = PACKAGE_DISCOVERY_VIEW) -> None:
    base.verify_package_view(view)


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
        raise base.ModuleViewError(
            "usage: prepare_reader_interaction_module_view.py "
            "create|create-package-view|check"
        )
    print(f"PASS: reader-interaction 20-module Guix view: {MODULE_VIEW}")
    print(
        "PASS: reader-interaction empty package-discovery view: "
        f"{PACKAGE_DISCOVERY_VIEW}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except base.ModuleViewError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
