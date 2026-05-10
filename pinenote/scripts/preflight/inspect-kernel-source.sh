#!/bin/sh
set -eu

expected_commit=6bf9085fb0a7c44ca7e6b92eeedfef817bd7d931

usage() {
  printf 'usage: %s KERNEL_SOURCE_DIRECTORY\n' "$0" >&2
  printf 'optional env: PINENOTE_KERNEL_ALLOW_DIFFERENT_COMMIT=1\n' >&2
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

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

source_dir=$1

if [ ! -d "$source_dir" ]; then
  fail "kernel source path is not a directory: $source_dir"
fi

if git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  current_commit=$(git -C "$source_dir" rev-parse HEAD)
  note "git commit: $current_commit"
  if [ "$current_commit" = "$expected_commit" ]; then
    pass "kernel source commit matches pinned PineNote reference"
  elif [ "${PINENOTE_KERNEL_ALLOW_DIFFERENT_COMMIT:-}" = 1 ]; then
    warn "kernel source commit differs from pinned reference: expected $expected_commit"
  else
    fail "kernel source commit differs from pinned reference: expected $expected_commit"
  fi
else
  warn "kernel source path is not a git checkout; commit identity was not verified"
fi

require_file arch/arm64/configs/pinenote_defconfig
require_file arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts
require_file arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi
require_file drivers/gpu/drm/rockchip/rockchip_ebc.c

require_contains arch/arm64/configs/pinenote_defconfig CONFIG_DRM_ROCKCHIP_EBC=m CONFIG_DRM_ROCKCHIP_EBC
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_REGULATOR_TPS65185=m CONFIG_REGULATOR_TPS65185
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_TOUCHSCREEN_CYTTSP5=m CONFIG_TOUCHSCREEN_CYTTSP5
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_BRCMFMAC=m CONFIG_BRCMFMAC
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_I2C_HID_OF=m CONFIG_I2C_HID_OF
require_contains arch/arm64/configs/pinenote_defconfig CONFIG_MMC_DW_ROCKCHIP=y CONFIG_MMC_DW_ROCKCHIP

require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts 'model = "Pine64 PineNote v1.2"' 'PineNote v1.2 model'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote-v1.2.dts 'compatible = "pine64,pinenote-v1.2", "pine64,pinenote", "rockchip,rk3566"' 'PineNote compatibility'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi '&ebc {' 'EBC node'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "ti,tps65185"' 'EBC PMIC'
require_contains arch/arm64/boot/dts/rockchip/rk3566-pinenote.dtsi 'compatible = "wacom,w9013", "hid-over-i2c"' 'Wacom pen HID'

warn "kernel source inspection does not build the kernel or prove PineNote hardware boot"
pass "kernel source preflight inspection completed"
