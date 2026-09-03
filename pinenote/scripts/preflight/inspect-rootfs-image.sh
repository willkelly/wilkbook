#!/bin/sh
set -eu

usage() {
  printf 'usage: %s ROOTFS_IMAGE\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

image_stat() {
  debugfs -R "stat $1" "$rootfs_image" 2>/dev/null
}

require_image_path() {
  path=$1
  description=$2
  output=$(image_stat "$path") || fail "could not inspect $description: $path"
  printf '%s\n' "$output" | grep -q '^Inode:' || fail "missing $description: $path"
  pass "found $description $path"
}

symlink_target() {
  image_stat "$1" | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p'
}

unique_store_path() {
  pattern=$1
  description=$2
  matches=$(printf '%s\n' "$store_listing" | awk '{ print $NF }' | grep -- "$pattern" || true)
  count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)
  [ "$count" -eq 1 ] || \
    fail "expected exactly one $description in the image store, found $count"
  printf '/gnu/store/%s\n' "$matches"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

rootfs_image=$1

if [ ! -f "$rootfs_image" ]; then
  fail "rootfs image is not a regular file: $rootfs_image"
fi

description=$(file "$rootfs_image")
case $description in
  *DOS/MBR* | *partition*)
    fail "rootfs image still looks like a partitioned disk: $description"
    ;;
esac
printf '%s\n' "$description"

if partx -g "$rootfs_image" >/dev/null 2>&1; then
  fail "rootfs image has a readable partition table"
fi
pass "no partition table detected"

tune2fs_output=$(tune2fs -l "$rootfs_image") || \
  fail "tune2fs could not read an ext filesystem"

printf '%s\n' "$tune2fs_output" | grep -q '^Filesystem volume name:[[:space:]]*PNGuixRoot$' || \
  fail "filesystem label is not PNGuixRoot"
pass "filesystem label is PNGuixRoot"

printf '%s\n' "$tune2fs_output" | grep -q '^Filesystem features:' || \
  fail "missing ext filesystem feature listing"
pass "ext filesystem metadata is readable"

extlinux_config=$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$rootfs_image" 2>/dev/null) || \
  fail "could not read /boot/extlinux/extlinux.conf"

printf '%s\n' "$extlinux_config" | grep -q 'root=PNGuixRoot' || \
  fail "embedded extlinux.conf does not use root=PNGuixRoot"
pass "embedded extlinux.conf uses root=PNGuixRoot"

if printf '%s\n' "$extlinux_config" | grep -q 'root=/dev/mmcblk'; then
  fail "embedded extlinux.conf contains forbidden root=/dev/mmcblk path"
fi
pass "embedded extlinux.conf avoids root=/dev/mmcblk"

printf '%s\n' "$extlinux_config" | grep -q '^[[:space:]]*KERNEL[[:space:]][[:space:]]*/boot/Image$' || \
  fail "embedded extlinux.conf does not use KERNEL /boot/Image"
pass "embedded extlinux.conf uses KERNEL /boot/Image"

printf '%s\n' "$extlinux_config" | grep -q '^[[:space:]]*FDT[[:space:]][[:space:]]*/boot/rk3566-pinenote-v1.2.dtb$' || \
  fail "embedded extlinux.conf does not use FDT /boot/rk3566-pinenote-v1.2.dtb"
pass "embedded extlinux.conf uses FDT /boot/rk3566-pinenote-v1.2.dtb"

printf '%s\n' "$extlinux_config" | grep -q '^[[:space:]]*INITRD[[:space:]][[:space:]]*/boot/initrd.cpio.gz$' || \
  fail "embedded extlinux.conf does not use INITRD /boot/initrd.cpio.gz"
pass "embedded extlinux.conf uses INITRD /boot/initrd.cpio.gz"

for required in /boot/Image /boot/config /boot/rk3566-pinenote-v1.2.dtb /boot/initrd.cpio.gz; do
  require_image_path "$required" "embedded boot payload"
