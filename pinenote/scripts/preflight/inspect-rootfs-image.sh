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

for required in /boot/Image /boot/rk3566-pinenote-v1.2.dtb /boot/initrd.cpio.gz; do
  debugfs -R "stat $required" "$rootfs_image" >/dev/null 2>&1 || \
    fail "missing embedded boot payload: $required"
  pass "found embedded boot payload $required"
done

sha256sum "$rootfs_image"
