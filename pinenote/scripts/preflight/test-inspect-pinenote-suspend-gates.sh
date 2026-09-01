#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
inspector="$script_dir/inspect-pinenote-suspend-gates.sh"
repo_policy="$script_dir/../../packages/koreader-device/frontend/device/pinenote/suspend_policy.lua"
repo_device="$script_dir/../../packages/koreader-device/frontend/device/pinenote/device.lua"

if ! command -v dtc >/dev/null 2>&1; then
  printf 'FAIL: dtc is required for suspend-gate tests\n' >&2
  exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-inspect-pinenote-suspend-gates.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

write_config() {
  cat >"$1" <<EOF
CONFIG_SUSPEND=y
CONFIG_SUSPEND_FREEZER=y
CONFIG_PM_SLEEP=y
CONFIG_PM_DEBUG=y
CONFIG_PM_SLEEP_DEBUG=y
CONFIG_PM_TEST_SUSPEND=y
CONFIG_ARM_PSCI_FW=y
CONFIG_ROCKCHIP_SUSPEND_MODE=y
CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y
EOF
}

write_config "$tmpdir/good.config"
python3 - "$tmpdir/good.config" "$tmpdir" <<'PY'
import sys
from pathlib import Path

good_path = Path(sys.argv[1])
outdir = Path(sys.argv[2])
good = good_path.read_text()
symbols = (
    "CONFIG_PM_TEST_SUSPEND",
    "CONFIG_ROCKCHIP_SUSPEND_MODE",
    # Activation became required on 2026-08-02: deep cannot wake without it.
    # It gets the same missing/prefixed/suffixed/wrong battery as any other
    # required symbol, so a silently-dropped activation fails the gate.
    "CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE",
)
for symbol in symbols:
    exact = f"{symbol}=y"
    fixtures = {
        "missing": good.replace(exact + "\n", "", 1),
        "prefixed": good.replace(exact, "prefix_" + exact, 1),
        "suffixed": good.replace(exact, exact + "_suffix", 1),
        "wrong": good.replace(exact, f"{symbol}=m", 1),
    }
    for kind, text in fixtures.items():
        (outdir / f"{kind}-{symbol}.config").write_text(text)
(outdir / "disabled-CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE.config").write_text(
    good.replace("CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y",
                 "# CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE is not set", 1))
PY

printf 'return true\n' >"$tmpdir/enabled-policy.lua"
printf '%s\n' '-- return false' 'return false' >"$tmpdir/comment-policy.lua"
printf 'return "false"\n' >"$tmpdir/string-policy.lua"
printf '%s\n' 'return false' 'return true' >"$tmpdir/later-override-policy.lua"

cat >"$tmpdir/legacy-policy-import.lua" <<'EOF'
local Generic = require("device/generic/device")
local suspend_qualified = require("device/pinenote/suspend_policy")
return Generic:extend{
    canSuspend = function() return true end,
}
EOF
cat >"$tmpdir/disabled-suspend.lua" <<'EOF'
local Generic = require("device/generic/device")
return Generic:extend{
    canSuspend = function() return false end,
}
EOF
cat >"$tmpdir/missing-suspend.lua" <<'EOF'
local Generic = require("device/generic/device")
return Generic:extend{
}
EOF

for module in ebc_barrier ebc_sleep_frame power_capabilities power_coordinator; do
  cp "$repo_device" "$tmpdir/import-$module.lua"
  printf '\n-- fail-closed import fixture\nlocal dormant = require("device/pinenote/%s")\n' "$module" >>"$tmpdir/import-$module.lua"
done

