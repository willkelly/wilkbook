#!/bin/sh
# Read-only PM ground-truth capture, run ON THE DEVICE. Emits a stable,
# diffable snapshot of everything the suspend qualification ladder needs to
# compare pre/post: the TPS65185 register file, regulator states, wakeup
# sources, and battery telemetry. This is the productized form of the
# 2026-08-01 capture (doc/artifacts/pinenote-pm-live-harvest-20260801.md)
# and the acceptance instrument for the first `deep` case
# (doc/power-management.md): run before suspend, run after resume, diff.
#
# TPS65185 note: the register dump does live I2C reads for uncached
# registers, including the read-to-clear INT1/INT2 — run it only when the
# EBC is idle (no temperature conversion pending) or accept eating a
# TMST completion. VCOM1 should always read the device calibration (0x8f
# on this unit); a post-resume dump reading the factory default 0x7D
# instead would mean the NVM assumption failed — stop the ladder there.
set -eu

echo "# pm-ground-truth $(uname -r) $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-time)"

echo "== tps65185 registers (i2c 3-0068 regmap)"
for d in /sys/kernel/debug/regmap/*; do
  [ -e "$d/name" ] || continue
  if [ "$(cat "$d/name")" = "tps65185" ]; then
    cat "$d/registers"
  fi
done

echo "== regulators name:state:users:suspend-mem"
for r in /sys/class/regulator/regulator.*; do
  [ -e "$r/name" ] || continue
  printf '%s:%s:%s:%s\n' \
    "$(cat "$r/name" 2>/dev/null)" \
    "$(cat "$r/state" 2>/dev/null)" \
    "$(cat "$r/num_users" 2>/dev/null)" \
    "$(cat "$r/suspend_mem_state" 2>/dev/null || echo '?')"
done

echo "== wakeup sources"
for w in /sys/class/wakeup/wakeup*/name; do
  [ -e "$w" ] && cat "$w"
done | sort

echo "== battery"
for f in charge_now charge_full voltage_now capacity status; do
  printf '%s=%s\n' "$f" "$(cat /sys/class/power_supply/rk817-bat*/$f 2>/dev/null || echo '?')"
done

echo "== suspend state"
cat /sys/power/mem_sleep 2>/dev/null || echo "mem_sleep unavailable"
printf 'ebc_irq=%s\n' "$(grep fdec0000.ebc /proc/interrupts | awk '{print $2}')"
echo "== end"
