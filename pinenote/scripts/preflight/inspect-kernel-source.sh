#!/bin/sh
set -eu

usage() {
  printf 'usage: %s KERNEL_SOURCE_DIRECTORY RESOLVED_CONFIG\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
}

pass() {
  printf 'PASS: %s\n' "$1"
}

note() {
  printf 'NOTE: %s\n' "$1"
}

require_file() {
  relative_path=$1
  if [ ! -f "$source_dir/$relative_path" ]; then
    fail "missing required kernel source artifact: $relative_path"
  fi
  pass "found $relative_path"
}

require_contains() {
  relative_path=$1
  expected_text=$2
  description=$3

  if ! grep -F -q -- "$expected_text" "$source_dir/$relative_path"; then
    fail "$relative_path does not contain expected $description: $expected_text"
  fi
  pass "$relative_path contains $description"
}

require_source_line() {
  relative_path=$1
  expected_text=$2
  description=$3

  if ! grep -F -x -q -- "$expected_text" "$source_dir/$relative_path"; then
    fail "$relative_path does not contain exact $description: $expected_text"
  fi
  pass "$relative_path contains exact $description"
}

require_resolved_config() {
  expected_text=$1
  description=$2

  if ! grep -F -x -q -- "$expected_text" "$config_file"; then
    fail "resolved pinenote_defconfig does not contain expected $description: $expected_text"
  fi
  pass "resolved pinenote_defconfig contains $description"
}

reject_resolved_config_enabled() {
  symbol=$1
  description=$2

  if grep -E -q "^${symbol}=(y|m)$" "$config_file"; then
    fail "resolved pinenote_defconfig enables forbidden $description"
  fi
  pass "resolved pinenote_defconfig leaves $description disabled"
}

reject_contains() {
  relative_path=$1
  forbidden_text=$2
  description=$3

  if grep -F -q -- "$forbidden_text" "$source_dir/$relative_path"; then
    fail "$relative_path contains forbidden $description: $forbidden_text"
  fi
  pass "$relative_path omits $description"
}