write_dts() {
  root_compatible=$1
  gpio_compatible=$2
  cover_label=$3
  cover_type=$4
  cover_code=$5
  cover_status=$6
  i2c_status=$7
  pmic_compatible=$8
  ldo6_suspend=${10:-'regulator-off-in-suspend;'}
  cover_wake=$9
  extra_wake=${10}
  output=${11}
  cat >"$output" <<EOF
/dts-v1/;
/ {
	compatible = $root_compatible;
	#address-cells = <1>;
	#size-cells = <1>;
	rockchip-suspend {
		compatible = "rockchip,pm-rk3568";
		name = "rockchip-suspend";
		status = "okay";
		rockchip,sleep-mode-config = <0x5ec>;
		rockchip,wakeup-config = <0x10>;
		rockchip,sleep-debug-en = <0x00>;
		rockchip,suspend-state-override = <0x5>;
	};
	mmc@fe2b0000 {
		reg = <0xfe2b0000 0x4000>;
		cap-power-off-card;
	};
	gpio-keys {
		compatible = $gpio_compatible;
		switch-cover {
			label = $cover_label;
			linux,input-type = <$cover_type>;
			linux,code = <$cover_code>;
			$cover_status
			$cover_wake
		};
	};
	i2c@fdd40000 {
		reg = <0xfdd40000 0x1000>;
		#address-cells = <1>;
		#size-cells = <0>;
		$i2c_status
		pmic@20 {
			reg = <0x20>;
			compatible = $pmic_compatible;
			wakeup-source;

			regulators {
				LDO_REG1 {
					regulator-state-mem {
						regulator-off-in-suspend;
					};
				};
				LDO_REG3 {
					regulator-state-mem {
						regulator-off-in-suspend;
					};
				};
				LDO_REG6 {
					regulator-state-mem {
						$ldo6_suspend
					};
				};
			};
		};
	};
	$extra_wake
};
EOF
}

good_root='"pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"'
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/good.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk817"' 'wakeup-source;' 'pen { wakeup-source; };' "$tmpdir/extra-wake.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk817"' '' '' "$tmpdir/missing-cover.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 'status = "disabled";' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/disabled-cover.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 '' 'status = "disabled";' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/disabled-ancestor.dts"
write_dts '"vendor,other-tablet"' '"gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/wrong-root.dts"
write_dts "$good_root" '"vendor,gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/wrong-gpio-compatible.dts"
write_dts "$good_root" '"gpio-keys"' '"lid"' 5 0 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/wrong-cover-label.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 1 0 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/wrong-cover-type.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 1 '' '' '"rockchip,rk817"' 'wakeup-source;' '' "$tmpdir/wrong-cover-code.dts"
write_dts "$good_root" '"gpio-keys"' '"cover"' 5 0 '' '' '"rockchip,rk805"' 'wakeup-source;' '' "$tmpdir/wrong-pmic-compatible.dts"

python3 - "$tmpdir/good.dts" "$tmpdir" <<'PY'
import sys
from pathlib import Path

good = Path(sys.argv[1]).read_text()
outdir = Path(sys.argv[2])
suspend = '''\trockchip-suspend {
\t\tcompatible = "rockchip,pm-rk3568";
\t\tname = "rockchip-suspend";
\t\tstatus = "okay";
\t\trockchip,sleep-mode-config = <0x5ec>;
\t\trockchip,wakeup-config = <0x10>;
\t\trockchip,sleep-debug-en = <0x00>;
\t\trockchip,suspend-state-override = <0x5>;
\t};
'''
if good.count(suspend) != 1:
    raise SystemExit("FAIL: test fixture could not locate exact suspend node")

omitted_name = good.replace('\t\tname = "rockchip-suspend";\n', "", 1)
if omitted_name == good:
    raise SystemExit("FAIL: test fixture could not omit explicit suspend name")
(outdir / "omitted-suspend-name.dts").write_text(omitted_name)

