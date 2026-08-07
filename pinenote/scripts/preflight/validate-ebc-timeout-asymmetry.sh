#!/bin/sh
# Structural gate: the EBC's two refresh paths have DIFFERENT timeout
# budgets, and the hardware reports no starvation at all.
#
# Why this needs a gate.  On 2026-08-06 the absence of EBC timeouts in a
# boot's dmesg was used as evidence that a DDR rate switch could NOT have
# corrupted the panel ("a 107 ms stall must blow the 25 ms frame budget").
# That inference is wrong, and it cost a night of chasing the wrong
# suspect, because:
#
#   * 25 ms (EBC_FRAME_TIMEOUT) is armed ONLY in the partial path, once
#     per frame.
#   * A global refresh is a single hardware transaction -- one DSP_START
#     carrying DSP_FRM_TOTAL -- covered by ONE wait of 3000 ms
#     (EBC_REFRESH_TIMEOUT) for ~600 ms of drive.  A 107 ms stall fits
#     inside that budget four times over, so it is invisible by
#     construction.
#   * The controller has no underrun/starvation interrupt: INT_STATUS
#     carries only frame/display-end and line-flag bits.  A starved fetch
#     drives wrong voltages and says nothing.
#
# So "no timeouts in dmesg" is not evidence of an undisturbed refresh --
# for the global path it is the PREDICTED signature of a disturbed one.
# If a rebase ever unifies these budgets or adds a starvation interrupt,
# that reasoning changes and this gate should be revisited rather than
# silently passing.
#
# Usage: validate-ebc-timeout-asymmetry.sh [patch]
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
patch=${1:-$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch}

fail() { echo "FAIL: $1" >&2; exit 1; }

section=$(awk '/^diff --git a\/drivers\/gpu\/drm\/rockchip\/rockchip_ebc.c/{f=1}
               f && /^diff --git/ && !/rockchip_ebc.c/{exit} f{print}' "$patch")
[ -n "$section" ] || fail "no rockchip_ebc.c section in $patch"
added=$(printf '%s\n' "$section" | sed -n 's/^+//p')

# 1. Both constants must still exist, and still differ.
frame_ms=$(printf '%s\n' "$added" |
  sed -n 's/.*EBC_FRAME_TIMEOUT[[:space:]]*msecs_to_jiffies(\([0-9]*\)).*/\1/p' |
  head -1)
refresh_ms=$(printf '%s\n' "$added" |
  sed -n 's/.*EBC_REFRESH_TIMEOUT[[:space:]]*msecs_to_jiffies(\([0-9]*\)).*/\1/p' |
  head -1)
[ -n "$frame_ms" ] || fail "EBC_FRAME_TIMEOUT no longer defined in ms"
[ -n "$refresh_ms" ] || fail "EBC_REFRESH_TIMEOUT no longer defined in ms"
[ "$frame_ms" -lt "$refresh_ms" ] || fail \
  "timeout asymmetry gone: frame=${frame_ms}ms refresh=${refresh_ms}ms"

# 2. The per-frame budget must be used ONCE, and the global budget must
#    be the one the global path waits on.  If EBC_FRAME_TIMEOUT ever
#    starts guarding the global path too, a stall there becomes
#    detectable and the reasoning above is obsolete.
frame_uses=$(printf '%s\n' "$added" | grep -c 'EBC_FRAME_TIMEOUT' || true)
[ "$frame_uses" -eq 2 ] || fail \
  "EBC_FRAME_TIMEOUT appears ${frame_uses}x (expected 2: definition + the single partial-path wait)"

# the call wraps across two lines, so match the argument in its context
printf '%s\n' "$added" | grep -B2 'EBC_REFRESH_TIMEOUT)' |
  grep -q 'wait_for_completion_timeout(&ebc->display_end' ||
  fail "the global path no longer waits on display_end with EBC_REFRESH_TIMEOUT"

# 3. No starvation reporting exists.  These are the only status bits the
#    handler can see; an underrun/FIFO bit appearing here would mean the
#    silence is no longer structural.  (Written as an if, not
#    `grep && fail`: under set -e a correctly-not-matching grep would
#    take the whole script down with it.)
if printf '%s\n' "$added" |
     grep -qiE '(UNDERRUN|UNDER_RUN|FIFO_EMPTY)_INT'; then
  fail "a starvation/underrun status bit appeared -- silence is no longer structural"
fi

echo "PASS: EBC timeout asymmetry intact (frame ${frame_ms}ms partial-only, global ${refresh_ms}ms, no starvation interrupt)"
