#!/bin/sh
# Structural gate over the TPS65185 suspend/resume hunk in the forward-port
# patch (doc/power-management.md, "Evidence pass (2026-08-01)").  The hunk
# restores chip registers after a SLEEP reset; the properties below are the
# load-bearing ones, and VCOM protection is the same class as
# never-bundle-the-waveform: VCOM lives in chip NVM as the per-device
# calibration and software must never write it.
#
# Usage: validate-tps65185-pm-hunk.sh [patch]   (default: the repo patch)
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
patch=${1:-$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch}

fail() { echo "FAIL: $1" >&2; exit 1; }

# The tps65185 file-diff section only.
section=$(awk '/^diff --git a\/drivers\/regulator\/tps65185.c/{f=1}
               f && /^diff --git/ && !/tps65185/{exit} f{print}' "$patch")
[ -n "$section" ] || fail "no tps65185 section in $patch"

# Added lines only (strip the leading +): what the hunk actually ships.
added=$(printf '%s\n' "$section" | sed -n 's/^+//p')

require() {
  printf '%s\n' "$added" | grep -qF "$1" || fail "missing: $1"
}

# 1. The PM ops exist and are wired.
require "static int tps65185_suspend(struct device *dev)"
require "static int tps65185_resume(struct device *dev)"
require "DEFINE_SIMPLE_DEV_PM_OPS(tps65185_pm_ops,"
require ".pm = pm_sleep_ptr(&tps65185_pm_ops),"

# 2. VCOM is never in the restore set and never written by PM code.
pm_code=$(printf '%s\n' "$added" | sed -n '/tps65185_pm_regs\[TPS65185_NUM_PM_REGS\]/,/DEFINE_SIMPLE_DEV_PM_OPS/p')
[ -n "$pm_code" ] || fail "cannot isolate the PM code block"
if printf '%s\n' "$pm_code" | grep -q "VCOM"; then
  # Allowed only inside comments explaining the exemption; forbid code refs.
  printf '%s\n' "$pm_code" | grep "VCOM" | grep -vq '^\s*\*' \
    && fail "PM code references a VCOM register (per-device calibration; NVM-backed; must never be written)" \
    || true
fi
printf '%s\n' "$pm_code" | grep -q "TPS65185_REG_VCOM" \
  && fail "restore set contains a VCOM register" || true

# 3. TMST1 (write-trigger bit) is excluded from the restore set.
printf '%s\n' "$pm_code" | grep -q "TPS65185_REG_TMST1," \
  && fail "restore set contains TMST1 (READ_THERM is a write-trigger)" || true

# 4. The EEPROM reload window is waited out before any restore write.
resume_body=$(printf '%s\n' "$added" | sed -n '/static int tps65185_resume/,/^}/p')
msleep_line=$(printf '%s\n' "$resume_body" | grep -n "msleep(TPS65185_WAKEUP_DELAY_MS)" | cut -d: -f1 | head -1)
write_line=$(printf '%s\n' "$resume_body" | grep -n "regmap_write" | cut -d: -f1 | head -1)
[ -n "$msleep_line" ] || fail "resume does not wait out the EEPROM reload window"
[ -n "$write_line" ] || fail "resume performs no restore writes"
[ "$msleep_line" -lt "$write_line" ] || fail "restore writes precede the EEPROM reload wait"

# 5. Restoration is cache-through (regmap_write), never regcache_sync
#    (REGCACHE_MAPLE would mask restores of believed-unchanged values).
printf '%s\n' "$pm_code" | grep -q "regcache_sync" \
  && fail "restore uses regcache_sync (defeated by REGCACHE_MAPLE)" || true

# 6. ENABLE is the last entry in the restore array (rails power up only
#    after sequencing is restored).
last_reg=$(printf '%s\n' "$pm_code" | grep "TPS65185_REG_" | grep -v "NUM_PM_REGS" | tail -1)
printf '%s\n' "$last_reg" | grep -q "TPS65185_REG_ENABLE" \
  || fail "ENABLE is not the last restore entry (rails before sequencing)"

echo "PASS: tps65185 PM hunk structural gate"
