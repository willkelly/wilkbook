#!/bin/sh
# Every Makefile recipe that invokes guix must go through $(GUIX), so that
# TIME_MACHINE=1 can pin it to channels.scm.
#
# Why this gate exists: channels.scm is the whole reproducibility claim in
# doc/release.md -- `guix time-machine -C channels.scm' rebuilds the identical
# closure -- but for a long time NO build target consumed it. Builds tracked
# whatever the developer last pulled, and the drift was invisible until the
# kernel stopped compiling entirely (issue #13: %linux-pinenote-base was, at
# the time, bound to nongnu:linux, a floating alias that moved 7.0 -> 7.1,
# where the forward-port patch then collided with mainline's PineNote DTSI;
# the base is series-pinned now). TIME_MACHINE=1 fixed the mechanism; this
# gate stops a new recipe from silently opting out of it again.  (The flag
# itself is currently broken for a different reason: channels.scm pins a
# nonguix that predates linux-7.1 -- doc/building.md.)
#
# MATCHING RULE, and it matters: do NOT flag every recipe line containing the
# word "guix". The per-target toolchain prefix is `$(call guix-shell,PKGS)',
# which contains "guix" and is CORRECT -- it provides a compiler, not a build
# of this project, and HOST_TOOLCHAIN=1 bypasses it wholesale. A matcher naive
# enough to flag those turns a green tree red on day one and then gets deleted
# for crying wolf. So: a recipe line invoking guix must contain $(GUIX), or
# $(call guix-shell, or appear in the small commented allowlist below.
set -eu

repo_root=$(CDPATH= cd -P "$(dirname "$0")/../../.." && pwd -P)
makefile=$repo_root/Makefile

fail=0
note() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

[ -f "$makefile" ] || { printf 'FAIL: no Makefile at %s\n' "$makefile" >&2; exit 1; }

# Recipe lines only (leading tab). Strip a leading '@' and any comment tail.
#
# ALLOWLIST -- each entry needs a reason:
#   guix describe   `channels-pin' regenerates the pin and must therefore
#                   describe the AMBIENT guix; routing it through the pin
#                   would make it copy channels.scm back onto itself.
lineno=0
while IFS= read -r line; do
    lineno=$((lineno + 1))
    case $line in
        "	"*) ;;                      # recipe line (leading tab)
        *) continue ;;
    esac
    case $line in
        *guix*) ;;                      # mentions guix
        *) continue ;;
    esac
    # Strip the leading tab and any '@' / '-' recipe-line modifiers so the
    # command word is at the front.
    cmd=$(printf '%s' "$line" | sed 's/^	*//; s/^[@-]*//; s/^[[:space:]]*//')
    case $cmd in
        '#'*) continue ;;               # a comment inside a recipe (`@# ...')
        echo\ *|printf\ *) continue ;;  # printing text ABOUT guix, not running it
    esac
    case $line in
        *'guix describe'*) continue ;;  # allowlisted, see above
        *'$(GUIX)'*) continue ;;        # pinnable: honours TIME_MACHINE
        *'$(call guix-shell'*) continue ;;  # toolchain only, not a build
    esac
    note "Makefile:$lineno invokes guix outside \$(GUIX): $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
done < "$makefile"

if [ "$fail" -eq 0 ]; then
    printf 'PASS: every Makefile recipe invoking guix goes through $(GUIX)\n'
    printf '      (so TIME_MACHINE=1 pins it to channels.scm), or is\n'
    printf '      allowlisted with a reason.\n'
fi
exit "$fail"