fixtures = {
    "missing-suspend": good.replace(suspend, "", 1),
    "disabled-suspend": good.replace('\t\tstatus = "okay";', '\t\tstatus = "disabled";', 1),
    "wrong-suspend-compatible": good.replace("rockchip,pm-rk3568", "vendor,other-pm", 1),
    "duplicate-suspend-unit": good.replace(
        suspend,
        suspend + suspend.replace("rockchip-suspend {", "rockchip-suspend@0 {"),
        1,
    ),
    "duplicate-suspend-renamed": good.replace(
        suspend,
        suspend + suspend.replace("rockchip-suspend {", "firmware-probe {")
        .replace('name = "rockchip-suspend";', 'name = "firmware-probe";'),
        1,
    ),
    "duplicate-suspend-nested": good.replace(
        "\tgpio-keys {",
        '\tprobe-bus {\n\t\tfirmware-probe {\n'
        '\t\t\tcompatible = "rockchip,pm-rk3568";\n'
        '\t\t\tstatus = "okay";\n\t\t};\n\t};\n\tgpio-keys {',
        1,
    ),
    # anchor on the LAST property: dtc requires properties before subnodes,
    # and the activated node now has policy properties after status.
    "suspend-child-policy": good.replace(
        '\t\trockchip,suspend-state-override = <0x5>;',
        '\t\trockchip,suspend-state-override = <0x5>;\n\t\tpolicy {\n\t\t\trockchip,sleep-mode-config;\n\t\t};',
        1,
    ),
    "suspend-extra-property": good.replace(
        '\t\tstatus = "okay";',
        '\t\tstatus = "okay";\n\t\tprobe-only-extra;',
        1,
    ),
    "suspend-name-lookalike": good.replace(
        '\t\tname = "rockchip-suspend";',
        '\t\tnames = "rockchip-suspend";',
        1,
    ),
    "cpu-idle-states": good.replace(
        suspend,
        '\tcpus {\n\t\tidle-states@0 {\n\t\t};\n\t};\n' + suspend,
        1,
    ),
    "cpu-idle-state-renamed": good.replace(
        suspend,
        '\tcpus {\n\t\t#address-cells = <1>;\n\t\t#size-cells = <0>;\n'
        '\t\tcpu@0 {\n\t\t\tdevice_type = "cpu";\n\t\t\treg = <0>;\n'
        '\t\t\tcpu-idle-states = <&idle_state>;\n\t\t};\n'
        '\t\tidle_state: low-power {\n\t\t\tcompatible = "arm,idle-state";\n'
        '\t\t\tstatus = "okay";\n\t\t};\n\t};\n' + suspend,
        1,
    ),
    "arm-idle-state-compatible": good.replace(
        suspend,
        '\tlow-power {\n\t\tcompatible = "arm,idle-state";\n'
        '\t\tstatus = "okay";\n\t};\n' + suspend,
        1,
    ),
}

# 2026-08-02: sleep-mode-config / wakeup-config / sleep-debug-en moved OUT
# of this blacklist -- they are now the reviewed activated policy and are
# required.  Their exact VALUES are pinned by the value-mutation fixtures
# below, so the gate did not get weaker: an unreviewed value now fails
# where previously any value failed.
policy_properties = (
    "wakeup-source",
    "rockchip,pwm-regulator-config",
    "rockchip,power-ctrl",
    "rockchip,gpio-power-config",
    "rockchip,apios-suspend",
    "rockchip,api-os-config",
    "rockchip,suspend-wfi-time-ms",
    "rockchip,wfi-config",
    "rockchip,virtual-poweroff",
    "rockchip,sleep-pin",
    "rockchip,sleep-io",
    "rockchip,retention",
    "regulator-state-mem",
    "regulator-state-mem-lite",
    "regulator-state-mem-ultra",
    "regulator-on-in-mem",
    "regulator-off-in-mem",
    "regulator-on-in-mem-lite",
    "regulator-off-in-mem-lite",
    "regulator-on-in-mem-ultra",
    "regulator-off-in-mem-ultra",
    "rockchip,regulator-on-in-mem",
    "rockchip,regulator-off-in-mem",
    "rockchip,regulator-on-in-mem-lite",
    "rockchip,regulator-off-in-mem-lite",
    "rockchip,regulator-on-in-mem-ultra",
    "rockchip,regulator-off-in-mem-ultra",
    "regulator-suspend-microvolt",
    "regulator-suspend-mode",
    # cap-power-off-card belongs on the sdmmc1 node and nowhere else; a
    # copy inside /rockchip-suspend is policy in the wrong place.  (The
    # suspend-state-override moved from this spoof list into the GOOD
    # fixture on 2026-08-08 -- R12 made it the reviewed standing policy.)
    "cap-power-off-card",
)
for index, property_name in enumerate(policy_properties):
    name = f"suspend-policy-{index:02d}"
    fixtures[name] = good.replace(
        '\t\tstatus = "okay";',
        f'\t\tstatus = "okay";\n\t\t{property_name};',
        1,
    )

