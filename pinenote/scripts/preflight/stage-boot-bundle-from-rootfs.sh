#!/bin/sh
set -eu

usage() {
  printf 'usage: %s ROOTFS_IMAGE BOOT_BUNDLE_DIRECTORY\n' "$0" >&2
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
    *) fail "boot bundle directory must resolve under $opencode_root" ;;
  esac
}

extract_first_field() {
  field=$1
  config=$2
  printf '%s\n' "$config" | sed -n "s/^[[:space:]]*$field[[:space:]][[:space:]]*//p" | sed -n '1p'
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

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

rootfs_image=$1
requested_bundle=$2

if [ ! -f "$rootfs_image" ]; then
  fail "rootfs image is not a regular file: $rootfs_image"
fi

opencode_root=$(resolve_directory /tmp/opencode) || fail "cannot resolve /tmp/opencode"
parent=$(dirname "$requested_bundle")
basename=$(basename "$requested_bundle")

case $basename in
  ''|'.'|'..') fail "boot bundle basename is unsafe: $basename" ;;
esac

parent_root=$(resolve_directory "$parent") || fail "boot bundle parent does not exist: $parent"
bundle=$parent_root/$basename
require_inside_opencode "$bundle"

if [ -e "$bundle" ] || [ -L "$bundle" ]; then
  fail "boot bundle path already exists; refusing to reuse it: $bundle"
fi

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
"$script_dir/inspect-rootfs-image.sh" "$rootfs_image" >/dev/null

extlinux_config=$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$rootfs_image" 2>/dev/null) || \
  fail "could not read /boot/extlinux/extlinux.conf from $rootfs_image"

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
if [ -z "$fdt_path" ]; then
  if [ -z "$fdt_dir" ]; then
    fail "source extlinux.conf does not name FDT or FDTDIR"
  fi
  fdt_path=$fdt_dir/rockchip/rk3566-pinenote-v1.2.dtb
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

mkdir -- "$bundle"
mkdir -- "$bundle/extlinux"

dump_rootfs_file "$kernel_path" "$bundle/extlinux/Image"
dump_rootfs_file "$initrd_path" "$bundle/extlinux/initrd.cpio.gz"
dump_rootfs_file "$fdt_path" "$bundle/extlinux/rk3566-pinenote-v1.2.dtb"
printf '%s\n' "$extlinux_config" > "$bundle/extlinux/source-extlinux.conf"

cat > "$bundle/extlinux/extlinux.conf" <<EOF
# Generated from a validated PNGuixRoot rootfs image for static preflight only.
# Do not install automatically and do not persist U-Boot environment changes.
LABEL pinenote-guix-preflight
  MENU LABEL Guix PineNote slim preflight
  LINUX Image
  FDT rk3566-pinenote-v1.2.dtb
  INITRD initrd.cpio.gz
  APPEND $append_args
EOF

pass "staged rootfs-matched boot bundle under $bundle"
pass "extracted Image, PineNote DTB, initrd, and generated extlinux.conf"
note "run: pinenote/scripts/preflight/inspect-boot-bundle.sh $bundle"
