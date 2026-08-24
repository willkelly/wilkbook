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

normalize_append_root() {
  append=$1
  normalized=
  found=false

  for argument in $append; do
    case $argument in
      root=*)
        argument=root=PNGuixRoot
        found=true
        ;;
    esac
    normalized=${normalized:+$normalized }$argument
  done

  if [ "$found" != true ]; then
    fail "source APPEND arguments lack root=; refusing ambiguous boot args"
  fi

  printf '%s\n' "$normalized"
}

normalize_extlinux_root() {
  extlinux_config=$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$rootfs_image" 2>/dev/null) || \
    fail "could not read /boot/extlinux/extlinux.conf from extracted rootfs"

  kernel_path=$(extract_first_field KERNEL "$extlinux_config")
  if [ -z "$kernel_path" ]; then
    kernel_path=$(extract_first_field LINUX "$extlinux_config")
  fi
  initrd_path=$(extract_first_field INITRD "$extlinux_config")
  fdt_path=$(extract_first_field FDT "$extlinux_config")
  fdt_dir=$(extract_first_field FDTDIR "$extlinux_config")
  append_args=$(extract_first_field APPEND "$extlinux_config")

  if [ -z "$kernel_path" ]; then
    fail "source extlinux.conf does not name KERNEL or LINUX"
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

  append_args=$(normalize_append_root "$append_args")

  normalized_extlinux=$(mktemp /tmp/wilkbook/pinenote-extlinux.XXXXXX)
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

if [ -e "$rootfs_image" ] || [ -L "$rootfs_image" ]; then
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

linux_partition_table=$(printf '%s\n' "$partition_table" | awk '$3 == "0x83" { print }')
linux_partition_count=$(printf '%s\n' "$linux_partition_table" | sed '/^[[:space:]]*$/d' | wc -l)
if [ "$linux_partition_count" -ne 1 ]; then
  fail "expected exactly one Linux root partition, found $linux_partition_count"
fi

set -- $linux_partition_table
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
script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
"$script_dir/embed-static-boot-in-rootfs.sh" "$rootfs_image" >/dev/null

pass "extracted rootfs image to $rootfs_image"
pass "filesystem label set to PNGuixRoot"
pass "embedded extlinux.conf uses root=PNGuixRoot and short /boot paths"
pass "start sector: $start_sector"
pass "sector count: $sector_count"
sha256sum "$rootfs_image"