# The rail-kill half of ultra: ordinary mainline DT that lives nowhere
# near /rockchip-suspend, so the property spoofs above cannot reach it.
# These inject where a real payload would go -- inside the PMIC's
# regulator children and on the SDIO controller.
rail_payload = {
    # Inverted 2026-08-08: the reviewed policy is rails OFF, so the spoof
    # is a rail drifting back ON (the R10/R11 unwakeable configuration).
    "rail-ldo6-on": (
        "LDO_REG6 {\n\t\t\t\t\tregulator-state-mem {\n\t\t\t\t\t\tregulator-off-in-suspend;",
        "LDO_REG6 {\n\t\t\t\t\tregulator-state-mem {\n\t\t\t\t\t\tregulator-on-in-suspend;"),
    "rail-mem-ultra-node": (
        "LDO_REG6 {\n\t\t\t\t\tregulator-state-mem {",
        "LDO_REG6 {\n\t\t\t\t\tregulator-state-mem-ultra {"),
    # The card-power declaration is load-bearing both ways round.
    "rail-sdio-keep-power": (
        "\tmmc@fe2b0000 {\n\t\treg = <0xfe2b0000 0x4000>;\n\t\tcap-power-off-card;",
        "\tmmc@fe2b0000 {\n\t\treg = <0xfe2b0000 0x4000>;\n\t\tkeep-power-in-suspend;\n\t\tcap-power-off-card;"),
    "rail-sdio-missing": (
        "\tmmc@fe2b0000 {\n\t\treg = <0xfe2b0000 0x4000>;\n\t\tcap-power-off-card;\n\t};\n",
        "\tmmc@fe2b0000 {\n\t\treg = <0xfe2b0000 0x4000>;\n\t};\n"),
}
for label, (exact, mutated) in rail_payload.items():
    if good.count(exact) != 1:
        raise SystemExit(f"FAIL: fixture cannot locate rail-payload anchor for {label}")
    fixtures[label] = good.replace(exact, mutated, 1)
fixtures["rail-sdio-power-off"] = good.replace(
    '\t\tpmic@20 {', '\t\tmmc@fe2b0000 {\n\t\t\tcap-power-off-card;\n\t\t};\n\n\t\tpmic@20 {', 1)

# The activated policy's values are measured, not tunable.  Any drift must
# fail closed, and so must dropping one of the three entirely.
activated_policy = {
    "sleep-mode": ("rockchip,sleep-mode-config = <0x5ec>;",
                   "rockchip,sleep-mode-config = <0x5ed>;"),
    "wakeup": ("rockchip,wakeup-config = <0x10>;",
               "rockchip,wakeup-config = <0x11>;"),
    "sleep-debug": ("rockchip,sleep-debug-en = <0x00>;",
                    "rockchip,sleep-debug-en = <0x01>;"),
    "state-override": ("rockchip,suspend-state-override = <0x5>;",
                       "rockchip,suspend-state-override = <0x3>;"),
}
for label, (exact, mutated) in activated_policy.items():
    if good.count("\t\t" + exact) != 1:
        raise SystemExit(f"FAIL: fixture cannot locate exact policy line for {label}")
    fixtures[f"suspend-value-{label}"] = good.replace("\t\t" + exact,
                                                      "\t\t" + mutated, 1)
    fixtures[f"suspend-missing-{label}"] = good.replace("\t\t" + exact + "\n", "", 1)

