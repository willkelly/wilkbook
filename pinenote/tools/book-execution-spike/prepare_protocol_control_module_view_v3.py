#!/usr/bin/env python3
"""Versioned v3 view for the reviewed null-netns protocol successor."""

from __future__ import annotations

from pathlib import Path
import sys

import prepare_protocol_control_module_view as base


HERE = Path(__file__).resolve().parent
MODULE_VIEW = HERE / "build/protocol-control-guix-module-view-v3"
PACKAGE_DISCOVERY_VIEW = HERE / "build/protocol-control-guix-package-view-v3"
PROTOCOL_SYSTEM = "pinenote/systems/pinenote-book-execution-protocol-control.scm"
PROTOCOL_SYSTEM_SHA256 = (
    "00fcb3deb29649f802c0d71438a8fe1328d01af584fab4677261d9876a4b966a"
)

# Reuse the independently exercised 19-module/zero-package-Scheme mechanism,
# but do not mutate its historical v1 views or helper source.  This process-local
# roster differs only at the intentionally revised protocol-control system.
base.MODULES = dict(base.MODULES)
base.MODULES[PROTOCOL_SYSTEM] = PROTOCOL_SYSTEM_SHA256


def main(argv: list[str]) -> int:
    if argv == ["create"]:
        base.create_view(MODULE_VIEW)
        base.create_package_view(PACKAGE_DISCOVERY_VIEW)
    elif argv == ["create-package-view"]:
        base.create_package_view(PACKAGE_DISCOVERY_VIEW)
    elif argv == ["check"]:
        base.verify_view(MODULE_VIEW)
        base.verify_package_view(PACKAGE_DISCOVERY_VIEW)
    else:
        raise base.ModuleViewError(
            "usage: prepare_protocol_control_module_view_v3.py "
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
    except base.ModuleViewError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
