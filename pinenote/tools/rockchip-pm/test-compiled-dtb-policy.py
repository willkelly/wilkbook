#!/usr/bin/env python3
"""Adversarial compiled-DTB fixtures for the host-only PM policy adapter."""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ADAPTER = ROOT / "compiled-dtb-policy.py"
MAXIMAL = ROOT / "fixtures" / "maximal-policy.dts"


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def require(name: str) -> None:
    if not shutil.which(name):
        raise SystemExit(f"FAIL: required tool not found: {name}")


def compiled(directory: Path, name: str, source: str) -> Path:
    dts = directory / f"{name}.dts"
    dtb = directory / f"{name}.dtb"
    dts.write_text(source)
    result = run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts)])
    if result.returncode:
        raise SystemExit(f"FAIL: dtc rejected {name}: {result.stderr.strip()}")
    return dtb


def rejected(directory: Path, name: str, source: str) -> None:
    dtb = compiled(directory, name, source)
    result = run([sys.executable, str(ADAPTER), "--check", str(dtb)])
    if not result.returncode:
        raise SystemExit(f"FAIL: adapter accepted {name}")


def accepted(directory: Path, name: str, source: str) -> None:
    dtb = compiled(directory, name, source)
    result = run([sys.executable, str(ADAPTER), "--check", str(dtb)])
    if result.returncode:
        raise SystemExit(f"FAIL: adapter rejected {name}: {result.stderr.strip()}")


def dtc_rejected(directory: Path, name: str, source: str) -> None:
    dts = directory / f"{name}.dts"
    dts.write_text(source)
    result = run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(directory / f"{name}.dtb"), str(dts)])
    if not result.returncode:
        raise SystemExit(f"FAIL: dtc accepted unresolved {name}")


def insert(source: str, text: str) -> str:
    marker = '\t\tstatus = "okay";'
    return source.replace(marker, marker + "\n" + text, 1)


def as_boolean(source: str, property_name: str) -> str:
    result, count = re.subn(
        rf"^\t\t{re.escape(property_name)}\s*=.*?;\n",
        f"\t\t{property_name};\n",
        source,
        count=1,
        flags=re.MULTILINE | re.DOTALL,
    )
    if count != 1:
        raise SystemExit(f"FAIL: fixture could not locate {property_name}")
    return result


