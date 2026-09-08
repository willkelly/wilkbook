#!/usr/bin/env python3
"""Narrow structural gates for the experimental device flavor."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SYSTEM = ROOT / "pinenote/systems/pinenote-book-state-device-reader.scm"
SERVICE = ROOT / "pinenote/services/book-state-device.scm"
AUTHORITY = ROOT / "pinenote/tools/book-state-device/book-state-device-authority.scm"
PLUGIN = ROOT / "pinenote/tools/book-state-device/plugin/bookstatedevice.koplugin/main.lua"
ACTIVATION = ROOT / "pinenote/tools/book-state-device/plugin/bookstatedevice.koplugin/activation.lua"
PYTHON_BOUNDARY = ROOT / "pinenote/tools/book-state-device/sandbox_storage_boundary.py"
OCI = ROOT / "pinenote/tools/book-state-guest/oci-state-book-bundle.scm"
DEPLOY = ROOT / "pinenote/tools/deploy/deploy.sh"


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {label}: missing {needle!r}")


system = SYSTEM.read_text()
service = SERVICE.read_text()
authority = AUTHORITY.read_text()
plugin = PLUGIN.read_text()
activation = ACTIVATION.read_text()
python_boundary = PYTHON_BOUNDARY.read_text()
oci = OCI.read_text()
deploy = DEPLOY.read_text()

require(system, "pinenote-reader-operating-system", "real reader inheritance")
require(system, "linux-pinenote-book-execution-test", "USER_NS kernel identity")
require(system, "gvisor/source", "source-built gVisor")
require(system, "%control-groups", "cgroup2 mount")
for forbidden in ("pinenote-book-state-reader-operating-system", "halt", "ttyAMA0", "virtio"):
    if forbidden in system:
        raise SystemExit(f"FAIL: hardware flavor contains QEMU/test token {forbidden!r}")

for needle in (
    '"/data/wilkbook/book-state"', '"/data/wilkbook/book-state/enabled"',
    '"GUILE_AUTO_COMPILE=0"', '"HOME=/nonexistent"',
    "#:file-creation-mask #o077", "tries 120",
):
    require(service, needle, "service boundary")

for needle in (
    "release-peer!", "finalize-owned-runsc!", "assert-parent-authority-only!",
    "book-ui-control-fd", "open-reader-state-runtime", "close-reader-state-runtime!",
    "SO_TYPE", "so-peercred", "interaction-budget-seconds 300.0",
    "generate-python-protocol-bundle", "reader-note/python@1",
    "active-listener-fd", "c-shutdown",
):
    require(authority, needle, "authority ownership")

for forbidden in ("(text-a .", "(text-b .", "Mémoire persistante", "Примечание Python"):
    if forbidden in authority or forbidden in plugin:
        raise SystemExit(f"FAIL: production device path contains scripted value {forbidden!r}")
for forbidden in ('message.kind == "edit"', 'message.kind == "save"', 'message.kind == "open"'):
    if forbidden in plugin:
        raise SystemExit(f"FAIL: production plugin accepts test automation {forbidden!r}")
for needle in ("InputDialog:new", "save_callback", "close_callback", "registerToMainMenu"):
    require(plugin, needle, "human KOReader seam")
require(plugin, "Activation.enabled()", "exact plugin activation")
for needle in ("statx", "AT_SYMLINK_NOFOLLOW", "AT_EMPTY_PATH", "O_NOFOLLOW",
               '"enabled\\n"', "stx_nlink", "stx_uid"):
    require(activation, needle, "stable activation marker")

require(service, "(cons 'book-language 'guile)", "compile-fixed first menu language")
if "getenv" in authority or "book-language" in plugin:
    raise SystemExit("FAIL: runtime caller or UI can select a book language")
for needle in ('STATE_ROOT = "/data/wilkbook/book-state"',
               'PRIVATE_UI_SOCKET = "/run/wilkbook-book-state/control.sock"',
               'language=python result=pass'):
    require(python_boundary, needle, "Python device sandbox boundary")

for flag in (
    '"--platform=systrap"', '"--network=none"', '"--host-uds=none"',
    '"--directfs=false"', '"--pass-fd=3:3"',
):
    require(oci, flag, "sandbox policy")

require(deploy, 'if [ "$flavor" = book-state-device-reader ]', "opt-in deploy path")
require(deploy, "pinenote/tools/book-state-device/derive-system.scm", "pin-gated deploy")
for flag in ("--no-grafts", "--no-substitutes", "--max-jobs=1", "--cores=2"):
    require(deploy, flag, "experimental deploy build flags")

print("PASS: experimental device flavor/source boundaries")
