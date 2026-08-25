#!/bin/sh
# Structural gate: the library directory must actually get created on a
# fresh device, and the reader must not open its file browser before it
# exists.
#
# Why a gate rather than trust.  Every failure mode in this area is
# SILENT and passes on a developer's workstation:
#
#   * An activation snippet would create /data/books on the os2 ROOT
#     filesystem, because /data is mounted by a shepherd service that
#     starts AFTER activation (verified on the device 2026-08-07: the
#     boot script mentions /data zero times).  The real mount then
#     shadows it forever.
#   * A shell one-shot without `export PATH` finds NO coreutils --
#     shepherd start-lambdas inherit PID 1's environment, which on this
#     device is a single e2fsck-static/sbin directory.  The script takes
#     its failure branch and exits 0 while a workstation test, which has
#     a full PATH, stays green.
#   * An ABSOLUTE symlink target (/data/user) dangles when followed from
#     os1, which mounts the same partition at /home.
#   * Without a declared ordering edge, shepherd starts services
#     concurrently and the reader can reach an unresolvable home_dir --
#     which KOReader does NOT recover from: realpath returns nil and it
#     lands in the read-only store directory.
#
# Usage: validate-koreader-library.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)

svc=$repo_root/pinenote/services/library.scm
rs=$repo_root/pinenote/services/reader-session.scm
sys=$repo_root/pinenote/systems/pinenote-reader.scm
# The seeded KOReader profile moved out of pinenote-reader.scm on
# 2026-08-24: it is a record now, and the record is the one place any of
# its defaults are declared.  Checks 9 and 10 below read it there.
prof=$repo_root/pinenote/services/koreader-profile.scm

fail() { echo "FAIL: $1" >&2; exit 1; }
for f in "$svc" "$rs" "$sys" "$prof"; do [ -r "$f" ] || fail "cannot read $f"; done

# Extract the EMBEDDED SHELL SCRIPT and analyse only that.  The .scm file
# documents these same hazards in prose, and matching the commentary
# instead of the code is how this gate first went red on itself.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
awk '/#!\/bin\/sh/{f=1} f{print} f && /^" port\)/{exit}' "$svc" > "$body"
[ -s "$body" ] || fail "could not extract the shell script from $svc"

# 1. It must be a shepherd one-shot gated on the DATA mount, not on
#    file-systems generally and never on activation.
grep -q "(one-shot? #t)" "$svc" || fail "library service is not a one-shot"
grep -q "(requirement '(file-system-/data))" "$svc" ||
  fail "library one-shot must require file-system-/data -- anything weaker
   (file-systems, or an activation snippet) can run before p7 is mounted
   and create the directory under the mountpoint, invisibly"
if grep -q "activation-service-type" "$svc"; then
  fail "library setup must not use activation-service-type: activation runs
   before /data is mounted"
fi

# 2. PATH must be exported before ANY command that needs coreutils.
path_line=$(grep -n 'export PATH=' "$body" | head -1 | cut -d: -f1 || true)
[ -n "$path_line" ] ||
  fail "no 'export PATH=' in the library script (shepherd gives it a PATH
   with one binary in it -- see wifi.scm:26-28)"
for cmd in mountpoint mkdir chmod chgrp sync; do
  first=$(grep -n "\b$cmd\b" "$body" | head -1 | cut -d: -f1 || true)
  [ -n "$first" ] || continue
  [ "$first" -gt "$path_line" ] ||
    fail "'$cmd' is used at body line $first, BEFORE export PATH at line $path_line"
done

# 3. Never touch an existing library, and never create one when p7 is not
#    mounted.
grep -q 'mountpoint -q' "$body" ||
  fail "the script must refuse when \$root is not a mount point"
grep -q 'already exists -- unchanged' "$body" ||
  fail "the script must leave an existing library completely alone"

