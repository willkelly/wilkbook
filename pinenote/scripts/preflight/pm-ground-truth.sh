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

# Wakeup sources, WITH COUNTS -- not just names.
#
# The names-only form could say which sources were armed but never which one
# actually fired, so "what woke it?" stayed a hardware question. The counters
# plus /sys/power/pm_wakeup_irq are the attribution: pm_wakeup_irq names the
# IRQ that ended the last suspend, which is the discriminator the cover-wake
# investigation needs (the cover switch and the rk817 pwrkey are different
# interrupts). Same fields pinenote/tools/power/power-snapshot.scm already
# records, so the vocabulary is not new.
echo "== wakeup sources"
for r in /sys/class/wakeup/wakeup*; do
  [ -e "$r/name" ] || continue
  printf '%s:active=%s:event=%s:wakeup=%s:expire=%s\n' \
    "$(cat "$r/name" 2>/dev/null || echo '?')" \
    "$(cat "$r/active_count" 2>/dev/null || echo '?')" \
    "$(cat "$r/event_count" 2>/dev/null || echo '?')" \
    "$(cat "$r/wakeup_count" 2>/dev/null || echo '?')" \
    "$(cat "$r/expire_count" 2>/dev/null || echo '?')"
done | sort
printf 'wakeup_count=%s\n' "$(cat /sys/power/wakeup_count 2>/dev/null || echo '?')"
printf 'pm_wakeup_irq=%s\n' "$(cat /sys/power/pm_wakeup_irq 2>/dev/null || echo '?')"

echo "== battery"
for f in charge_now charge_full voltage_now capacity status; do
  printf '%s=%s\n' "$f" "$(cat /sys/class/power_supply/rk817-bat*/$f 2>/dev/null || echo '?')"
done

# Memory. The README advertises a boot-RAM figure whose only provenance was a
# one-off reading nobody can reproduce; capturing it here means the number
# comes out of the same staged, SHA-verified capture as everything else, for
# free, on every run -- rather than costing its own supervised session.
echo "== memory"
for f in MemTotal MemFree MemAvailable Buffers Cached Shmem Slab; do
  printf '%s\n' "$(grep "^$f:" /proc/meminfo 2>/dev/null || echo "$f: ?")"
done
free -m 2>/dev/null || echo "free unavailable"
echo "-- top RSS"
ps -eo rss,comm --sort=-rss 2>/dev/null | head -20 || echo "ps unavailable"

echo "== suspend state"
cat /sys/power/mem_sleep 2>/dev/null || echo "mem_sleep unavailable"
printf 'ebc_irq=%s\n' "$(grep fdec0000.ebc /proc/interrupts | awk '{print $2}')"
echo "== end"