def main() -> int:
    require("dtc")
    require("fdtdump")
    source = MAXIMAL.read_text()
    if 'name = "rockchip-suspend";' not in source:
        raise SystemExit("FAIL: maximal fixture lacks explicit name metadata")
    source_without_name = source.replace('\t\tname = "rockchip-suspend";\n', "", 1)
    if source_without_name == source:
        raise SystemExit("FAIL: maximal fixture could not omit explicit name metadata")
    dtc_rejection_count = 0
    with tempfile.TemporaryDirectory(prefix="rockchip-pm-dtb-") as temporary:
        directory = Path(temporary)
        regulator_nodes = "\n".join(
            f"\treg_extra_{index}: regulator@{0x20 + index:x} {{ "
            f"reg = <0x{0x20 + index:x}>; phandle = <{0x20 + index}>; }};"
            for index in range(29)
        )
        thirty_regulators = source.replace(
            "\trockchip-suspend {", regulator_nodes + "\n\n\trockchip-suspend {", 1
        ).replace(
            "<&reg_mem_on>, <&reg_mem_on_extra>;",
            "<" + " ".join(["&reg_mem_on"] + [f"&reg_extra_{index}" for index in range(29)]) + ">;",
            1,
        )
        accepted(directory, "thirty-distinct-regulators", thirty_regulators)
        accepted(directory, "name-metadata", source)
        accepted(directory, "synthesized-name-metadata", source_without_name)
        rejected(directory, "unknown-property", insert(source, "\t\tunknown-policy = <1>;"))
        rejected(directory, "name-lookalike", insert(source, "\t\tnames = \"rockchip-suspend\";"))
        rejected(directory, "unknown-boolean-property", insert(source, "\t\tunknown-policy;"))
        rejected(directory, "wrong-gpio-property", source.replace(
            "rockchip,power-ctrl", "rockchip,suspend-gpios", 1))
        rejected(directory, "wrong-boolean-gpio-property", insert(
            source, "\t\trockchip,suspend-gpios;"))
        rejected(directory, "unprefixed-regulator-property", source.replace(
            "rockchip,regulator-on-in-mem", "regulator-on-in-mem", 1))
        for property_name in (
            "regulator-on-in-mem",
            "regulator-off-in-mem",
            "regulator-on-in-mem-lite",
            "regulator-off-in-mem-lite",
            "regulator-on-in-mem-ultra",
            "regulator-off-in-mem-ultra",
        ):
            rejected(directory, f"boolean-{property_name}", insert(
                source, f"\t\t{property_name};"))
        for property_name in (
            "rockchip,sleep-mode-config",
            "rockchip,wakeup-config",
            "rockchip,pwm-regulator-config",
            "rockchip,sleep-debug-en",
            "rockchip,apios-suspend",
            "rockchip,virtual-poweroff",
            "rockchip,power-ctrl",
            "rockchip,regulator-on-in-mem",
            "rockchip,regulator-off-in-mem",
            "rockchip,regulator-on-in-mem-lite",
            "rockchip,regulator-off-in-mem-lite",
            "rockchip,regulator-on-in-mem-ultra",
            "rockchip,regulator-off-in-mem-ultra",
        ):
            rejected(directory, f"boolean-{property_name.replace(',', '-')}",
                     as_boolean(source, property_name))
        rejected(directory, "child-policy-node", source.replace(
            "\t\trockchip,regulator-off-in-mem-ultra = <&reg_ultra_off>;\n\t};",
            "\t\trockchip,regulator-off-in-mem-ultra = <&reg_ultra_off>;\n\t\tchild { };\n\t};",
            1))
        rejected(directory, "duplicate-compatible", source.replace(
            "\trockchip-suspend {", "\tother-suspend { compatible = \"rockchip,pm-rk3568\"; status = \"okay\"; };\n\n\trockchip-suspend {", 1))
        rejected(directory, "wrong-path", source.replace("rockchip-suspend", "other-suspend"))
        rejected(directory, "scalar-cells", source.replace("<0x7ff>", "<0x7ff 0>"))
        rejected(directory, "sleep-bits", source.replace("<0x7ff>", "<0x800>"))
        rejected(directory, "wake-bits", source.replace("<0x1ffff>", "<0x20000>"))
        rejected(directory, "pwm-bits", source.replace("<0x1ff>", "<0x200>"))
        rejected(directory, "virtual-two", source.replace("<1>;\n\t\trockchip,power-ctrl", "<2>;\n\t\trockchip,power-ctrl"))
        # ultra override: only exactly <5>, one cell, exact name.  (The
        # base fixture is the accepted <5> case.)
        rejected(directory, "override-bool", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override;"))
        rejected(directory, "override-two-cells", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override = <5 0>;"))
        rejected(directory, "override-mem", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override = <3>;"))
        rejected(directory, "override-lite", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override = <4>;"))
        rejected(directory, "override-range", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override = <6>;"))
        rejected(directory, "override-zero-sentinel", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-override = <0>;"))
        rejected(directory, "override-lookalike", source.replace(
            "rockchip,suspend-state-override = <5>;", "rockchip,suspend-state-overrides = <5>;"))
        rejected(directory, "ten-gpios", source.replace("<&gpio0 8 0xa8>;", "<&gpio0 8 0xa8>, <&gpio0 9 0xa9>;"))
        rejected(directory, "malformed-gpio", source.replace("<&gpio0 8 0xa8>;", "<&gpio0 8>;"))
        rejected(directory, "missing-gpio-alias", source.replace("\t\tgpio0 = &gpio0;\n", ""))
        rejected(directory, "duplicate-gpio-alias", source.replace(
            "\t\tgpio0 = &gpio0;", "\t\tgpio0 = &gpio0;\n\t\tgpio1 = &gpio0;"))
        rejected(directory, "overflow-gpio-alias", source.replace("gpio0 = &gpio0", "gpio134217728 = &gpio0"))
        rejected(directory, "duplicate-regulator", source.replace(
            "<&reg_mem_on>, <&reg_mem_on_extra>;",
            "<&reg_mem_on>, <&reg_mem_on>, <&reg_mem_on_extra>;"))
        rejected(directory, "regulator-overlap", source.replace("<&reg_mem_off>;", "<&reg_mem_on>;"))
        rejected(directory, "regulator-overflow", source.replace(
            "<&reg_mem_on>, <&reg_mem_on_extra>;",
            "<" + " ".join("&reg_mem_on" for _ in range(31)) + ">;"))
        rejected(directory, "wfi-time", insert(source, "\t\trockchip,suspend-wfi-time-ms = <1>;"))
        rejected(directory, "numeric-unresolved-gpio", source.replace("&gpio0 0 0xa0", "0xdeadbeef 0 0xa0"))
        rejected(directory, "numeric-unresolved-regulator", source.replace("<&reg_mem_on>", "<0xdeadbeef>", 1))
        dtc_rejected(directory, "unresolved-gpio", source.replace("&gpio0 0 0xa0", "&missing_gpio 0 0xa0"))
        dtc_rejection_count += 1
        dtc_rejected(directory, "unresolved-regulator", source.replace("&reg_mem_on", "&missing_regulator", 1))
        dtc_rejection_count += 1
    if dtc_rejection_count != 2:
        raise SystemExit("FAIL: unresolved phandle fixtures did not exercise both dtc rejections")
    print("PASS: compiled Rockchip PM DTB adapter rejects adversarial fixtures (2 dtc rejections)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
