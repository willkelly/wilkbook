#!/bin/sh
# Copy one spike-only system/image into immutable private QEMU inputs.
# Host-only: never mounts, launches QEMU, or touches a device.
set -eu
umask 077

usage() {
  printf 'usage: %s SYSTEM_STORE_DIRECTORY RAW_IMAGE_STORE_FILE NAME\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 3 ] || { usage; exit 2; }
system_input=$1
image_input=$2
name=$3

case $name in
  ''|*[!a-z0-9.-]*|.*|*..*) fail "unsafe artifact name: $name" ;;
esac

for command in blkid dd e2label guile guix partx sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
artifact_root=$script_dir/build/artifacts
mkdir -p "$artifact_root"
chmod 0700 "$script_dir/build" "$artifact_root"

system=$(readlink -f -- "$system_input") || fail "cannot resolve system input"
image=$(readlink -f -- "$image_input") || fail "cannot resolve image input"
case $system in
  /gnu/store/*-system) ;;
  *) fail "system input is not a canonical Guix system output: $system" ;;
esac
case $image in
  /gnu/store/*-disk-image) ;;
  *) fail "image input is not a canonical Guix disk image output: $image" ;;
esac
[ -d "$system" ] || fail "system output is not a directory: $system"
[ -f "$image" ] || fail "image output is not a regular file: $image"
image_system_count=$(guix gc --references "$image" | grep -Fxc "$system" || true)
[ "$image_system_count" -eq 1 ] ||
  fail "raw image does not reference the selected system exactly once"

kernel=$system/kernel/Image
config=$system/kernel/.config
dtb=$system/kernel/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb
initrd=$system/initrd
parameters=$system/parameters
for pair in \
  "kernel Image:$kernel" \
  "kernel config:$config" \
  "PineNote DTB:$dtb" \
  "initrd:$initrd" \
  "boot parameters:$parameters"
do
  label=${pair%%:*}
  path=${pair#*:}
  [ -f "$path" ] || fail "missing $label: $path"
done

# Guix systems expose a kernel profile, whose Image/config/DTB pass through a
# module-database output before resolving to the actual package.  Prove every
# staged kernel member terminates in the one exact package output instead of
# treating SYSTEM/kernel itself as that output.
kernel_target=$(readlink -f -- "$kernel") || fail "cannot resolve system kernel Image"
case $kernel_target in
  /gnu/store/*-linux-pinenote-book-execution-test-7.1.8-pinenote/Image)
    kernel_output=${kernel_target%/Image} ;;
  *) fail "system did not select the exact PineNote USER_NS test kernel: $kernel_target" ;;
esac
config_target=$(readlink -f -- "$config") || fail "cannot resolve system kernel config"
dtb_target=$(readlink -f -- "$dtb") || fail "cannot resolve system PineNote DTB"
[ "$config_target" = "$kernel_output/.config" ] ||
  fail "system config does not resolve inside the selected kernel output"
[ "$dtb_target" = "$kernel_output/lib/dtbs/rockchip/rk3566-pinenote-v1.2.dtb" ] ||
  fail "system DTB does not resolve inside the selected kernel output"
grep -Fqx 'CONFIG_USER_NS=y' "$config" || \
  fail "selected kernel config does not contain CONFIG_USER_NS=y"

destination=$artifact_root/$name
[ ! -e "$destination" ] && [ ! -L "$destination" ] || \
  fail "artifact destination already exists: $destination"
temporary=$(mktemp -d "$artifact_root/.stage.XXXXXX")
cleanup() {
  if [ -n "${temporary:-}" ] && [ -d "$temporary" ]; then
    rm -rf -- "$temporary"
  fi
}
trap cleanup EXIT HUP INT TERM
mkdir "$temporary/boot-bundle" "$temporary/boot-bundle/extlinux"

copy_fixed() {
  source=$1
  destination_file=$2
  cp --reflink=auto --sparse=always -- "$source" "$destination_file"
  chmod 0400 "$destination_file"
  [ "$(stat -c %h "$destination_file")" -eq 1 ] || \
    fail "private copy unexpectedly has hard-link aliases: $destination_file"
}

copy_baseline() {
  source=$1
  destination_file=$2
  rootfs=$temporary/root-partition.ext4
  cp --reflink=auto --sparse=always -- "$source" "$destination_file"
  chmod 0600 "$destination_file"
  [ "$(stat -c %h "$destination_file")" -eq 1 ] ||
    fail "private baseline unexpectedly has hard-link aliases"

  partition_table=$(partx -g -o START,SECTORS,TYPE "$destination_file") ||
    fail "could not read raw-image partition table"
  partition_count=$(printf '%s\n' "$partition_table" |
                    sed '/^[[:space:]]*$/d' | wc -l)
  [ "$partition_count" -eq 1 ] ||
    fail "raw image does not contain exactly one partition"
  set -- $partition_table
  baseline_start_sector=$1
  baseline_sector_count=$2
  partition_type=$3
  [ "$partition_type" = "0x83" ] ||
    fail "raw image partition is not Linux type 0x83"
  case $baseline_start_sector:$baseline_sector_count in
    *[!0123456789:]*|:*|*:)
      fail "invalid raw-image partition geometry" ;;
  esac

  # raw-with-offset labels this filesystem Guix_image even when the OS root is
  # declared by PNGuixRoot.  Work only on private regular files: extract the
  # sole partition, set the required label, and write it back without touching
  # the MBR or bytes outside the partition.  No mount, loop device, or root is
  # involved.
  dd if="$destination_file" of="$rootfs" bs=512 \
    skip="$baseline_start_sector" count="$baseline_sector_count" status=none
  [ "$(blkid -p -s TYPE -o value "$rootfs")" = ext4 ] ||
    fail "raw image partition is not ext4"
  e2label "$rootfs" PNGuixRoot
  [ "$(blkid -p -s LABEL -o value "$rootfs")" = PNGuixRoot ] ||
    fail "could not set private root filesystem label"
  dd if="$rootfs" of="$destination_file" bs=512 \
    seek="$baseline_start_sector" count="$baseline_sector_count" \
    conv=notrunc status=none
  rm -f -- "$rootfs"
  chmod 0400 "$destination_file"
}

copy_baseline "$image" "$temporary/baseline.raw"
copy_fixed "$kernel" "$temporary/boot-bundle/extlinux/Image"
copy_fixed "$config" "$temporary/boot-bundle/extlinux/config"
copy_fixed "$dtb" "$temporary/boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb"
copy_fixed "$initrd" "$temporary/boot-bundle/extlinux/initrd.cpio.gz"

kernel_args=$(guile -c '
(use-modules (srfi srfi-1) (srfi srfi-13))
(define parameters (call-with-input-file (cadr (command-line)) read))
(unless (and (pair? parameters) (eq? (car parameters) (quote boot-parameters)))
  (exit 2))
(define entries
  (filter (lambda (field)
            (and (pair? field) (eq? (car field) (quote kernel-arguments))))
          (cdr parameters)))
(unless (= (length entries) 1) (exit 2))
(define arguments (cadr (car entries)))
(unless (and (list? arguments) (every string? arguments)) (exit 2))
(when (any (lambda (argument) (string-any char-whitespace? argument)) arguments)
  (exit 2))
(display (string-join arguments " "))
' "$parameters") || fail "could not read the system boot parameters"
[ -n "$kernel_args" ] || fail "system kernel argument list is empty"
case " $kernel_args " in
  *' root='*) fail "system arguments already contain a root= token" ;;
esac
case " $kernel_args " in
  *' console=ttyS2,1500000n8 '*) ;;
  *) fail "system arguments lack the PineNote hardware console" ;;
esac

cat > "$temporary/boot-bundle/extlinux/extlinux.conf" <<EOF
# Generated only for the private book-execution QEMU baseline.
LABEL wilkbook-book-execution-spike
  MENU LABEL Wilkbook book-execution spike
  KERNEL Image
  FDT rk3566-pinenote-v1.2.dtb
  INITRD initrd.cpio.gz
  APPEND $kernel_args gnu.system=$system gnu.load=$system/boot root=PNGuixRoot
EOF
chmod 0400 "$temporary/boot-bundle/extlinux/extlinux.conf"

cat > "$temporary/manifest.txt" <<EOF
schema=1
purpose=non-shipping-pinenote-book-execution-qemu-inputs
source-system=$system
source-image=$image
source-image-sha256=$(sha256sum "$image" | cut -d ' ' -f 1)
kernel-output=$kernel_output
kernel-package-version=7.1.8-pinenote
kernel-runtime-release=7.1.8
kernel-architecture=arm64
target=aarch64-linux-gnu
kernel-delta=CONFIG_USER_NS:n-to-y-after-olddefconfig
root-label=PNGuixRoot
baseline-transformation=private-partition-label-only
baseline-start-sector=$baseline_start_sector
baseline-sector-count=$baseline_sector_count
qemu-host-share=none
qemu-network=none
runtime-profile=isolation-userns
EOF
for relative in \
  baseline.raw \
  boot-bundle/extlinux/Image \
  boot-bundle/extlinux/config \
  boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb \
  boot-bundle/extlinux/initrd.cpio.gz \
  boot-bundle/extlinux/extlinux.conf
do
  hash=$(sha256sum "$temporary/$relative" | cut -d ' ' -f 1)
  printf 'sha256[%s]=%s\n' "$relative" "$hash" >> "$temporary/manifest.txt"
done
chmod 0400 "$temporary/manifest.txt"
chmod 0500 "$temporary/boot-bundle" "$temporary/boot-bundle/extlinux"
chmod 0500 "$temporary"

mv -- "$temporary" "$destination"
temporary=
printf 'PASS: staged immutable private QEMU inputs: %s\n' "$destination"
