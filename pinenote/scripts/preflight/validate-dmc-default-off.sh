#!/bin/sh
# Structural gate: the DMC mode selector must default to "off" on EVERY
# path that is not an explicit, recognised opt-in.
#
# Why this needs a gate rather than trust.  324 MHz starves the EBC's
# phase-data fetch and corrupts the display, and the controller has no
# underrun interrupt -- so a mis-defaulted boot produces a clean dmesg, a
# clean checkpoint table, and a wrecked panel.  There is no runtime signal
# that says the default is wrong; the only signal is a human looking at
# the glass.
#
# It has already regressed once, silently.  Commit ad1019b, "Disable the
# DDR drop by default", changed only comments: its string replacement did
# not match, nobody checked the result, and the selector went on
# returning "normal" on a missing file, an unmounted /data, an
# unrecognised value, and any throw -- while three documents asserted the
# opposite.  A fresh install would have corrupted its display on every
# boot, and the repo would have said it was fine.
#
# Usage: validate-dmc-default-off.sh [service.scm]
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
service=${1:-$repo_root/pinenote/services/dmc.scm}

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -r "$service" ] || fail "cannot read $service"

# The selector: from `(define mode` to the catch handler that closes it.
selector=$(awk '/\(define mode/{f=1} f{print} f&&/\(lambda _ /{exit}' "$service")
[ -n "$selector" ] || fail "no (define mode ...) selector found in $service"

# 1. Every literal the selector can RETURN must be "off" or a value read
#    from the file.  Any bare "normal" among them is a default path that
#    opts the device in without being asked.
normals=$(printf '%s\n' "$selector" | grep -c '"normal"' || true)
[ "$normals" -eq 1 ] || fail \
  "selector mentions \"normal\" ${normals}x; exactly 1 is expected (the
   member allowlist).  Any other occurrence is a DEFAULT path, and the
   default must be off -- see ad1019b for how this regresses silently."

printf '%s\n' "$selector" | grep -q "(member v '(\"normal\" \"noswitch\" \"off\"))" ||
  fail "the recognised-value allowlist is missing or changed shape"

# 2. The three fallbacks and the catch handler must each yield "off".
for pattern in \
  '((eof-object? line) "off")' \
  '"off"))' \
  '(lambda _ "off")'
do
  printf '%s\n' "$selector" | grep -qF "$pattern" ||
    fail "selector is missing the default-off path: $pattern"
done

# 3. The dispatch must treat anything-but-off as running the window, so
#    that "off" is genuinely the do-nothing state and not a label.
grep -qF '(if (string=? mode "off")' "$service" ||
  fail "dispatch no longer keys on mode = \"off\""

echo "PASS: DMC selector defaults to off on every non-opt-in path"
