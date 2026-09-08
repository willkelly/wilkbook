#!/bin/sh
# Non-mounting inspection of stage-private-qemu-inputs.sh output.
set -eu

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || {
  printf 'usage: %s PRIVATE-INPUT-DIRECTORY\n' "$0" >&2
  exit 2
}

for command in blkid file python3 sfdisk sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
artifact_root=$script_dir/build/artifacts
inputs=$(CDPATH= cd -P "$1" && pwd -P) || fail "cannot resolve input directory"
case $inputs in
  "$artifact_root"/*) ;;
  *) fail "inputs are outside the private worktree artifact root: $inputs" ;;
esac

manifest=$inputs/manifest.txt
baseline=$inputs/baseline.raw
bundle=$inputs/boot-bundle
for relative in \
  manifest.txt \
  baseline.raw \
  boot-bundle/extlinux/Image \
  boot-bundle/extlinux/config \
  boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb \
  boot-bundle/extlinux/initrd.cpio.gz \
  boot-bundle/extlinux/extlinux.conf
do
  path=$inputs/$relative
  [ -f "$path" ] || fail "missing fixed input: $relative"
  [ ! -L "$path" ] || fail "input is a symlink: $relative"
  [ "$(stat -c %h "$path")" -eq 1 ] || fail "input has hard-link aliases: $relative"
  mode=$(stat -c %a "$path")
  case $mode in
    *[2367]|*[2367][0-7]|*[2367][0-7][0-7])
      fail "input has a write bit: $relative mode=$mode" ;;
  esac
done

grep -Fqx 'purpose=non-shipping-pinenote-book-execution-qemu-inputs' "$manifest" ||
  fail "manifest purpose is missing"
grep -Fqx 'kernel-runtime-release=7.1.8' "$manifest" ||
  fail "manifest runtime release is missing"
grep -Fqx 'kernel-delta=CONFIG_USER_NS:n-to-y-after-olddefconfig' "$manifest" ||
  fail "manifest USER_NS delta is missing"
grep -Fqx 'baseline-transformation=private-partition-label-only' "$manifest" ||
  fail "manifest baseline transformation is missing"
grep -Fqx 'qemu-host-share=none' "$manifest" || fail "manifest permits a host share"
grep -Fqx 'qemu-network=none' "$manifest" || fail "manifest permits QEMU networking"
grep -Fqx 'runtime-profile=isolation-userns' "$manifest" ||
  fail "manifest does not select isolation-userns"

for relative in \
  baseline.raw \
  boot-bundle/extlinux/Image \
  boot-bundle/extlinux/config \
  boot-bundle/extlinux/rk3566-pinenote-v1.2.dtb \
  boot-bundle/extlinux/initrd.cpio.gz \
  boot-bundle/extlinux/extlinux.conf
do
  expected=$(sed -n "s|^sha256\[$relative\]=||p" "$manifest")
  [ "${#expected}" -eq 64 ] || fail "manifest lacks SHA-256 for $relative"
  observed=$(sha256sum "$inputs/$relative" | cut -d ' ' -f 1)
  [ "$observed" = "$expected" ] || fail "SHA-256 mismatch for $relative"
done

grep -Fqx 'CONFIG_USER_NS=y' "$bundle/extlinux/config" ||
  fail "staged kernel config lacks CONFIG_USER_NS=y"
file "$bundle/extlinux/Image" | grep -Fq 'Linux kernel ARM64 boot executable Image' ||
  fail "staged Image is not an ARM64 Linux boot Image"

source_system=$(sed -n 's/^source-system=//p' "$manifest")
case $source_system in
  /gnu/store/*-system) ;;
  *) fail "manifest source system is not canonical" ;;
esac
append=$(sed -n 's/^[[:space:]]*APPEND[[:space:]][[:space:]]*//p' \
         "$bundle/extlinux/extlinux.conf")
[ "$(printf '%s\n' "$append" | wc -l)" -eq 1 ] ||
  fail "extlinux configuration does not contain exactly one APPEND"
case " $append " in
  *' root=PNGuixRoot '*) ;;
  *) fail "extlinux APPEND lacks root=PNGuixRoot" ;;
esac
case " $append " in
  *' console=ttyS2,1500000n8 '*) ;;
  *) fail "extlinux APPEND lacks the one steerable hardware console" ;;
esac
root_count=0
system_count=0
load_count=0
console_count=0
for argument in $append; do
  [ "$argument" != root=PNGuixRoot ] || root_count=$((root_count + 1))
  [ "$argument" != "gnu.system=$source_system" ] || system_count=$((system_count + 1))
  [ "$argument" != "gnu.load=$source_system/boot" ] || load_count=$((load_count + 1))
  [ "$argument" != console=ttyS2,1500000n8 ] || console_count=$((console_count + 1))
done
[ "$root_count" -eq 1 ] || fail "extlinux APPEND root identity is ambiguous"
[ "$system_count" -eq 1 ] || fail "extlinux APPEND lacks the exact Guix system"
[ "$load_count" -eq 1 ] || fail "extlinux APPEND lacks the matched Guix load path"
[ "$console_count" -eq 1 ] || fail "extlinux APPEND console identity is ambiguous"

partition=$(sfdisk --json "$baseline" | python3 -c '
import json, sys
table = json.load(sys.stdin)["partitiontable"]
parts = table["partitions"]
if len(parts) != 1:
    raise SystemExit(f"expected one root partition, observed {len(parts)}")
sector_size = int(table.get("sectorsize", 512))
part = parts[0]
print(int(part["start"]) * sector_size, int(part["size"]) * sector_size)
') || fail "baseline partition table is not the expected one-partition image"
set -- $partition
offset=$1
size=$2
start_sector=$(sed -n 's/^baseline-start-sector=//p' "$manifest")
sector_count=$(sed -n 's/^baseline-sector-count=//p' "$manifest")
case $start_sector:$sector_count in
  *[!0123456789:]*|:*|*:) fail "manifest partition geometry is invalid" ;;
esac
[ "$offset" -eq $((start_sector * 512)) ] ||
  fail "manifest start sector does not match baseline partition table"
[ "$size" -eq $((sector_count * 512)) ] ||
  fail "manifest sector count does not match baseline partition table"
probe=$(blkid -p -O "$offset" -S "$size" -o export "$baseline") ||
  fail "could not probe root filesystem inside baseline"
printf '%s\n' "$probe" | grep -Fqx 'TYPE=ext4' ||
  fail "baseline root partition is not ext4"
printf '%s\n' "$probe" | grep -Fqx 'LABEL=PNGuixRoot' ||
  fail "baseline root partition lacks label PNGuixRoot"

printf 'PASS: immutable private PineNote book-execution QEMU inputs\n'
printf '  baseline-offset=%s baseline-size=%s\n' "$offset" "$size"
