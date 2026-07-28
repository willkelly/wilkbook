#!/usr/bin/env python3
"""Fail-closed compiled-DTB adapter for dormant Rockchip PM host fixtures."""

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

SLEEP_MASK = 0x7ff
WAKE_MASK = 0x1ffff
PWM_MASK = 0x1ff
MAX_GPIOS = 9
MAX_REGULATORS = 30
U32_MAX = 0xffffffff
OPTIONALS = {
    "rockchip,sleep-mode-config": "sleep_mode",
    "rockchip,wakeup-config": "wakeup",
    "rockchip,pwm-regulator-config": "pwm_regulator",
    "rockchip,sleep-debug-en": "sleep_debug",
    "rockchip,apios-suspend": "apios_suspend",
    "rockchip,virtual-poweroff": "virtual_poweroff",
}
REGULATORS = (
    ("rockchip,regulator-on-in-mem", 0, "on"),
    ("rockchip,regulator-off-in-mem", 0, "off"),
    ("rockchip,regulator-on-in-mem-lite", 1, "on"),
    ("rockchip,regulator-off-in-mem-lite", 1, "off"),
    ("rockchip,regulator-on-in-mem-ultra", 2, "on"),
    ("rockchip,regulator-off-in-mem-ultra", 2, "off"),
)
METADATA = {"compatible", "name", "status"}
ALLOWED = {*METADATA, "rockchip,power-ctrl", *OPTIONALS,
           *(name for name, _, _ in REGULATORS)}


class PolicyError(ValueError):
    pass


@dataclass
class Node:
    path: str
    properties: dict[str, str] = field(default_factory=dict)
    children: list[str] = field(default_factory=list)


def fail(message: str) -> None:
    raise PolicyError(message)


def require_tool(name: str) -> None:
    if not shutil.which(name):
        fail(f"required tool not found: {name}")


