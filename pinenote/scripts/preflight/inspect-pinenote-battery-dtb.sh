#!/bin/sh
set -eu

usage() {
  printf 'usage: %s RK3566_PINENOTE_V1_2_DTB\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

dtb=$1

if [ ! -f "$dtb" ]; then
  fail "DTB path is not a regular file: $dtb"
fi

if ! command -v fdtdump >/dev/null 2>&1; then
  fail "fdtdump is required to inspect the DTB"
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to validate the decompiled DTB"
fi

tmp=$(mktemp "${TMPDIR:-/tmp}/inspect-pinenote-battery-dtb.XXXXXX") ||
  fail "could not create temporary DTS"
trap 'rm -f "$tmp"' EXIT HUP INT TERM

# fdtdump reads the supplied DTB and writes only the temporary DTS. The DTB is
# never modified. Unlike dtc's display-oriented decompiler, fdtdump preserves
# cells as hex values, which makes all profile values unambiguous. Decompilation
# intentionally loses source labels, so the parser below proves the
# monitored-battery phandle relationship numerically.
if ! fdtdump "$dtb" >"$tmp" 2>/dev/null; then
  fail "fdtdump could not decompile DTB: $dtb"
fi

python3 - "$tmp" <<'PY'
import re
import sys


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def cells(value):
    return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|[0-9]+", value)]


nodes = []
stack = []
node_re = re.compile(r"^\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*):\s*)?([^\s{]+)\s*\{$")
property_re = re.compile(r"^\s*([A-Za-z0-9,#_-]+)\s*=\s*(.*?)\s*;$")

for line in open(sys.argv[1], encoding="utf-8"):
    stripped = line.strip()
    if stripped == "};":
        if stack:
            stack.pop()
        continue
    match = node_re.match(line)
    if match:
        node = {"name": match.group(1), "parent": stack[-1] if stack else None,
                "properties": {}}
        nodes.append(node)
        stack.append(node)
        continue
    match = property_re.match(line)
    if match and stack:
        stack[-1]["properties"][match.group(1)] = match.group(2)


def one(description, predicate):
    matches = [node for node in nodes if predicate(node)]
    if len(matches) != 1:
        fail(f"expected exactly one {description}, found {len(matches)}")
    return matches[0]


battery = one("root battery node", lambda node: node["name"] == "battery" and
              node["parent"] is not None and node["parent"]["name"] == "/")
charger = one("RK817 charger child", lambda node: node["name"] == "charger" and
              node["parent"] is not None and node["parent"]["name"] == "pmic@20")
root = one("root node", lambda node: node["name"] == "/" and node["parent"] is None)

if '"pine64,pinenote-v1.2"' not in root["properties"].get("compatible", ""):
    fail("root compatible does not identify PineNote v1.2")

expected_scalars = {
    "charge-full-design-microamp-hours": 4000000,
    "charge-term-current-microamp": 300000,
    "constant-charge-current-max-microamp": 2000000,
    "constant-charge-voltage-max-microvolt": 4200000,
    "factory-internal-resistance-micro-ohms": 96000,
    "voltage-max-design-microvolt": 4200000,
    "voltage-min-design-microvolt": 3500000,
    "ocv-capacity-celsius": 20,
}
if battery["properties"].get("compatible") != '"simple-battery"':
    fail("battery compatible is not simple-battery")
for property_name, expected in expected_scalars.items():
    actual = cells(battery["properties"].get(property_name, ""))
    if actual != [expected]:
        fail(f"battery {property_name} is {actual}, expected {[expected]}")

expected_ocv = [4168000, 100, 4109000, 95, 4066000, 90, 4023000, 85,
                3985000, 80, 3954000, 75, 3924000, 70, 3897000, 65,
                3866000, 60, 3826000, 55, 3804000, 50, 3789000, 45,
                3777000, 40, 3770000, 35, 3763000, 30, 3750000, 25,
                3732000, 20, 3710000, 15, 3680000, 10, 3670000, 5,
                3500000, 0]
if cells(battery["properties"].get("ocv-capacity-table-0", "")) != expected_ocv:
    fail("battery OCV table does not match the upstream 21-pair profile")

expected_charger = {
    "rockchip,resistor-sense-micro-ohms": 10000,
    "rockchip,sleep-enter-current-microamp": 150000,
    "rockchip,sleep-filter-current-microamp": 100000,
}
for property_name, expected in expected_charger.items():
    actual = cells(charger["properties"].get(property_name, ""))
    if actual != [expected]:
        fail(f"charger {property_name} is {actual}, expected {[expected]}")

battery_phandle = cells(battery["properties"].get("phandle", ""))
monitored_battery = cells(charger["properties"].get("monitored-battery", ""))
if len(battery_phandle) != 1:
    fail("battery has no unique compiler-assigned phandle")
if monitored_battery != battery_phandle:
    fail("charger monitored-battery does not reference the battery node phandle")

print("PASS: generated DTB contains the exact upstream RK817 battery profile")
print("PASS: charger monitored-battery phandle resolves to the battery node")
print("NOTE: phandle numbers are compiler-assigned; only their equality is asserted")
PY

pass "generated PineNote battery DTB inspection completed"
