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

printf '%s\n' "$extlinux_config" | grep -q 'root=LABEL=PNGuixRoot' || \
  fail "embedded extlinux.conf does not use root=LABEL=PNGuixRoot"
pass "embedded extlinux.conf uses root=LABEL=PNGuixRoot"

if printf '%s\n' "$extlinux_config" | grep -q 'root=/dev/mmcblk'; then
  fail "embedded extlinux.conf contains forbidden root=/dev/mmcblk path"
fi
pass "embedded extlinux.conf avoids root=/dev/mmcblk"

sha256sum "$rootfs_image"