def dump_dtb(dtb: Path) -> str:
    require_tool("fdtdump")
    if not dtb.is_file():
        fail(f"DTB is not a file: {dtb}")
    result = subprocess.run(["fdtdump", str(dtb)], check=False, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        fail(f"fdtdump failed for {dtb}: {result.stderr.strip()}")
    return result.stdout


def parse_dump(text: str) -> dict[str, Node]:
    nodes: dict[str, Node] = {"/": Node("/")}
    stack = ["/"]
    root_open = False
    root_closed = False
    node_re = re.compile(r"^\s*([^\s{}]+)\s*\{$")
    prop_re = re.compile(r"^\s*([^\s=]+)\s*=\s*(.*);$")
    boolean_prop_re = re.compile(r"^\s*([^\s=;{}]+)\s*;$")
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//") or line.startswith("/dts-v1/"):
            continue
        if root_closed:
            fail(f"fdtdump has content after the root node: {line}")
        if line == "};":
            if len(stack) == 1:
                if not root_open:
                    fail("fdtdump closes the root node before opening it")
                root_closed = True
                continue
            stack.pop()
            continue
        node_match = node_re.match(raw)
        if node_match:
            name = node_match.group(1)
            if name == "/":
                if root_open or len(stack) != 1:
                    fail("fdtdump has a duplicate or nested root node")
                root_open = True
                continue
            parent = stack[-1]
            path = parent.rstrip("/") + "/" + name
            if path in nodes:
                fail(f"duplicate compiled node path: {path}")
            nodes[path] = Node(path)
            nodes[parent].children.append(path)
            stack.append(path)
            continue
        prop_match = prop_re.match(raw)
        if prop_match:
            name, value = prop_match.groups()
            if name in nodes[stack[-1]].properties:
                fail(f"duplicate property {name} at {stack[-1]}")
            nodes[stack[-1]].properties[name] = value
            continue
        boolean_prop_match = boolean_prop_re.match(raw)
        if boolean_prop_match:
            name = boolean_prop_match.group(1)
            if name in nodes[stack[-1]].properties:
                fail(f"duplicate property {name} at {stack[-1]}")
            nodes[stack[-1]].properties[name] = ""
            continue
        if len(stack) == 1 and line.startswith("/memreserve/") and line.endswith(";"):
            continue
        fail(f"unrecognized fdtdump syntax at {stack[-1]}: {line}")
    if len(stack) != 1 or not root_open or not root_closed:
        fail("fdtdump has unbalanced nodes")
    for node in nodes.values():
        if node.path != "/":
            node.properties.setdefault(
                "name", f'"{node.path.rsplit("/", 1)[-1].split("@", 1)[0]}"')
    return nodes


def cells(value: str, context: str) -> list[int]:
    if not value.startswith("<") or not value.endswith(">"):
        fail(f"{context} is not a cell property")
    words = re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", value)
    if not words:
        fail(f"{context} has no cells")
    stripped = re.sub(r"0x[0-9a-fA-F]+|\b\d+\b|[<>\s]", "", value)
    if stripped:
        fail(f"{context} has malformed cells")
    return [int(word, 0) for word in words]


def strings(value: str, context: str) -> list[str]:
    result = re.findall(r'"([^"]*)"', value)
    if not result:
        fail(f"{context} is not a string property")
    return result


def phandle_nodes(nodes: dict[str, Node]) -> dict[int, Node]:
    result: dict[int, Node] = {}
    for node in nodes.values():
        if "phandle" not in node.properties:
            continue
        value = cells(node.properties["phandle"], f"{node.path}/phandle")
        if len(value) != 1 or not value[0] or value[0] in result:
            fail(f"invalid phandle at {node.path}")
        result[value[0]] = node
    return result


def stable_regulator_id(node: Node) -> int:
    value = 2166136261
    for byte in node.path.encode("utf-8"):
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value or 1


def gpio_banks(nodes: dict[str, Node]) -> dict[str, int]:
    aliases = nodes.get("/aliases")
    result: dict[str, int] = {}

    if aliases is None:
        return result
    for name, value in aliases.properties.items():
        match = re.fullmatch(r"gpio(\d+)", name)
        if not match:
            continue
        paths = strings(value, f"/aliases/{name}")
        if len(paths) != 1 or paths[0] not in nodes:
            fail(f"invalid GPIO alias {name}")
        bank = int(match.group(1))
        if bank > U32_MAX // 32:
            fail(f"GPIO alias index exceeds u32 numbering: {name}")
        if paths[0] in result:
            fail(f"GPIO controller has multiple aliases: {paths[0]}")
        result[paths[0]] = bank
    return result


def gpio_number(node: Node, pin: int, banks: dict[str, int]) -> int:
    if node.path not in banks:
        fail(f"GPIO controller lacks a gpioN alias: {node.path}")
    if pin > 31:
        fail(f"GPIO pin out of range at {node.path}")
    number = banks[node.path] * 32 + pin
    if number > U32_MAX or number == 0xffff:
        fail(f"GPIO number is not representable at {node.path}")
    return number


def scalar(node: Node, property_name: str) -> tuple[bool, int]:
    if property_name not in node.properties:
        return False, 0
    value = cells(node.properties[property_name], f"{node.path}/{property_name}")
    if len(value) != 1:
        fail(f"{property_name} must contain exactly one cell")
    return True, value[0]


def adapt(dtb: Path) -> dict:
    nodes = parse_dump(dump_dtb(dtb))
    candidates = [node for node in nodes.values()
                  if "compatible" in node.properties
                  and strings(node.properties["compatible"], f"{node.path}/compatible") ==
                  ["rockchip,pm-rk3568"]
                  and "status" in node.properties
                  and strings(node.properties["status"], f"{node.path}/status") == ["okay"]]
    if len(candidates) != 1 or candidates[0].path != "/rockchip-suspend":
        fail("expected exactly one enabled rockchip,pm-rk3568 at /rockchip-suspend")
    node = candidates[0]
    if "name" in node.properties and strings(node.properties["name"],
                                               f"{node.path}/name") != ["rockchip-suspend"]:
        fail("/rockchip-suspend name is not exactly rockchip-suspend")
    if node.children:
        fail("rockchip-suspend policy node must not have children")
    unknown = set(node.properties) - ALLOWED
    if unknown:
        fail(f"unsupported policy properties: {sorted(unknown)}")
    phandles = phandle_nodes(nodes)
    banks = gpio_banks(nodes)
    result = {field: scalar(node, prop) for prop, field in OPTIONALS.items()}
    if result["sleep_mode"][1] & ~SLEEP_MASK:
        fail("sleep-mode-config has unknown bits")
    if result["wakeup"][1] & ~WAKE_MASK:
        fail("wakeup-config has unknown bits")
    if result["pwm_regulator"][1] & ~PWM_MASK:
        fail("pwm-regulator-config has unknown bits")
    if result["virtual_poweroff"][0] and result["virtual_poweroff"][1] not in (0, 1):
        fail("virtual-poweroff must be zero or one")
    gpios: list[tuple[int, int]] = []
    if "rockchip,power-ctrl" in node.properties:
        gpio_cells = cells(node.properties["rockchip,power-ctrl"], "rockchip,power-ctrl")
        offset = 0
        while offset < len(gpio_cells):
            controller = phandles.get(gpio_cells[offset])
            if controller is None or "#gpio-cells" not in controller.properties:
                fail("unresolved GPIO controller phandle")
            count = cells(controller.properties["#gpio-cells"], f"{controller.path}/#gpio-cells")
            if len(count) != 1 or count[0] != 2 or offset + 3 > len(gpio_cells):
                fail("malformed GPIO cells")
            gpios.append((gpio_number(controller, gpio_cells[offset + 1], banks),
                          gpio_cells[offset + 2]))
            offset += 3
        if len(gpios) > MAX_GPIOS:
            fail("too many GPIO specifiers")
    regulators = [[[], []] for _ in range(3)]
    regulator_paths: dict[int, str] = {}
    for property_name, state, direction in REGULATORS:
        if property_name not in node.properties:
            continue
        refs = cells(node.properties[property_name], property_name)
        if len(refs) > MAX_REGULATORS:
            fail(f"too many regulator references in {property_name}")
        destination = regulators[state][0 if direction == "on" else 1]
        for reference in refs:
            target = phandles.get(reference)
            if target is None:
                fail(f"unresolved regulator phandle in {property_name}")
            regulator_id = stable_regulator_id(target)
            previous_path = regulator_paths.setdefault(regulator_id, target.path)
            if previous_path != target.path:
                fail(f"regulator identity collision: {previous_path} and {target.path}")
            if regulator_id in destination:
                fail(f"duplicate regulator in {property_name}")
            destination.append(regulator_id)
        if set(regulators[state][0]) & set(regulators[state][1]):
            fail(f"regulator on/off overlap for state {state}")
    return {"optionals": result, "gpios": gpios, "regulators": regulators}


def c_input(name: str, policy: dict) -> str:
    lines = [f"static const struct rockchip_suspend_model_policy_input {name} = {{"]
    for field, (present, value) in policy["optionals"].items():
        lines.append(f"\t.{field} = {{ {'true' if present else 'false'}, 0x{value:x} }},")
    for index, (number, flags) in enumerate(policy["gpios"]):
        lines.append(f"\t.gpios[{index}] = {{ 0x{number:x}, 0x{flags:x} }},")
    lines.append(f"\t.gpio_count = {len(policy['gpios'])},")
    for state, (on, off) in enumerate(policy["regulators"]):
        for index, value in enumerate(on):
            lines.append(f"\t.regulators[{state}].on[{index}] = 0x{value:x},")
        for index, value in enumerate(off):
            lines.append(f"\t.regulators[{state}].off[{index}] = 0x{value:x},")
        lines.append(f"\t.regulators[{state}].on_count = {len(on)},")
        lines.append(f"\t.regulators[{state}].off_count = {len(off)},")
    lines.append("};")
    return "\n".join(lines)


def write_header(output: Path, donor: Path, maximal: Path) -> None:
    donor_policy = adapt(donor)
    maximal_policy = adapt(maximal)
    text = "/* Generated from compiled DTBs; do not edit. */\n#ifndef ROCKCHIP_PM_COMPILED_FIXTURES_H\n#define ROCKCHIP_PM_COMPILED_FIXTURES_H\n\n"
    text += c_input("rockchip_pm_compiled_donor", donor_policy) + "\n\n"
    text += c_input("rockchip_pm_compiled_maximal", maximal_policy) + "\n\n#endif\n"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(text.encode("ascii"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=Path)
    parser.add_argument("--header", type=Path)
    parser.add_argument("donor", type=Path, nargs="?")
    parser.add_argument("maximal", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        if args.check:
            if args.header or args.donor or args.maximal:
                fail("--check accepts exactly one DTB")
            adapt(args.check)
        else:
            if not args.header or not args.donor or not args.maximal:
                fail("--header requires output, donor DTB, and maximal DTB")
            write_header(args.header, args.donor, args.maximal)
    except PolicyError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
