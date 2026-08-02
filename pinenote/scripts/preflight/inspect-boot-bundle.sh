#!/bin/sh
set -eu

usage() {
  printf 'usage: %s BOOT_BUNDLE_DIRECTORY\n' "$0" >&2
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

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

bundle=$1

if [ ! -d "$bundle" ]; then
  fail "bundle path is not a directory: $bundle"
fi

find_file() {
  name=$1
  if [ -f "$bundle/$name" ]; then
    printf '%s\n' "$bundle/$name"
    return 0
  fi
  if [ -f "$bundle/extlinux/$name" ]; then
    printf '%s\n' "$bundle/extlinux/$name"
    return 0
  fi
  return 1
}

image=$(find_file Image || true)
if [ -z "$image" ]; then
  image_gz=$(find_file Image.gz || true)
  if [ -n "$image_gz" ]; then
    fail "found Image.gz but no uncompressed Image; PineNote extlinux reference expects Image"
  fi
  fail "missing Image"
fi
pass "found Image at $image"

config=$(find_file config || true)
if [ -z "$config" ]; then
  fail "missing resolved kernel config"
fi
pass "found resolved kernel config at $config"
if ! grep -F -x -q -- 'CONFIG_ROCKCHIP_SUSPEND_MODE=y' "$config"; then
  fail "resolved kernel config lacks dormant Rockchip suspend model"
fi
if ! grep -F -x -q -- 'CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y' "$config"; then
  fail "resolved kernel config lacks Rockchip suspend activation (deep will not wake)"
fi
pass "resolved kernel config enables reviewed Rockchip suspend activation"

dtb_count=0
for candidate in "$bundle"/rk3566-pinenote*.dtb "$bundle"/extlinux/rk3566-pinenote*.dtb; do
  if [ -f "$candidate" ]; then
    dtb_count=$((dtb_count + 1))
    pass "found PineNote DTB at $candidate"
  fi
done
if [ "$dtb_count" -eq 0 ]; then
  fail "missing rk3566-pinenote*.dtb"
fi

initrd=$(find_file uInitrd.img || true)
if [ -z "$initrd" ]; then
  initrd=$(find_file initrd || true)
fi
if [ -z "$initrd" ]; then
  initrd=$(find_file initrd.cpio.gz || true)
fi
if [ -z "$initrd" ]; then
  fail "missing uInitrd.img or documented initrd file"
fi
pass "found initrd at $initrd"

extlinux=$(find_file extlinux.conf || true)
if [ -z "$extlinux" ]; then
  fail "missing extlinux.conf"
fi
pass "found extlinux.conf at $extlinux"

if grep -q 'root=PNGuixRoot' "$extlinux"; then
  pass "extlinux.conf uses root=PNGuixRoot"
else
  fail "extlinux.conf does not use root=PNGuixRoot"
fi

if grep -q 'root=/dev/mmcblk' "$extlinux"; then
  fail "extlinux.conf contains forbidden root=/dev/mmcblk path"
fi
pass "extlinux.conf avoids root=/dev/mmcblk"

for forbidden in \
  'rkdeveloptool' \
  'fw_setenv' \
  'write-partition' \
  'saveenv' \
  'of=/dev/' \
  'repartition'; do
  set +e
  matches=$(find "$bundle" -type f -exec sh -c '
    forbidden=$1
    shift
    for file do
      if grep -q -- "$forbidden" "$file"; then
        printf "%s\n" "$file"
      else
        status=$?
        if [ "$status" -ne 1 ]; then
          exit "$status"
        fi
      fi
    done
  ' sh "$forbidden" {} +)
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    fail "error while scanning bundle for forbidden string: $forbidden"
  fi
  if [ -n "$matches" ]; then
    fail "bundle contains forbidden deployment string: $forbidden"
  fi
done
pass "no forbidden deployment strings found"

warn "static inspection cannot prove PineNote bootloader, panel, EBC, or waveform behavior"
pass "boot bundle preflight inspection complete"
