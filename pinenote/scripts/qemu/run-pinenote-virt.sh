#!/bin/sh
# Boot the real PineNote kernel, initrd, and rootfs in QEMU's generic ARM64
# "virt" machine. Takes a boot bundle staged by
# stage-boot-bundle-from-rootfs.sh (Image, initrd, extlinux.conf with the
# matching gnu.system/gnu.load arguments) and a disk built by
# make-virt-disk.sh.
#
# What this proves: the hardware kernel image boots, the initrd finds the
# waveform partition by PARTNAME and installs it, root mounts by the
# PNGuixRoot label, Shepherd and the one-shot services run. What it cannot
# prove: EBC rendering, USB dwc3 gadget, or any RK3566 hardware behavior.
set -eu

usage() {
  printf 'usage: %s BOOT_BUNDLE_DIRECTORY DISK_IMAGE\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || { usage; exit 2; }

bundle=$1
disk=$2

command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  fail "qemu-system-aarch64 not found; run via: guix shell qemu -- $0 ..."

kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
config=$bundle/extlinux/extlinux.conf

[ -f "$kernel" ] || fail "bundle is missing extlinux/Image: $bundle"
[ -f "$initrd" ] || fail "bundle is missing extlinux/initrd.cpio.gz: $bundle"
[ -f "$config" ] || fail "bundle is missing extlinux/extlinux.conf: $bundle"
[ -f "$disk" ] || fail "disk image is not a regular file: $disk"

append=$(sed -n 's/^[[:space:]]*APPEND[[:space:]][[:space:]]*//p' "$config" | sed -n '1p')
[ -n "$append" ] || fail "bundle extlinux.conf has no APPEND line"

case " $append " in
  *' gnu.system='*) ;;
  *) fail "APPEND lacks gnu.system=; bundle does not match a Guix rootfs" ;;
esac

# Hardware consoles do not exist on the virt machine; steer the kernel
# console to the PL011 UART instead. Everything else, including the
# rockchip_ebc parameters and root=PNGuixRoot, stays exactly as on hardware.
append=$(printf '%s' "$append" | sed \
  -e 's/console=ttyS2,1500000n8/console=ttyAMA0/' \
  -e 's/console=tty0 //')

printf 'booting with: %s\n' "$append"
printf '(exit QEMU with C-a x)\n'

exec qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2048 \
  -nographic -no-reboot \
  -kernel "$kernel" \
  -initrd "$initrd" \
  -append "$append" \
  -drive if=virtio,format=raw,file="$disk"
