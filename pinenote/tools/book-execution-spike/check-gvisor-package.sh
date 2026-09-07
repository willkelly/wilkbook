#!/bin/sh
# Host-only checks for the pinned, prebuilt ARM64 gVisor package.  This script
# inspects foreign ELFs with native tools; it never executes them.
set -eu

usage() {
  cat >&2 <<'EOF'
usage: check-gvisor-package.sh [--derivation]
       [--archive FILE --sha256sums FILE --sha512sums FILE]
       [--output GUIX_PACKAGE_OUTPUT]
       [--package-definition FILE --member-manifest FILE]

With no options, check the package's structural pins.  Optional gates may be
combined.  Run archive/output inspection through a native tool environment:

  guix shell binutils zstd -- check-gvisor-package.sh ...
EOF
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo=$(CDPATH= cd -P "$script_dir/../../.." && pwd -P)
package=$repo/pinenote/packages/gvisor.scm
members=$script_dir/expected-release-members.txt

version=20260831.0
tag=release-20260831.0
asset=gvisor-aarch64.tar.zstd
sha256=c1182b6046e1c64b871cd13b4d11335f1d55ba89c3a5c7e8cf4dc1c8f3ac0d3a
sha512=92705c4f339715e34435e9ca553484d9edde0df21137d35aa89b66c3215069e009bfc6e0cc8f8fe8da681059b4c06daa70ce34f166978742742e99685c08730a
base32=0fhdmkrwihadrzlcg9f3i6x5a7az6c8lsfyi3j3lpip18rh2n661

derivation=0
archive=
sha256sums=
sha512sums=
output=
package_override=
members_override=

while [ "$#" -gt 0 ]; do
  case $1 in
    --derivation)
      derivation=1
      shift
      ;;
    --archive|--sha256sums|--sha512sums|--output|--package-definition|--member-manifest)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      case $1 in
        --archive) archive=$2 ;;
        --sha256sums) sha256sums=$2 ;;
        --sha512sums) sha512sums=$2 ;;
        --output) output=$2 ;;
        --package-definition) package_override=$2 ;;
        --member-manifest) members_override=$2 ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -z "$package_override" ] || package=$package_override
[ -z "$members_override" ] || members=$members_override

[ -f "$package" ] || fail "package module missing: $package"
[ -f "$members" ] || fail "member manifest missing: $members"

require_literal() {
  grep -Fq "$1" "$package" || fail "package pin missing: $1"
}

require_literal "(define %gvisor-version \"$version\")"
require_literal '"https://github.com/google/gvisor/releases/download/"'
require_literal '"/gvisor-aarch64.tar.zstd"'
require_literal "\"$base32\""
require_literal "(supported-systems '(\"aarch64-linux\"))"
require_literal '"containerd-shim-runsc-v1"'
require_literal '"gvisor-bin/gvisor-sentry-prewarmer"'
require_literal '"gvisor-bin/gvisor_sentry"'

if grep -Eq '\(invoke[[:space:]]+"(curl|wget)"' "$package"; then
  fail "package contains an unpinned build-time downloader"
fi

member_count=$(wc -l < "$members" | tr -d ' ')
[ "$member_count" = 6 ] || fail "expected six release files, got $member_count"
[ "$(LC_ALL=C sort -u "$members" | wc -l | tr -d ' ')" = 6 ] || \
  fail "release member manifest contains duplicates"

tmp=
layout_tmp=
package_members_tmp=
cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$layout_tmp" ] || rm -rf "$layout_tmp"
  [ -z "$package_members_tmp" ] || \
    rm -f "$package_members_tmp" "$package_members_tmp.expected"
}
trap cleanup EXIT HUP INT TERM

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

# Evaluate the package's canonical list rather than grepping selected names.
# The external manifest is retained as an independently readable release
# roster; exact equality prevents either list from drifting to a false green.
need_command guix
package_members_tmp=${TMPDIR:-/tmp}/wilkbook-gvisor-members.$$
if ! printf '%s\n' \
    '(primitive-load (cadr (command-line)))' \
    '(for-each (lambda (x) (display x) (newline))' \
    '          (@@ (pinenote packages gvisor) %gvisor-release-members))' | \
    guix repl -q -L "$repo" /dev/stdin "$package" > "$package_members_tmp"; then
  fail "could not evaluate package member list"
fi
LC_ALL=C sort -o "$package_members_tmp" "$package_members_tmp"
if ! LC_ALL=C sort "$members" | cmp -s - "$package_members_tmp"; then
  LC_ALL=C sort "$members" > "$package_members_tmp.expected"
  diff -u "$package_members_tmp.expected" "$package_members_tmp" >&2 || true
  rm -f "$package_members_tmp.expected"
  fail "package member list differs from the release manifest"