reject_file() {
  relative_path=$1
  description=$2

  if [ -e "$source_dir/$relative_path" ]; then
    fail "$relative_path retains forbidden $description"
  fi
  pass "$relative_path is absent as required for $description"
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

source_dir=$1
config_file=$2
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rockchip_pm_check="$script_dir/../../tools/rockchip-pm/check.py"
rockchip_pm_patch="$script_dir/../../patches/linux-pinenote-7.0-bsp-sip-probe.patch"
rockchip_pm_validator="$script_dir/validate-rockchip-pm-source.sh"

if [ ! -d "$source_dir" ]; then
  fail "kernel source path is not a directory: $source_dir"
fi

if [ ! -f "$config_file" ]; then
  fail "resolved kernel config is not a regular file: $config_file"
fi
if [ ! -f "$rockchip_pm_validator" ]; then
  fail "missing Rockchip PM validation wrapper: $rockchip_pm_validator"
fi

if git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  current_commit=$(git -C "$source_dir" rev-parse HEAD)
  note "git commit: $current_commit"
else
  warn "kernel source path is not a git checkout; commit identity was not verified"
fi

require_file arch/arm64/configs/pinenote_defconfig
require_file arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts
require_file arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi
require_file drivers/gpu/drm/rockchip/rockchip_ebc.c
require_file include/soc/rockchip/rockchip_legacy_sip.h
require_file include/dt-bindings/suspend/rockchip-rk3568.h
require_file drivers/soc/rockchip/rockchip_suspend_model.h
require_file drivers/soc/rockchip/rockchip_suspend_model.c
require_file drivers/soc/rockchip/rockchip_suspend_of.h
require_file drivers/soc/rockchip/rockchip_suspend_of.c
require_file drivers/soc/rockchip/rockchip_suspend_executor.c
require_file drivers/soc/rockchip/rockchip_suspend_backend.h
require_file drivers/soc/rockchip/rockchip_suspend_backend.c
require_file drivers/soc/rockchip/rockchip_suspend_activate.c
require_file drivers/soc/rockchip/rockchip_suspend_mode.c
require_file drivers/regulator/core.c
require_file include/linux/regulator/consumer.h
require_file include/linux/regulator/of_regulator.h
require_file drivers/pmdomain/rockchip/pm-domains.c
require_file include/soc/rockchip/rockchip_sip.h
reject_file drivers/firmware/rockchip_legacy_sip.c 'legacy SIP query transport'
reject_file drivers/soc/rockchip/rockchip_suspend_mode_core.c 'retired generic suspend model core'
reject_file drivers/soc/rockchip/rockchip_suspend_mode.h 'retired generic suspend model header'
reject_file drivers/soc/rockchip/rockchip_suspend_activate.h 'retired split activation declaration'

require_contains arch/arm64/configs/pinenote_defconfig CONFIG_DRM_ROCKCHIP_EBC=m CONFIG_DRM_ROCKCHIP_EBC
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_REGULATOR_TPS65185=m CONFIG_REGULATOR_TPS65185
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_TOUCHSCREEN_CYTTSP5=m CONFIG_TOUCHSCREEN_CYTTSP5
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_BRCMFMAC=m CONFIG_BRCMFMAC
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_I2C_HID_OF=m CONFIG_I2C_HID_OF
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_MMC_DW_ROCKCHIP=y CONFIG_MMC_DW_ROCKCHIP
pass "using caller-supplied build-produced resolved config"
require_resolved_config CONFIG_POWER_SUPPLY=y CONFIG_POWER_SUPPLY
require_resolved_config CONFIG_CHARGER_RK817=y CONFIG_CHARGER_RK817
require_resolved_config CONFIG_MFD_RK8XX_I2C=y CONFIG_MFD_RK8XX_I2C
require_resolved_config CONFIG_ROCKCHIP_SUSPEND_MODE=y CONFIG_ROCKCHIP_SUSPEND_MODE
require_source_line arch/arm64/configs/pinenote_defconfig '# CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE is not set' 'hard-off activation config'
reject_resolved_config_enabled CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE

require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts 'model = "Pine64 PineNote v1.2"' 'PineNote v1.2 model'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts 'compatible = "pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"' 'PineNote compatibility'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '&ebc {' 'EBC node'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "ti,tps65185"' 'EBC PMIC'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "pine64,pinenote-ws8100-pen"' 'WS8100 pen'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "wacom,w9013", "hid-over-i2c"' 'Wacom pen HID'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'battery: battery {' 'PineNote battery node'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "simple-battery"' simple-battery
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'charge-full-design-microamp-hours = <4000000>' 'battery design capacity'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'charge-term-current-microamp = <300000>' 'battery termination current'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'constant-charge-current-max-microamp = <2000000>' 'battery maximum charge current'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'constant-charge-voltage-max-microvolt = <4200000>' 'battery maximum charge voltage'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'factory-internal-resistance-micro-ohms = <96000>' 'battery internal resistance'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'voltage-max-design-microvolt = <4200000>' 'battery design maximum voltage'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'voltage-min-design-microvolt = <3500000>' 'battery design minimum voltage'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'ocv-capacity-celsius = <20>' 'battery OCV temperature'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<4168000 100>, <4109000 95>, <4066000 90>, <4023000 85>,' 'battery OCV table first row'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<3985000 80>, <3954000 75>, <3924000 70>, <3897000 65>,' 'battery OCV table second row'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<3866000 60>, <3826000 55>, <3804000 50>, <3789000 45>,' 'battery OCV table third row'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<3777000 40>, <3770000 35>, <3763000 30>, <3750000 25>,' 'battery OCV table fourth row'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<3732000 20>, <3710000 15>, <3680000 10>, <3670000  5>,' 'battery OCV table fifth row'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '<3500000  0>;' 'battery OCV table final pair'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'monitored-battery = <&battery>' 'RK817 monitored battery relationship'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'rockchip,resistor-sense-micro-ohms = <10000>' 'RK817 sense resistor'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'rockchip,sleep-enter-current-microamp = <150000>' 'RK817 sleep-enter current'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'rockchip,sleep-filter-current-microamp = <100000>' 'RK817 sleep-filter current'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'rockchip-suspend {' 'probe-only Rockchip suspend node'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "rockchip,pm-rk3568"' 'probe-only Rockchip suspend compatible'
if ! sh "$rockchip_pm_validator" "$rockchip_pm_check" "$rockchip_pm_patch" "$source_dir"; then
  fail "authoritative Rockchip PM patch/source validation failed"
fi
pass "authoritative Rockchip PM patch/source validation passed"
require_source_line include/soc/rockchip/rockchip_sip.h '#define ROCKCHIP_SLEEP_PD_CONFIG		0xff' 'modern 0xff power-domain control definition'
require_contains drivers/pmdomain/rockchip/pm-domains.c 'ROCKCHIP_SLEEP_PD_CONFIG,' 'existing modern 0xff power-domain SIP path'

warn "kernel source inspection does not build the kernel or prove PineNote hardware boot"
pass "kernel source preflight inspection completed"
