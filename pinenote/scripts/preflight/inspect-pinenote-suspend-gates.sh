#!/bin/sh
set -eu

usage() {
  printf 'usage: %s RESOLVED_CONFIG DTB SUSPEND_POLICY_LUA KOREADER_DEVICE_LUA\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

require_config() {
  value=$1
  if ! grep -F -x -q -- "$value" "$config"; then
    fail "resolved kernel config is missing exact line $value"
  fi
  pass "resolved kernel config contains exact line $value"
}

if [ "$#" -ne 4 ]; then
  usage
  exit 2
fi

config=$1
dtb=$2
policy_lua=$3
device_lua=$4
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
policy_harness="$script_dir/validate-pinenote-suspend-policy.lua"

for file in "$config" "$dtb" "$policy_lua" "$device_lua" "$policy_harness"; do
  if [ ! -f "$file" ]; then
    fail "input is not a regular file: $file"
  fi
done

if ! command -v fdtdump >/dev/null 2>&1; then
  fail "fdtdump is required to inspect the DTB"
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to validate the decompiled DTB and policy bytes"
fi
if ! command -v luajit >/dev/null 2>&1; then
  fail "luajit is required to evaluate the restricted Lua policy harness"
fi
if ! command -v timeout >/dev/null 2>&1; then
  fail "timeout is required to bound restricted Lua policy evaluation"
fi

require_config CONFIG_SUSPEND=y
require_config CONFIG_SUSPEND_FREEZER=y
require_config CONFIG_PM_SLEEP=y
require_config CONFIG_PM_DEBUG=y
require_config CONFIG_PM_SLEEP_DEBUG=y
require_config CONFIG_PM_TEST_SUSPEND=y
require_config CONFIG_ARM_PSCI_FW=y
require_config CONFIG_ROCKCHIP_SUSPEND_MODE=y
if grep -E -q '^CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=(y|m)$' "$config"; then
  fail "resolved kernel config enables hidden Rockchip suspend activation"
fi
pass "resolved kernel config leaves hidden Rockchip suspend activation disabled"

python3 - "$policy_lua" "$device_lua" <<'PY'
import sys
from pathlib import Path


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


policy = Path(sys.argv[1]).read_bytes()
if policy != b"return false\n":
    fail("suspend policy must contain exactly 'return false' followed by one newline")

device = Path(sys.argv[2]).read_bytes()
for module in (
    b"device/pinenote/ebc_barrier",
    b"device/pinenote/ebc_sleep_frame",
    b"device/pinenote/power_capabilities",
    b"device/pinenote/power_coordinator",
):
    if module in device:
        fail(f"production device source references dormant module {module.decode()}")
PY
pass "production device source references no dormant power module"

if ! timeout 5s luajit "$policy_harness" "$device_lua"; then
  fail "restricted PineNote suspend policy evaluation failed or timed out"
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/inspect-pinenote-suspend-gates.XXXXXX") ||
  fail "could not create temporary DTS"
trap 'rm -f "$tmp"' EXIT HUP INT TERM

if ! fdtdump "$dtb" >"$tmp" 2>/dev/null; then
  fail "fdtdump could not decompile DTB: $dtb"
fi

python3 - "$tmp" <<'PY'
import re
import sys


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def quoted_tokens(value):
    return re.findall(r'"([^"\\]*)"', value)


def cells(value):
    return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|[0-9]+", value)]


nodes = []
stack = []
node_re = re.compile(r"^\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*):\s*)?([^\s{]+)\s*\{$")
property_re = re.compile(r"^\s*([A-Za-z0-9,#_-]+)\s*=\s*(.*?)\s*;$")
boolean_re = re.compile(r"^\s*([A-Za-z0-9,#_-]+)\s*;$")

for line in open(sys.argv[1], encoding="utf-8"):
    if line.strip() == "};":
        if stack:
            stack.pop()
        continue
    match = node_re.match(line)
    if match:
        name = match.group(1)
        parent = stack[-1] if stack else None
        path = "/" if parent is None else (
            f"/{name}" if parent["path"] == "/" else f'{parent["path"]}/{name}')
        node = {"path": path, "parent": parent, "properties": {}}
        nodes.append(node)
        stack.append(node)
        continue
    match = property_re.match(line)
    if match and stack:
        stack[-1]["properties"][match.group(1)] = match.group(2)
        continue
    match = boolean_re.match(line)
    if match and stack:
        stack[-1]["properties"][match.group(1)] = True

for node in nodes:
    if node["path"] != "/":
        node["properties"].setdefault(
            "name", f'"{node["path"].rsplit("/", 1)[-1].split("@", 1)[0]}"')

def one(path):
    matches = [node for node in nodes if node["path"] == path]
    if len(matches) != 1:
        fail(f"expected exactly one DT node at {path}, found {len(matches)}")
    return matches[0]


def enabled(node):
    while node is not None:
        status = node["properties"].get("status")
        if status is not None and quoted_tokens(status) not in (["okay"], ["ok"]):
            return False
        node = node["parent"]
    return True


def require_token(node, property_name, token):
    if token not in quoted_tokens(node["properties"].get(property_name, "")):
        fail(f"{node['path']} {property_name} lacks exact token {token}")


root = one("/")
require_token(root, "compatible", "pine64,pinenote-v1.2")

expected_wake_paths = ["/gpio-keys/switch-cover", "/i2c@fdd40000/pmic@20"]
wake_paths = sorted(node["path"] for node in nodes
                    if "wakeup-source" in node["properties"] and enabled(node))
if wake_paths != expected_wake_paths:
    fail(f"effectively enabled DT wake-source paths are {wake_paths}, expected {expected_wake_paths}")

gpio_keys = one("/gpio-keys")
cover = one("/gpio-keys/switch-cover")
pmic = one("/i2c@fdd40000/pmic@20")
for node in (gpio_keys, cover, pmic):
    if not enabled(node):
        fail(f"expected DT node is not effectively enabled: {node['path']}")
require_token(gpio_keys, "compatible", "gpio-keys")
if quoted_tokens(cover["properties"].get("label", "")) != ["cover"]:
    fail("cover label is not exactly cover")
if cells(cover["properties"].get("linux,input-type", "")) != [5]:
    fail("cover linux,input-type is not exactly EV_SW (5)")
if cells(cover["properties"].get("linux,code", "")) != [0]:
    fail("cover linux,code is not exactly SW_LID (0)")
require_token(pmic, "compatible", "rockchip,rk817")

idle_state_nodes = sorted(
    node["path"] for node in nodes
    if node["path"].rsplit("/", 1)[-1].split("@", 1)[0] == "idle-states"
    or "arm,idle-state" in quoted_tokens(node["properties"].get("compatible", ""))
)
idle_state_references = sorted(
    node["path"] for node in nodes if "cpu-idle-states" in node["properties"]
)
if idle_state_nodes or idle_state_references:
    fail("CPU idle states are forbidden while BSP SIP activation is compiled out: "
         f"nodes={idle_state_nodes}, references={idle_state_references}")

suspend_nodes = [
    node for node in nodes if node is not root and (
        node["path"].rsplit("/", 1)[-1].split("@", 1)[0] == "rockchip-suspend"
        or "rockchip,pm-rk3568" in quoted_tokens(node["properties"].get("compatible", ""))
    )
]
if len(suspend_nodes) != 1 or suspend_nodes[0]["path"] != "/rockchip-suspend":
    fail(f"expected only the exact root /rockchip-suspend node, found {[node['path'] for node in suspend_nodes]}")
suspend = suspend_nodes[0]
if not enabled(suspend):
    fail("/rockchip-suspend is not effectively enabled")
if quoted_tokens(suspend["properties"].get("compatible", "")) != ["rockchip,pm-rk3568"]:
    fail("/rockchip-suspend compatible is not exactly rockchip,pm-rk3568")
if quoted_tokens(suspend["properties"].get("name", "")) != ["rockchip-suspend"]:
    fail("/rockchip-suspend name is not exactly rockchip-suspend")
if quoted_tokens(suspend["properties"].get("status", "")) != ["okay"]:
    fail("/rockchip-suspend status is not exactly okay")
if set(suspend["properties"]) != {"compatible", "name", "status"}:
    extra = sorted(set(suspend["properties"]) - {"compatible", "name", "status"})
    fail(f"/rockchip-suspend carries forbidden dormant-policy properties {extra}")
suspend_descendants = [
    node["path"] for node in nodes if node["path"].startswith("/rockchip-suspend/")
]
if suspend_descendants:
    fail(f"/rockchip-suspend must not carry policy child nodes: {suspend_descendants}")
print("PASS: effective DT wake capability is exactly cover switch and RK817 PMIC with verified identities")
print("PASS: dormant Rockchip suspend node is unique, enabled, and policy-free")
PY

pass "offline suspend qualification gates passed"
printf '%s\n' 'NOTE: this does not prove TF-A/U-Boot, DDR retention, runtime wake policy, physical wake routing, EBC rails, resume, or suspend current'
