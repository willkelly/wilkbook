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
  pm_test_line=$1
  cat >"$2" <<EOF
CONFIG_SUSPEND=y
CONFIG_SUSPEND_FREEZER=y
CONFIG_PM_SLEEP=y
CONFIG_PM_DEBUG=y
CONFIG_PM_SLEEP_DEBUG=y
$pm_test_line
CONFIG_ARM_PSCI_FW=y
EOF
}

write_config 'CONFIG_PM_TEST_SUSPEND=y' "$tmpdir/good.config"
write_config '' "$tmpdir/missing.config"
write_config 'prefix_CONFIG_PM_TEST_SUSPEND=y' "$tmpdir/prefixed.config"
write_config 'CONFIG_PM_TEST_SUSPEND=y_suffix' "$tmpdir/suffixed.config"

printf 'return true\n' >"$tmpdir/enabled-policy.lua"
printf '%s\n' '-- return false' 'return false' >"$tmpdir/comment-policy.lua"
printf 'return "false"\n' >"$tmpdir/string-policy.lua"
printf '%s\n' 'return false' 'return true' >"$tmpdir/later-override-policy.lua"

cat >"$tmpdir/comment-computed-enable.lua" <<'EOF'
--[[
local suspend_qualified = require("device/pinenote/suspend_policy")
    canSuspend = suspend_qualified and yes or no,
]]
local Generic = require("device/generic/device")
local suspend_qualified = require("device/pinenote/suspend_policy")
return Generic:extend{
    ["can" .. "Suspend"] = function() return true end,
}
EOF
cat >"$tmpdir/string-computed-enable.lua" <<'EOF'
local expected = [[local suspend_qualified = require("device/pinenote/suspend_policy")
    canSuspend = suspend_qualified and yes or no,]]
local Generic = require("device/generic/device")
local suspend_qualified = require("device/pinenote/suspend_policy")
return Generic:extend{
    ["can" .. "Suspend"] = function() return true end,
}
EOF
cat >"$tmpdir/later-computed-override.lua" <<'EOF'
local Generic = require("device/generic/device")
local suspend_qualified = require("device/pinenote/suspend_policy")
local PineNote = Generic:extend{
    canSuspend = suspend_qualified and yes or no,
}
PineNote["can" .. "Suspend"] = function() return true end
return PineNote
EOF
cat >"$tmpdir/ignored-policy.lua" <<'EOF'
local Generic = require("device/generic/device")
local suspend_qualified = require("device/pinenote/suspend_policy")
return Generic:extend{
    canSuspend = function() return false end,
}
EOF

write_dts() {
  root_compatible=$1
  gpio_compatible=$2
  cover_label=$3
  cover_type=$4
  cover_code=$5
  cover_status=$6
  i2c_status=$7
  pmic_compatible=$8
  cover_wake=$9
  extra_wake=${10}
  output=${11}
  cat >"$output" <<EOF
/dts-v1/;
/ {
	compatible = $root_compatible;
	#address-cells = <1>;
	#size-cells = <1>;
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

for fixture in good extra-wake missing-cover disabled-cover disabled-ancestor wrong-root wrong-gpio-compatible wrong-cover-label wrong-cover-type wrong-cover-code wrong-pmic-compatible; do
  dtc -I dts -O dtb -o "$tmpdir/$fixture.dtb" "$tmpdir/$fixture.dts"
done

expect_reject() {
  description=$1
  shift
  if sh "$inspector" "$@"; then
    printf 'FAIL: inspector accepted %s\n' "$description" >&2
    exit 1
  fi
}

sh "$inspector" "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"

expect_reject 'missing config' "$tmpdir/missing.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
expect_reject 'prefixed config spoof' "$tmpdir/prefixed.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
expect_reject 'suffixed config spoof' "$tmpdir/suffixed.config" "$tmpdir/good.dtb" "$repo_policy" "$repo_device"
expect_reject 'enabled policy' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/enabled-policy.lua" "$repo_device"
expect_reject 'comment policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/comment-policy.lua" "$repo_device"
expect_reject 'string policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/string-policy.lua" "$repo_device"
expect_reject 'later-override policy spoof' "$tmpdir/good.config" "$tmpdir/good.dtb" "$tmpdir/later-override-policy.lua" "$repo_device"
expect_reject 'comment-hidden expected lines with computed enablement' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/comment-computed-enable.lua"
expect_reject 'string-hidden expected lines with computed enablement' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/string-computed-enable.lua"
expect_reject 'later computed canSuspend override' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/later-computed-override.lua"
expect_reject 'ignored suspend policy with hardcoded disabled value' "$tmpdir/good.config" "$tmpdir/good.dtb" "$repo_policy" "$tmpdir/ignored-policy.lua"
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

printf '%s\n' 'PASS: suspend gates reject all reviewed config, Lua, and DT spoof fixtures'
