#!/bin/sh
set -eu

usage() {
  printf 'usage: %s RAW_DISK_IMAGE OUTPUT_ROOTFS_IMAGE\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

extract_first_field() {
  field=$1
  config=$2
  printf '%s\n' "$config" | sed -n "s/^[[:space:]]*$field[[:space:]][[:space:]]*//p" | sed -n '1p'
}

normalize_extlinux_root() {
  extlinux_config=$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$rootfs_image" 2>/dev/null) || \
    fail "could not read /boot/extlinux/extlinux.conf from extracted rootfs"

  kernel_path=$(extract_first_field KERNEL "$extlinux_config")
  initrd_path=$(extract_first_field INITRD "$extlinux_config")
  fdt_path=$(extract_first_field FDT "$extlinux_config")
  fdt_dir=$(extract_first_field FDTDIR "$extlinux_config")
  append_args=$(extract_first_field APPEND "$extlinux_config")

  if [ -z "$kernel_path" ]; then
    fail "source extlinux.conf does not name KERNEL"
  fi
  if [ -z "$initrd_path" ]; then
    fail "source extlinux.conf does not name INITRD"
  fi
  if [ -z "$fdt_path" ] && [ -z "$fdt_dir" ]; then
    fail "source extlinux.conf does not name FDT or FDTDIR"
  fi
  if [ -z "$append_args" ]; then
    fail "source extlinux.conf does not name APPEND arguments"
  fi

  case " $append_args " in
    *' gnu.system='*) ;;
    *) fail "source APPEND arguments lack gnu.system=; refusing mismatched Guix boot args" ;;
  esac

  case " $append_args " in
    *' gnu.load='*) ;;
    *) fail "source APPEND arguments lack gnu.load=; refusing mismatched Guix boot args" ;;
  esac

  case " $append_args " in
    *' root=/dev/mmcblk'*) fail "source APPEND arguments contain forbidden raw eMMC root path" ;;
  esac

  append_args=$(printf '%s\n' "$append_args" | \
    sed 's/\(^\|[[:space:]]\)root=[^[:space:]]*/ root=LABEL=PNGuixRoot/' | \
    sed 's/^[[:space:]]*//')

  normalized_extlinux=$(mktemp /tmp/opencode/pinenote-extlinux.XXXXXX)
  {
    printf '%s\n' '# Generated from Guix image output for PineNote Gate 6 preflight.'
    printf '%s\n' '# Do not persist U-Boot environment changes when using this entry.'
    printf '%s\n' 'LABEL pinenote-guix-preflight'
    printf '%s\n' '  MENU LABEL Guix PineNote slim preflight'
    printf '  KERNEL %s\n' "$kernel_path"
    if [ -n "$fdt_path" ]; then
      printf '  FDT %s\n' "$fdt_path"
    else
      printf '  FDTDIR %s\n' "$fdt_dir"
    fi
    printf '  INITRD %s\n' "$initrd_path"
    printf '  APPEND %s\n' "$append_args"
  } > "$normalized_extlinux"

  debugfs -w -R 'rm /boot/extlinux/extlinux.conf' "$rootfs_image" >/dev/null 2>&1 || \
    fail "could not remove source extlinux.conf from extracted rootfs"
  debugfs -w -R "write $normalized_extlinux /boot/extlinux/extlinux.conf" \
    "$rootfs_image" >/dev/null 2>&1 || \
    fail "could not write normalized extlinux.conf into extracted rootfs"
  rm -f "$normalized_extlinux"
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

raw_image=$1
rootfs_image=$2

if [ ! -f "$raw_image" ]; then
  fail "raw image is not a regular file: $raw_image"
fi

if [ -e "$rootfs_image" ]; then
  fail "output already exists: $rootfs_image"
fi

if [ -b "$rootfs_image" ]; then
  fail "refusing block-device output: $rootfs_image"
fi

output_parent=$(dirname "$rootfs_image")
if [ ! -d "$output_parent" ]; then
  fail "output parent directory does not exist: $output_parent"
fi

partition_table=$(partx -g -o START,SECTORS,TYPE "$raw_image") || \
  fail "could not read raw image partition table"

partition_count=$(printf '%s\n' "$partition_table" | sed '/^[[:space:]]*$/d' | wc -l)
if [ "$partition_count" -ne 1 ]; then
  fail "expected exactly one partition, found $partition_count"
fi

set -- $partition_table
start_sector=$1
sector_count=$2
partition_type=$3

if [ "$partition_type" != "0x83" ]; then
  fail "expected Linux partition type 0x83, found $partition_type"
fi

case $start_sector:$sector_count in
  *[!0123456789:]* | :* | *:)
    fail "invalid partition geometry: start=$start_sector sectors=$sector_count"
    ;;
esac

dd if="$raw_image" of="$rootfs_image" bs=512 skip="$start_sector" \
  count="$sector_count" status=none
e2label "$rootfs_image" PNGuixRoot
normalize_extlinux_root

pass "extracted rootfs image to $rootfs_image"
pass "filesystem label set to PNGuixRoot"
pass "embedded extlinux.conf uses root=LABEL=PNGuixRoot"
pass "start sector: $start_sector"
pass "sector count: $sector_count"
sha256sum "$rootfs_image"
