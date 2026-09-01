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
# Activation is ON as of 2026-08-02: platform `deep` cannot wake without it
# (bl31 reported cfg: 0x0 and never returned).  The policy values and the
# emitted SIP sequence are both evidence-gated -- see
# doc/artifacts/pinenote-sip-sequence-differential-20260802.md.
if ! grep -F -x -q -- 'CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y' "$config"; then
  fail "resolved kernel config lacks Rockchip suspend activation (deep will not wake)"
fi
pass "resolved kernel config enables reviewed Rockchip suspend activation"

python3 - "$policy_lua" "$device_lua" <<'PY'
import sys
from pathlib import Path


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


policy = Path(sys.argv[1]).read_bytes()
if policy != b"return false\n":
    fail("legacy dormant suspend policy must remain exactly 'return false' followed by one newline")

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
  fail "restricted PineNote production-suspend evaluation failed or timed out"
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
    fail("CPU idle states remain forbidden under BSP SIP activation: "
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
# 2026-08-02: activation is ON, so the node now carries policy -- but
# EXACTLY the reviewed policy, with exactly these values, and nothing else.
# The first three were measured from os1's booted DTB (the kernel on which
# deep demonstrably works); the fourth is the standing ultra override,
# adopted 2026-08-08 after R12 proved the matched rails+override payload
# resumes on both wake legs at 4.64 mA
# (doc/artifacts/pinenote-ultra-r12-20260808).  Override and rails are a
# MATCHED PAIR: this dict requires the override, and the rail checks below
# require the rails, so any DTB this gate passes carries both halves.
ACTIVATED_POLICY = {
    "rockchip,sleep-mode-config": 0x5ec,
    "rockchip,wakeup-config": 0x10,
    "rockchip,sleep-debug-en": 0x00,
    "rockchip,suspend-state-override": 0x5,
}
allowed = {"compatible", "name", "status"} | set(ACTIVATED_POLICY)
if set(suspend["properties"]) != allowed:
    extra = sorted(set(suspend["properties"]) - allowed)
    missing = sorted(allowed - set(suspend["properties"]))
    fail("/rockchip-suspend property set is not exactly the reviewed activated "
         f"policy (unexpected={extra}, missing={missing})")
for prop, expected in sorted(ACTIVATED_POLICY.items()):
    got = cells(suspend["properties"][prop])
    if got != [expected]:
        fail(f"/rockchip-suspend {prop} is {got}, expected [{hex(expected)}] -- "
             "these values are measured, not tunable; re-run the SIP "
             "differential before changing them")
suspend_descendants = [
    node["path"] for node in nodes if node["path"].startswith("/rockchip-suspend/")
]
if suspend_descendants:
    fail(f"/rockchip-suspend must not carry policy child nodes: {suspend_descendants}")
# 2026-08-07: this gate REJECTED the rail payload; 2026-08-08 it REQUIRES
# it.  The history matters and is kept: with the rails ON, ultra parks at
# sram2wfi with GPIO0 wake armed and nothing -- not the RTC, not the power
# button -- ever wakes it (R10, R11).  With the rails OFF, wake is
# PMIC-mediated (rk817-internal alarm and PWRON restore the rails) and the
# kernel genuinely resumes: three consecutive proofs on this device, 4.64
# mA measured (R12).  So the OLD danger (rails-off = unwakeable) was
# real only in the configuration this gate used to protect; the ACTUAL
# invariant is the matched pair, and both halves are now pinned.
#
# vcc_3v3_pmu still powers the GPIO0 pad bank, so every SoC-side GPIO
# wake source (touch, pen, Wacom, BT/Wi-Fi host-wake, the cover) is dead
# during suspend BY DESIGN.  The wake sources are the PMIC paths.  A
# future wake source that is not rk817-internal will not work until this
# policy is revisited -- that is a documented consequence, not a bug.
PMU_RAILS_OFF_IN_SUSPEND = ("LDO_REG1", "LDO_REG3", "LDO_REG6")
suspend_states = [
    node for node in nodes
    if node["path"].rsplit("/", 1)[-1].startswith("regulator-state-mem")
]
for node in suspend_states:
    parent = node["parent"]
    rail = parent["path"].rsplit("/", 1)[-1] if parent else "?"
    if node["path"].rsplit("/", 1)[-1] != "regulator-state-mem":
        fail(f"{rail} carries {node['path'].rsplit('/', 1)[-1]}: the mem-lite/mem-ultra "
             "suspend states are BSP surface we do not use and must not appear in a "
             "production DT")
    if rail in PMU_RAILS_OFF_IN_SUSPEND and "regulator-off-in-suspend" not in node["properties"]:
        fail(f"{rail} is not regulator-off-in-suspend -- the reviewed ultra "
             "configuration kills this rail (R12); a rails-on DT with the "
             "standing override is the R10/R11 configuration, proven unwakeable")
seen_rails = {
    node["parent"]["path"].rsplit("/", 1)[-1]
    for node in suspend_states if node["parent"]
}
for rail in PMU_RAILS_OFF_IN_SUSPEND:
    if seen_rails and rail not in seen_rails:
        fail(f"{rail} has no regulator-state-mem: its suspend state would be "
             "unpinned, and these three rails ARE the reviewed payload")
# sdmmc1 must declare the card powered off in suspend: vqmmc (vcca_1v8_pmu)
# dies, so keep-power would hand the mmc core a stale card on resume.
sdmmc_nodes = [n for n in nodes if "cap-power-off-card" in n["properties"]]
if len(sdmmc_nodes) != 1 or not sdmmc_nodes[0]["path"].endswith("mmc@fe2b0000"):
    fail(f"cap-power-off-card must appear on exactly /mmc@fe2b0000 (sdmmc1), "
         f"found on {[n['path'] for n in sdmmc_nodes]}")
for n in nodes:
    if "keep-power-in-suspend" in n["properties"]:
        fail(f"{n['path']} carries keep-power-in-suspend: its supply dies in "
             "suspend under the reviewed rail policy")
print("PASS: the matched ultra pair is pinned -- override 5 plus the three rails off, sdmmc1 card-power-off")
print("PASS: PMU wake rails stay powered in suspend and no SDIO card-power flip is present")
print("PASS: effective DT wake capability is exactly cover switch and RK817 PMIC with verified identities")
print("PASS: dormant Rockchip suspend node is unique, enabled, and policy-free")
PY

pass "offline suspend qualification gates passed"
printf '%s\n' 'NOTE: this does not prove TF-A/U-Boot, DDR retention, runtime wake policy, physical wake routing, EBC rails, resume, or suspend current'
