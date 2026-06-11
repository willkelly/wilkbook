#!/bin/sh
# Build a synthetic GPT disk that mimics the PineNote layout closely enough
# for the initrd's first-boot logic: a 2 MiB partition GPT-named "waveform"
# (found via /sys/class/block uevent PARTNAME scanning) and a partition
# carrying the extracted PNGuixRoot rootfs (found by filesystem label).
# Host-side only; writes nothing outside /tmp/opencode.
set -eu

usage() {
  printf 'usage: %s ROOTFS_IMAGE DISK_IMAGE [WAVEFORM_FILE]\n' "$0" >&2
  printf 'DISK_IMAGE must resolve under /tmp/opencode.\n' >&2
  printf 'Without WAVEFORM_FILE the waveform partition is zero-filled,\n' >&2
  printf 'which exercises the initrd copy path but not real waveform data.\n' >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }

rootfs=$1
disk=$2
waveform=${3:-}

command -v sgdisk >/dev/null 2>&1 || \
  fail "sgdisk not found; run via: guix shell gptfdisk -- $0 ..."

[ -f "$rootfs" ] || fail "rootfs image is not a regular file: $rootfs"
if [ -n "$waveform" ]; then
  [ -f "$waveform" ] || fail "waveform file is not a regular file: $waveform"
fi

opencode_root=$(CDPATH= cd -P /tmp/opencode && pwd -P) || \
  fail "cannot resolve /tmp/opencode"
disk_parent=$(CDPATH= cd -P "$(dirname "$disk")" && pwd -P) || \
  fail "disk image parent does not exist"
disk=$disk_parent/$(basename "$disk")
case $disk in
  "$opencode_root"/*) ;;
  *) fail "disk image must resolve under $opencode_root" ;;
esac

rootfs_bytes=$(wc -c < "$rootfs")

# Layout (512-byte sectors):
#   2048..6143      2 MiB partition named "waveform"
#   8192..+rootfs   rootfs partition named "os2", PNGuixRoot inside
root_start=8192
root_sectors=$(( (rootfs_bytes + 511) / 512 ))
root_end=$(( root_start + root_sectors - 1 ))
# Slack for the GPT backup header at the end of the disk.
disk_sectors=$(( root_end + 2048 ))

rm -f -- "$disk"
truncate -s $(( disk_sectors * 512 )) "$disk"

sgdisk --clear \
  --new=1:2048:6143 --typecode=1:8300 --change-name=1:waveform \
  --new=2:${root_start}:${root_end} --typecode=2:8300 --change-name=2:os2 \
  "$disk" >/dev/null

if [ -n "$waveform" ]; then
  dd if="$waveform" of="$disk" bs=512 seek=2048 count=4096 \
     conv=notrunc status=none
  pass "waveform partition filled from $waveform (first 2 MiB)"
else
  pass "waveform partition left zero-filled (copy-path test only)"
fi

dd if="$rootfs" of="$disk" bs=512 seek=$root_start conv=notrunc status=none
pass "rootfs written into partition 2 (GPT name os2)"
pass "synthetic PineNote-layout disk ready: $disk"
