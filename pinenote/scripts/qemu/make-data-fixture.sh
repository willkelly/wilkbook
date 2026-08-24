#!/bin/sh
# Build a synthetic p7 ("data") filesystem that looks like a PineNote whose
# stock Debian os1 has been lived in.
#
# This is the partition the whole library design turns on, and until now no
# offline rung had one: qemu-virt-check booted a disk with no p7 at all, so
# every path that matters -- does the library get created, does the pointer
# to the Debian home resolve, do we leave os1's home alone -- was untested
# anywhere except on the one physical device.
#
# The layout mirrors what was read off the real device on 2026-08-07:
# p7's ROOT is os1's /home, so the Debian user's home is ./user, and the
# marker file pn_use_as_home_mmcblk0p5 sits beside it.  Ownership comes from
# the invoking user; on a host whose uid is 1000 (the Debian user's uid)
# that reproduces the real thing exactly.
#
# Host-side only, rootless (mke2fs -d), writes nothing outside /tmp/wilkbook.
#
# usage: make-data-fixture.sh VARIANT OUTPUT_IMG
#   os1-used       a lived-in Debian home, NO library yet   (the migrating
#                  friend: the case the library service exists for)
#   with-library   the same, plus an existing /books with a book and its
#                  .sdr sidecar (the author's device: must be left alone)
#   empty          a bare filesystem, no Debian home at all (reprovisioned
#                  p7: the pointer must be skipped, not dangling)
set -eu

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[ "$#" -eq 2 ] || { printf 'usage: %s VARIANT OUTPUT_IMG\n' "$0" >&2; exit 2; }
variant=$1
out=$2

case $variant in
  os1-used|with-library|empty) ;;
  *) fail "unknown variant: $variant (os1-used|with-library|empty)" ;;
esac

command -v mke2fs >/dev/null 2>&1 || \
  fail "mke2fs not found; run via: guix shell e2fsprogs -- $0 ..."

artifact_root=$(CDPATH= cd -P /tmp/wilkbook && pwd -P) || \
  fail "cannot resolve /tmp/wilkbook"
out_parent=$(CDPATH= cd -P "$(dirname "$out")" && pwd -P) || \
  fail "output parent does not exist"
out=$out_parent/$(basename "$out")
case $out in
  "$artifact_root"/*) ;;
  *) fail "output image must resolve under $artifact_root" ;;
esac

tree=$(mktemp -d "$artifact_root/pinenote-datafix-XXXXXX")
trap 'rm -rf -- "$tree"' EXIT

if [ "$variant" != "empty" ]; then
  # The marker os1's initrd writes to claim p7 as its /home.
  : > "$tree/pn_use_as_home_mmcblk0p5"

  # The Debian user's home.  Top-level names are asserted verbatim by
  # run-virt-assertions.sh, so changing them means changing that too.
  mkdir -p "$tree/user/Desktop" "$tree/user/Documents" "$tree/user/Downloads" \
           "$tree/user/Music" "$tree/user/Pictures" "$tree/user/Public" \
           "$tree/user/Templates" "$tree/user/Videos" \
           "$tree/user/.config/koreader"

  # The stock demo documents that ship on the Debian image, and one book
  # in a place a real person would put one.
  printf 'stub epub (fixture)\n' > "$tree/user/Documents/Wikipedia_Pine.epub"
  printf 'stub pdf (fixture)\n'  > "$tree/user/Documents/Wikipedia_Pine.pdf"
  printf 'stub epub (fixture)\n' > "$tree/user/Documents/A Book I Was Reading.epub"

  # os1's own KOReader profile, with the lastdir the real device carries.
  cat > "$tree/user/.config/koreader/settings.reader.lua" <<'LUA'
-- fixture: stands in for os1's KOReader profile
return {
    ["lastdir"] = "/home/user",
}
LUA

  printf '# fixture\n' > "$tree/user/.bashrc"
fi

if [ "$variant" = "with-library" ]; then
  mkdir -p "$tree/books/Existing Book.sdr"
  printf 'stub epub (fixture)\n' > "$tree/books/Existing Book.epub"
  printf 'return { ["percent_finished"] = 0.5 }\n' \
    > "$tree/books/Existing Book.sdr/metadata.epub.lua"
fi

rm -f -- "$out"
# 64 MiB is ample and keeps the disk image small; the real p7 is ~24 GiB.
mke2fs -q -t ext4 -L data -d "$tree" "$out" 65536 >/dev/null 2>&1 || \
  fail "mke2fs failed to build the fixture filesystem"

pass "data fixture ($variant) built: $out"
if [ "$variant" != "empty" ]; then
  pass "  Debian home present at ./user with $(ls "$tree/user" | wc -l) visible entries"
fi
if [ "$variant" = "with-library" ]; then
  pass "  pre-existing ./books with one book and its .sdr sidecar"
fi