done

profile_link=$(symlink_target /var/guix/profiles/system)
case "$profile_link" in
  system-*-link) ;;
  *) fail "persistent system profile has invalid generation link: $profile_link" ;;
esac
system_store=$(symlink_target "/var/guix/profiles/$profile_link")
case "$system_store" in
  /gnu/store/*-system) ;;
  *) fail "persistent system generation has invalid store target: $system_store" ;;
esac
store_listing=$(debugfs -R 'ls -l /gnu/store' "$rootfs_image" 2>/dev/null) || \
  fail "could not list the image's Guix store"
require_image_path "$system_store/profile/bin/pinenote-wifi-control" \
  "packaged PineNote Wi-Fi control"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/inspect-rootfs-image.XXXXXX") || \
  fail "could not create temporary inspection directory"
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

debugfs -R "dump /boot/config $tmpdir/kernel-config" "$rootfs_image" >/dev/null 2>&1 || \
  fail "could not extract embedded kernel config"
grep -F -x -q -- 'CONFIG_ROCKCHIP_SUSPEND_MODE=y' "$tmpdir/kernel-config" || \
  fail "embedded kernel config lacks dormant Rockchip suspend model"
if ! grep -F -x -q -- 'CONFIG_ROCKCHIP_SUSPEND_MODE_ACTIVATE=y' "$tmpdir/kernel-config"; then
  fail "embedded kernel config lacks Rockchip suspend activation (deep will not wake)"
fi
pass "embedded kernel config enables reviewed Rockchip suspend activation"
for symbol in CONFIG_KEXEC=y CONFIG_KEXEC_FILE=y; do
  grep -F -x -q -- "$symbol" "$tmpdir/kernel-config" || \
    fail "embedded kernel config lacks $symbol (the update path's trial boot needs kexec)"
done
pass "embedded kernel config enables kexec (update path)"
require_image_path "$system_store/profile/sbin/kexec" "packaged kexec-tools"
require_image_path "$system_store/profile/bin/guix" "packaged guix (store importer for guix copy)"
require_image_path "$system_store/profile/bin/wilkbook-generation" "packaged generation helper (update path)"


debugfs -R "dump $system_store/profile/bin/pinenote-wifi-control $tmpdir/wifi-link" \
  "$rootfs_image" >/dev/null 2>&1 || fail "could not resolve packaged PineNote Wi-Fi control"
wifi_target=$(tr -d '\n' <"$tmpdir/wifi-link")
case "$wifi_target" in
  /gnu/store/*-pinenote-platform-controls-*/bin/pinenote-wifi-control) ;;
  *) fail "packaged PineNote Wi-Fi control has invalid target: $wifi_target" ;;
esac
platform_controls_store=${wifi_target%/bin/pinenote-wifi-control}
require_image_path "$wifi_target" "packaged PineNote Wi-Fi executable"
require_image_path "$platform_controls_store/share/pinenote-platform-controls/pinenote-power-broker.lua" \
  "packaged suspend broker"
require_image_path "$platform_controls_store/share/pinenote-platform-controls/broker_protocol.lua" \
  "packaged suspend broker protocol"
require_image_path "$platform_controls_store/share/pinenote-platform-controls/broker_quiesce.lua" \
  "packaged suspend broker EBC quiesce"

platform_service=$(unique_store_path \
  '-shepherd-pinenote-platform-controls\.scm$' \
  "generated pinenote-platform-controls Shepherd service")
for svc in guix-daemon pinenote-grow-root pinenote-guix-acl; do
  unique_store_path "-shepherd-$svc\.scm\$" "generated $svc Shepherd service" >/dev/null
done
pass "generated guix-daemon, grow-root and guix-acl services are present (update path)"
reader_service=$(unique_store_path \
  '-shepherd-reader-session\.scm$' \
  "generated reader-session Shepherd service")
