#!/bin/sh
set -eu

usage() {
  printf 'usage: %s [TEMP_DIRECTORY]\n' "$0" >&2
  printf 'optional env: PINENOTE_FIRMWARE_SUPPORT PINENOTE_DIAGNOSTICS PINENOTE_EBC_TEST\n' >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

note() {
  printf 'NOTE: %s\n' "$1"
}

resolve_directory() {
  directory=$1
  (CDPATH= cd -P "$directory" && pwd -P)
}

require_inside_opencode() {
  path=$1
  case $path in
    "$opencode_root"/*) ;;
    *) fail "temporary directory must resolve under $opencode_root" ;;
  esac
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

opencode_root=$(resolve_directory /tmp/opencode) || fail "cannot resolve /tmp/opencode"

if [ "$#" -eq 1 ]; then
  requested_root=$1
  parent=$(dirname "$requested_root")
  basename=$(basename "$requested_root")

  case $basename in
    ''|'.'|'..') fail "temporary directory basename is unsafe: $basename" ;;
  esac

  parent_root=$(resolve_directory "$parent") || fail "temporary directory parent does not exist: $parent"
  intended_root=$parent_root/$basename
  require_inside_opencode "$intended_root"

  if [ -e "$intended_root" ]; then
    if [ ! -d "$intended_root" ]; then
      fail "temporary directory exists but is not a directory: $intended_root"
    fi
    temp_root=$(resolve_directory "$intended_root") || fail "cannot resolve temporary directory: $intended_root"
    require_inside_opencode "$temp_root"
  else
    temp_root=$intended_root
  fi
else
  temp_root=$(mktemp -d "$opencode_root/pinenote-preflight.XXXXXX")
  temp_root=$(resolve_directory "$temp_root") || fail "cannot resolve temporary directory: $temp_root"
  require_inside_opencode "$temp_root"
fi

mkdir -p -- "$temp_root"
fixture=$temp_root/fixture

if [ -e "$fixture" ] || [ -L "$fixture" ]; then
  fail "fixture path already exists; refusing to reuse it: $fixture"
fi

mkdir -- "$fixture"
resolved_fixture=$(resolve_directory "$fixture") || fail "cannot resolve fixture path: $fixture"
require_inside_opencode "$resolved_fixture"

mkdir -- "$fixture/state"
mkdir -- "$fixture/state/firmware"
mkdir -- "$fixture/output"
printf 'mock waveform fixture\n' > "$fixture/state/firmware/ebc.wbf"
pass "created temporary fixtures under $temp_root"

firmware_support=${PINENOTE_FIRMWARE_SUPPORT:-}
diagnostics=${PINENOTE_DIAGNOSTICS:-}
ebc_test=${PINENOTE_EBC_TEST:-}

if [ -z "$firmware_support" ] || [ -z "$diagnostics" ] || [ -z "$ebc_test" ]; then
  note "store paths were not fully supplied; build them before a full helper check:"
  note "guix build -L . pinenote-firmware-support --target=aarch64-linux-gnu"
  note "guix build -L . pinenote-diagnostics --target=aarch64-linux-gnu"
  note "guix build -L . pinenote-ebc-test --target=aarch64-linux-gnu"
  note "then rerun with PINENOTE_FIRMWARE_SUPPORT, PINENOTE_DIAGNOSTICS, and PINENOTE_EBC_TEST"
  pass "mock preflight stopped before touching package helpers"
  exit 0
fi

waveform_helper=$firmware_support/bin/pinenote-install-waveform
brcm_helper=$firmware_support/bin/pinenote-install-brcm-firmware
params_helper=$firmware_support/bin/pinenote-apply-ebc-params
diagnostics_helper=$diagnostics/bin/pinenote-diagnostics
ebc_test_helper=$ebc_test/bin/pinenote-ebc-test

for helper in "$waveform_helper" "$brcm_helper" "$params_helper" "$diagnostics_helper" "$ebc_test_helper"; do
  if [ ! -x "$helper" ]; then
    fail "missing executable helper: $helper"
  fi
done
pass "all supplied helper paths are executable"

if grep -q '/lib/firmware/rockchip/ebc.wbf' "$waveform_helper"; then
  pass "waveform helper documents the real firmware destination"
else
  fail "waveform helper does not mention expected firmware destination"
fi

if grep -q '/sys/module/rockchip_ebc/parameters' "$params_helper"; then
  pass "parameter helper documents the real EBC sysfs parameter path"
else
  fail "parameter helper does not mention expected EBC sysfs parameter path"
fi

if grep -q '/lib/firmware/brcm' "$brcm_helper"; then
  pass "Broadcom helper documents the real brcm firmware destination"
else
  fail "Broadcom helper does not mention expected brcm firmware destination"
fi

note "not executing waveform or parameter helpers because they target real /lib and /sys paths"

"$diagnostics_helper" > "$fixture/output/diagnostics.out"
pass "ran read-only diagnostics helper on host"

"$ebc_test_helper" > "$fixture/output/ebc-test.out"
pass "ran read-only EBC test helper on host"

if grep -q 'No framebuffer, DRM, EBC, partition, or bootloader writes are performed.' "$fixture/output/ebc-test.out"; then
  pass "EBC test helper reports non-destructive behavior"
else
  fail "EBC test helper did not report non-destructive behavior"
fi

pass "mock PineNote service preflight complete"