fi
rm -f "$package_members_tmp"
package_members_tmp=
pass "package source pins ARM64 release $tag"
pass "package member list exactly matches the six-file release manifest"

validate_tree() { # ROOT PREFIX (PREFIX is empty for archive, bin for output)
  tree=$1
  prefix=$2
  [ -d "$tree" ] || fail "layout root is not a directory: $tree"
  need_command readelf
  need_command strings

  layout_tmp=${TMPDIR:-/tmp}/wilkbook-gvisor-check.$$
  mkdir -p "$layout_tmp"
  if find "$tree" -type l -print -quit | grep -q .; then
    fail "layout contains a symlink"
  fi
  find "$tree" -type f -printf '%P\n' | LC_ALL=C sort \
    > "$layout_tmp/actual-files"
  if [ -n "$prefix" ]; then
    sed "s#^#$prefix/#" "$members" > "$layout_tmp/expected-files"
  else
    cp "$members" "$layout_tmp/expected-files"
  fi
  LC_ALL=C sort -o "$layout_tmp/expected-files" "$layout_tmp/expected-files"
  cmp -s "$layout_tmp/expected-files" "$layout_tmp/actual-files" || {
    diff -u "$layout_tmp/expected-files" "$layout_tmp/actual-files" >&2 || true
    fail "installed file list differs from the pinned release"
  }
  while IFS= read -r member; do
    file=$tree/${prefix:+$prefix/}$member
    [ -x "$file" ] || fail "release member is not executable: $file"
    readelf -h "$file" | grep -Eq 'Machine:[[:space:]]+AArch64$' || \
      fail "release member is not an AArch64 ELF: $file"
    if readelf -l "$file" | grep -q INTERP; then
      fail "release member has an unexpected ELF interpreter: $file"
    fi
    if readelf -d "$file" 2>/dev/null | grep -q NEEDED; then
      fail "release member has an unexpected dynamic dependency: $file"
    fi
  done < "$members"
  strings "$tree/${prefix:+$prefix/}runsc" | grep -Fq "release-$version" || \
    fail "runsc does not contain the pinned release marker"
  rm -rf "$layout_tmp"
  layout_tmp=
}

if [ -n "$archive" ] || [ -n "$sha256sums" ] || [ -n "$sha512sums" ]; then
  [ -n "$archive" ] && [ -n "$sha256sums" ] && [ -n "$sha512sums" ] || \
    fail "archive inspection requires --archive, --sha256sums, and --sha512sums"
  [ -f "$archive" ] || fail "archive not found: $archive"
  [ -f "$sha256sums" ] || fail "SHA256SUMS not found: $sha256sums"
  [ -f "$sha512sums" ] || fail "SHA512SUMS not found: $sha512sums"
  need_command sha256sum
  need_command sha512sum
  need_command tar

  upstream256=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$sha256sums")
  upstream512=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$sha512sums")
  [ "$upstream256" = "$sha256" ] || fail "upstream SHA256 entry changed"
  [ "$upstream512" = "$sha512" ] || fail "upstream SHA512 entry changed"
  [ "$(sha256sum "$archive" | awk '{print $1}')" = "$sha256" ] || \
    fail "archive SHA256 mismatch"
  [ "$(sha512sum "$archive" | awk '{print $1}')" = "$sha512" ] || \
    fail "archive SHA512 mismatch"

  tmp=${TMPDIR:-/tmp}/wilkbook-gvisor-archive.$$
  mkdir -p "$tmp/root"
  { cat "$members"; printf '%s\n' 'gvisor-bin/'; } | LC_ALL=C sort \
    > "$tmp/expected-archive"
  tar --zstd -tf "$archive" | LC_ALL=C sort > "$tmp/actual-archive"
  cmp -s "$tmp/expected-archive" "$tmp/actual-archive" || {
    diff -u "$tmp/expected-archive" "$tmp/actual-archive" >&2 || true
    fail "archive member list differs from the pinned release"
  }
  tar --zstd -xf "$archive" -C "$tmp/root" --no-same-owner
  validate_tree "$tmp/root" ""
  pass "archive checksums, exact layout, and six static AArch64 ELFs"
fi

if [ "$derivation" -eq 1 ]; then
  (cd "$repo" &&
    guix time-machine -C channels.scm -- \
      build --no-grafts --derivations -L . \
      --target=aarch64-linux-gnu \
      -e '(@ (pinenote packages gvisor) gvisor-bin)')
  pass "pinned-channel package derivation"
fi

if [ -n "$output" ]; then
  validate_tree "$output" "bin"
  pass "installed output exact layout and six static AArch64 ELFs"
fi