# 4. The Debian-home pointer must be RELATIVE.  os1 mounts this partition
#    at /home, so an absolute target dangles from the rescue slot.
grep -q 'ln -s \.\./user' "$body" ||
  fail "the Debian-home pointer must use the RELATIVE target ../user"
if grep -q 'ln -s "*/data/user' "$body"; then
  fail "ABSOLUTE symlink target: /data/user dangles when followed from os1,
   which mounts the same partition at /home"
fi

# 5. Nothing may write inside the Debian user's home.
if grep -E '(mkdir|touch|cp|mv|chown|chmod|ln)[^|]*\$root/user' "$body" |
     grep -v 'ln -s \.\./user' | grep -q .; then
  fail "the script writes inside \$root/user -- that directory IS os1's
   /home/user and os1 is the untouched rescue path"
fi

# 6. The reader must be ordered after the library.
grep -q 'pinenote-dmc pinenote-library' "$rs" ||
  fail "reader-session must require pinenote-library; shepherd starts
   services concurrently, so without the edge the reader can open its file
   browser before /data/books exists"

# 7. The service must actually be registered in the reader flavor.
grep -q '(service pinenote-library-service-type)' "$sys" ||
  fail "pinenote-library-service-type is not registered in the reader flavor"
grep -q '#:use-module (pinenote services library)' "$sys" ||
  fail "pinenote-reader.scm does not import (pinenote services library)"

# 8. There must be a shadowed fallback for the never-mounted case.  The
#    one-shot refuses when /data is not a mount point (correctly), which
#    leaves home_dir unresolvable -- and KOReader lands in the store.
grep -q "pinenote-library-fallback" "$sys" ||
  fail "no shadowed /data/books fallback in the reader flavor: when p7 does
   not mount, the one-shot refuses and KOReader opens the read-only store
   directory instead of anything the user can understand"

# 9. The seeded profile must suppress the quickstart guide, or home_dir is
#    never consulted on a first boot.  reader.lua:251-255 -- when
#    QuickStart:isShown() is false it FORCES start_with="last" and opens the
#    guide, so the library is not what the user sees.  isShown() is
#    shown_version >= quickstart_force_show_version (2021070000).
#     Newlines are folded first: a record field wraps across lines, and a
#     line-based grep would silently match nothing.
seeded=$(tr '\n' ' ' < "$prof" |
           grep -o 'quickstart-shown-version[^)]*(default[^)]*)' |
           head -1 || true)
[ -n "$seeded" ] ||
  fail "the seeded KOReader profile does not set quickstart-shown-version;
   without it a fresh device opens the quickstart guide and the seeded
   home_dir is never used (reader.lua:251-255)"
ver=$(printf '%s' "$seeded" | grep -o '[0-9]\{6,\}' | head -1)
[ -n "$ver" ] && [ "$ver" -ge 2021070000 ] ||
  fail "quickstart_shown_version=$ver is below the 2021070000 threshold, so
   QuickStart:isShown() is still false"

# 10. The seeded font block must be CONDITIONAL on the fonts actually being
#     staged: a fresh clone has no pinenote/fonts/local (gitignored,
#     licensed), so pinenote-local-fonts is #f and EXT_FONT_DIR is never
#     set -- naming "Equity A" there points at a font not in the image.
#
#     "COMPLETE" used to be checked here too (cre_font without
#     monospace_font / cre_font_family_fonts shipped on every fonts-present
#     build once).  It is no longer checkable as a property of the text,
#     because it is no longer expressible: the three keys are emitted from
#     ONE record field, so there is no state in which one is missing.
#     validate-koreader-profile.sh proves that by generating both variants.
grep -q '(and pinenote-local-fonts' "$prof" ||
  fail "the seeded KOReader profile's font aliases are not conditional on
   pinenote-local-fonts; a fresh clone would seed a font that is not in
   the image"

echo "PASS: library is created on p7 by an ordered one-shot, the pointer is
      relative, os1's home is untouched, and the first boot lands in it"