manifest = []
for name, text in fixtures.items():
    (outdir / f"{name}.dts").write_text(text)
    manifest.append(name)
(outdir / "generated-dtb-fixtures.txt").write_text("\n".join(manifest) + "\n")
PY

for fixture in good omitted-suspend-name extra-wake missing-cover disabled-cover disabled-ancestor wrong-root wrong-gpio-compatible wrong-cover-label wrong-cover-type wrong-cover-code wrong-pmic-compatible; do
  dtc -I dts -O dtb -o "$tmpdir/$fixture.dtb" "$tmpdir/$fixture.dts"
done
while IFS= read -r fixture; do
  dtc -I dts -O dtb -o "$tmpdir/$fixture.dtb" "$tmpdir/$fixture.dts"
done <"$tmpdir/generated-dtb-fixtures.txt"

expect_reject() {
  description=$1
  shift
  if sh "$inspector" "$@"; then
    printf 'FAIL: inspector accepted %s\n' "$description" >&2
    exit 1
  fi
}

sh "$inspector" "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
sh "$inspector" "$tmpdir/good.config" "$tmpdir/omitted-suspend-name.dtb" "$repo_policy" "$repo_device"

for symbol in CONFIG_PM_TEST_SUSPEND CONFIG_ROCKCHIP_SUSPEND_MODE; do
  for kind in missing prefixed suffixed wrong; do
    expect_reject "$kind $symbol config" "$tmpdir/$kind-$symbol.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
  done
done
expect_reject 'disabled activation config' "$tmpdir/disabled-CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
expect_reject 'enabled policy' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/enabled-policy.lua" "$repo_device"
expect_reject 'comment policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/comment-policy.lua" "$repo_device"
expect_reject 'string policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/string-policy.lua" "$repo_device"
expect_reject 'later-override policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/later-override-policy.lua" "$repo_device"
expect_reject 'production import of the dormant legacy policy' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/legacy-policy-import.lua"
expect_reject 'production canSuspend returning false' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/disabled-suspend.lua"
expect_reject 'production device without canSuspend' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/missing-suspend.lua"
for module in ebc_barrier ebc_sleep_frame power_capabilities power_coordinator; do
  expect_reject "production device dormant $module reference" "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/import-$module.lua"
done
expect_reject 'extra wake source' "$tmpdir/good.config" "$tmpdir/extra-wake.dtb" "$repo_policy" "$repo_device"
expect_reject 'missing cover wake' "$tmpdir/good.config" "$tmpdir/missing-cover.dtb" "$repo_policy" "$repo_device"
expect_reject 'disabled expected node' "$tmpdir/good.config" "$tmpdir/disabled-cover.dtb" "$repo_policy" "$repo_device"
expect_reject 'disabled expected ancestor' "$tmpdir/good.config" "$tmpdir/disabled-ancestor.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong root compatible' "$tmpdir/good.config" "$tmpdir/wrong-root.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong gpio-keys compatible' "$tmpdir/good.config" "$tmpdir/wrong-gpio-compatible.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong cover label' "$tmpdir/good.config" "$tmpdir/wrong-cover-label.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong cover input type' "$tmpdir/good.config" "$tmpdir/wrong-cover-type.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong cover code' "$tmpdir/good.config" "$tmpdir/wrong-cover-code.dtb" "$repo_policy" "$repo_device"
expect_reject 'wrong PMIC compatible' "$tmpdir/good.config" "$tmpdir/wrong-pmic-compatible.dtb" "$repo_policy" "$repo_device"
while IFS= read -r fixture; do
  expect_reject "$fixture DT fixture" "$tmpdir/good.config" "$tmpdir/$fixture.dtb" "$repo_policy" "$repo_device"
done <"$tmpdir/generated-dtb-fixtures.txt"

printf '%s\n' 'PASS: suspend gates reject all reviewed config, Lua, and DT spoof fixtures'