if printf '%s\n' "$store_listing" | awk '{ print $NF }' | \
     grep -q -- '-shepherd-pinenote-autosuspend\.scm$'; then
  fail "legacy pinenote-autosuspend Shepherd service is present in the reader image"
fi
pass "legacy pinenote-autosuspend Shepherd service is absent"

debugfs -R "dump $platform_service $tmpdir/platform-service.scm" \
  "$rootfs_image" >/dev/null 2>&1 || fail "could not extract generated platform-controls service"
debugfs -R "dump $reader_service $tmpdir/reader-service.scm" \
  "$rootfs_image" >/dev/null 2>&1 || fail "could not extract generated reader-session service"

for token in \
  '(quote (pinenote-platform-controls))' \
  '#:respawn? (quote #t)' \
  '/var/log/pinenote-platform-controls.log' \
  'WILKBOOK_KOREADER_ROOT=' \
  'WILKBOOK_WIFI_CONTROL=' \
  'pinenote-power-broker.lua' \
  'uinput'; do
  grep -F -q -- "$token" "$tmpdir/platform-service.scm" || \
    fail "generated platform-controls service lacks required token: $token"
done
pass "generated platform-controls service supervises the packaged broker"

for token in \
  'pinenote-platform-controls' \
  '/run/wilkbook-power/ready' \
  'wilkbook-power-control' \
  'pinenote-platform-controls did not become ready'; do
  grep -F -q -- "$token" "$tmpdir/reader-service.scm" || \
    fail "generated reader-session service lacks Phase 2 token: $token"
done
pass "generated reader-session waits for the platform-controls service and input device"

debugfs -R "dump $system_store/profile/bin/koreader $tmpdir/koreader-link" \
  "$rootfs_image" >/dev/null 2>&1 || fail "could not resolve packaged KOReader"
koreader_target=$(tr -d '\n' <"$tmpdir/koreader-link")
case "$koreader_target" in
  /gnu/store/*-koreader-bin-*/bin/koreader) ;;
  *) fail "packaged KOReader has invalid target: $koreader_target" ;;
esac
koreader_store=${koreader_target%/bin/koreader}
pinenote_lua="$koreader_store/lib/koreader/frontend/device/pinenote"
for module in ebc_barrier.lua ebc_sleep_frame.lua power_capabilities.lua power_coordinator.lua; do
  require_image_path "$pinenote_lua/$module" "dormant PineNote module"
done

for file in suspend_policy.lua device.lua; do
  debugfs -R "dump $pinenote_lua/$file $tmpdir/$file" "$rootfs_image" >/dev/null 2>&1 || \
    fail "could not extract packaged PineNote $file"
done
policy_hash=$(sha256sum "$tmpdir/suspend_policy.lua")
case "$policy_hash" in
  25712167ce722b4ee26628e97f0cb8f344b8449288a27bf9a131a9f59f5183b7\ *) ;;
  *) fail "packaged suspend policy is not exactly disabled" ;;
esac
pass "packaged suspend policy is exactly disabled"

for module in ebc_barrier ebc_sleep_frame power_capabilities power_coordinator; do
  if grep -F -q -- "device/pinenote/$module" "$tmpdir/device.lua"; then
    fail "packaged production device references dormant module $module"
  fi
done
pass "packaged production device references no dormant power module"

for token in \
  'wilkbook-power-control' \
  '/run/wilkbook-power/request' \
  '/run/current-system/profile/bin/pinenote-wifi-control' \
  'canSuspend = suspend_qualified and yes or no'; do
  grep -F -q -- "$token" "$tmpdir/device.lua" || \
    fail "packaged production device lacks Phase 2 token: $token"
done
if grep -F -q -- 'WILKBOOK_PINENOTE_VALIDATION' "$tmpdir/device.lua"; then
  fail "packaged production device still consumes the Phase 1 validation gate"
fi
pass "packaged production device uses the acknowledged broker and packaged Wi-Fi helper"

sha256sum "$rootfs_image"
