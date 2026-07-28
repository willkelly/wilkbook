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

validate_source_path() {
  path=$1
  description=$2

  case $path in
    /*) ;;
    *) fail "$description path is not absolute: $path" ;;
  esac

  if printf '%s' "$path" | grep -q '[[:space:][:cntrl:]]'; then
    fail "$description path contains whitespace or control characters: $path"
  fi

  case $path in
    *..* | *\;* | *\|* | *\&* | *\`* | *\$* | *\(* | *\)* | *\<* | *\>* | *\\* | *\"*)
      fail "$description path contains unsafe characters: $path"
      ;;
  esac

  case $path in
    /gnu/store/* | /boot/Image | /boot/initrd.cpio.gz | /boot/rk3566-pinenote-v1.2.dtb) ;;
    *) fail "$description path is outside the allowed boot payload paths: $path" ;;
  esac
}

dump_rootfs_file() {
  source=$1
  target=$2
  debugfs -R "dump $source $target" "$rootfs_image" >/dev/null 2>&1 || \
    fail "could not extract $source from $rootfs_image"
  if [ ! -f "$target" ]; then
    fail "debugfs did not create expected file: $target"
  fi
}

replace_rootfs_file() {
  source=$1
  target=$2
  debugfs -w -R "rm $target" "$rootfs_image" >/dev/null 2>&1 || true
  debugfs -w -R "write $source $target" "$rootfs_image" >/dev/null 2>&1 || \
    fail "could not write $target into $rootfs_image"
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

rootfs_image=$1

if [ ! -f "$rootfs_image" ]; then
  fail "rootfs image is not a regular file: $rootfs_image"
fi
if [ -b "$rootfs_image" ]; then
  fail "refusing block-device input: $rootfs_image"
fi

tune2fs -l "$rootfs_image" >/dev/null 2>&1 || \
  fail "tune2fs could not read an ext filesystem"

extlinux_config=$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$rootfs_image" 2>/dev/null) || \
  fail "could not read /boot/extlinux/extlinux.conf from rootfs"

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
if [ -z "$fdt_path" ]; then
  if [ -z "$fdt_dir" ]; then
    fail "source extlinux.conf does not name FDT or FDTDIR"
  fi
  fdt_path=$fdt_dir/rockchip/rk3566-pinenote-v1.2.dtb
fi
if [ -z "$append_args" ]; then
  fail "source extlinux.conf does not name APPEND arguments"
fi

validate_source_path "$kernel_path" KERNEL
validate_source_path "$initrd_path" INITRD
validate_source_path "$fdt_path" FDT
case "$kernel_path" in
  /boot/Image) kernel_config_path=/boot/config ;;
  */Image) kernel_config_path=${kernel_path%/Image}/.config ;;
  *) fail "cannot derive kernel config from KERNEL path: $kernel_path" ;;
esac
validate_source_path "$kernel_config_path" "kernel config"

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

tmpdir=$(mktemp -d /tmp/opencode/pinenote-static-boot.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

dump_rootfs_file "$kernel_path" "$tmpdir/Image"
dump_rootfs_file "$kernel_config_path" "$tmpdir/config"
dump_rootfs_file "$initrd_path" "$tmpdir/initrd.cpio.gz"
dump_rootfs_file "$fdt_path" "$tmpdir/rk3566-pinenote-v1.2.dtb"

cat > "$tmpdir/extlinux.conf" <<EOF
# Generated from a validated PNGuixRoot rootfs image for PineNote Gate 6.
# Keep boot payloads at short /boot paths for stock U-Boot/extlinux loading.
LABEL pinenote-guix-preflight
  MENU LABEL Guix PineNote USB console preflight
  KERNEL /boot/Image
  FDT /boot/rk3566-pinenote-v1.2.dtb
  INITRD /boot/initrd.cpio.gz
  APPEND $append_args
EOF

replace_rootfs_file "$tmpdir/Image" /boot/Image
replace_rootfs_file "$tmpdir/config" /boot/config
replace_rootfs_file "$tmpdir/initrd.cpio.gz" /boot/initrd.cpio.gz
replace_rootfs_file "$tmpdir/rk3566-pinenote-v1.2.dtb" /boot/rk3566-pinenote-v1.2.dtb
replace_rootfs_file "$tmpdir/extlinux.conf" /boot/extlinux/extlinux.conf

pass "embedded Image, matching kernel config, PineNote DTB, and initrd under /boot"
pass "rewrote extlinux.conf to short /boot paths with root=PNGuixRoot"
sha256sum "$rootfs_image"
