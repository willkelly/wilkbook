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

# Input axes. Two open issues each needed one EVIOCGABS read -- the
# touchscreen's ABS_MT_SLOT range (#21: how many MT slots, and is
# KOReader's pen_slot = main_finger_slot + 4 inside it) and the stylus's
# pressure/tilt/hover ranges (#20: is there enough signal for real ink).
# Both fall out of a capture that already runs, the way memory and wake
# attribution do, rather than costing their own supervised session.
#
# Presence is read from the sysfs ABS bitmap, NOT inferred from the
# ioctl: EVIOCGABS succeeds for every code on any device that has
# absinfo at all, so an all-zero struct cannot be told apart from an
# absent axis (the 2026-08-24 probe used a zeros heuristic and got away
# with it; this does not have to).
#
# The reader image has no python, perl, evtest or standalone lua -- only
# a shell and KOReader's bundled luajit. Everything here is guarded so
# the script still succeeds where luajit or the devices are absent.
echo "== input axes"
abs_luajit=""
if [ -n "${KO:-}" ] && [ -x "${KO}/luajit" ]; then
  abs_luajit="${KO}/luajit"
elif command -v luajit >/dev/null 2>&1; then
  abs_luajit=$(command -v luajit)
else
  for c in /gnu/store/*-koreader-bin-*/lib/koreader/luajit; do
    if [ -x "$c" ]; then abs_luajit=$c; break; fi
  done
fi

abs_nodes=""
for d in /dev/input/event*; do
  [ -e "$d" ] || continue
  abs_nodes="$abs_nodes $d"
done

if [ -z "$abs_luajit" ]; then
  echo "luajit unavailable (no \$KO/luajit, no luajit on PATH, no koreader-bin in the store)"
elif [ -z "$abs_nodes" ]; then
  echo "no /dev/input/event* nodes"
else
  abs_probe=${TMPDIR:-/tmp}/pm-ground-truth-absprobe.$$.lua
  # `if ! cat >` rather than a bare redirect: under `set -e` an
  # unwritable TMPDIR would otherwise abort the whole capture, and this
  # section is the least important thing in it.
  if ! cat > "$abs_probe" <<'ABSPROBE'
-- EVIOCGABS + sysfs-bitmap axis probe. Derived from the committed
-- doc/artifacts/pinenote-input-clocks-20260824/absprobe.lua; presence is
-- taken from the bitmap rather than from a zeroed absinfo struct.
local ffi = require("ffi")
ffi.cdef[[
int open(const char *pathname, int flags);
int ioctl(int fd, unsigned long request, ...);
int close(int fd);
struct input_absinfo { int value; int minimum; int maximum; int fuzz; int flat; int resolution; };
]]
local function EVIOCGABS(abs)  -- _IOR('E', 0x40+abs, struct input_absinfo /*24*/)
  return 0x80000000 + 24*0x10000 + 0x45*0x100 + (0x40 + abs)
end

local NAMES = {
  [0x00]="ABS_X",[0x01]="ABS_Y",[0x18]="ABS_PRESSURE",[0x19]="ABS_DISTANCE",
  [0x1a]="ABS_TILT_X",[0x1b]="ABS_TILT_Y",[0x28]="ABS_MISC",
  [0x2f]="ABS_MT_SLOT",[0x30]="ABS_MT_TOUCH_MAJOR",[0x31]="ABS_MT_TOUCH_MINOR",
  [0x35]="ABS_MT_POSITION_X",[0x36]="ABS_MT_POSITION_Y",
  [0x39]="ABS_MT_TRACKING_ID",[0x3a]="ABS_MT_PRESSURE",
}
local ORDER = {0x00,0x01,0x18,0x19,0x1a,0x1b,0x28,0x2f,0x30,0x31,0x35,0x36,0x39,0x3a}

local function readFirstLine(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  return line
end

-- The kernel prints one %lx word per unsigned long, HIGHEST word first,
-- with no zero padding -- so index from the RIGHT of each word string
-- rather than trying to turn a 64-bit bitmap into a Lua number (which
-- would lose precision above 2^53).
local function bitmapTester(line)
  if not line then return nil end
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then return nil end
  local byIndex = {}
  for i, w in ipairs(words) do byIndex[#words - i] = w end
  return function(code)
    local w = byIndex[math.floor(code / 64)]
    if not w then return false end
    local bit = code % 64
    local pos = #w - math.floor(bit / 4)
    if pos < 1 then return false end
    local nibble = tonumber(w:sub(pos, pos), 16)
    if not nibble then return false end
    return math.floor(nibble / 2 ^ (bit % 4)) % 2 == 1
  end
end

local function range(info)
  if not info then return "absent" end
  return string.format("%d..%d", info.min, info.max)
end

-- Overridable only so the bitmap parsing can be exercised at rung 1
-- against a fake sysfs tree; the device never sets it.
local SYSFS = os.getenv("PM_GT_SYSFS_ROOT") or "/sys/class/input"

for _, dev in ipairs(arg) do
  local ev = dev:match("([^/]+)$") or dev
  local sysfs = SYSFS .. "/" .. ev .. "/device"
  local absline = readFirstLine(sysfs .. "/capabilities/abs")
  local has = bitmapTester(absline)
  -- Skip nodes with no ABS axes at all (keys, switches, the orientation
  -- bridge): they are noise in a diff and answer neither question.
  if has and absline:match("[1-9a-f]") then
    local name = readFirstLine(sysfs .. "/name") or "?"
    print(string.format("node=%s name=%s", dev, name))
    -- Presence comes from the bitmap, so it is reported even when the
    -- node itself cannot be opened; only the ranges need the ioctl.
    local fd = ffi.C.open(dev, 0)  -- O_RDONLY
    if fd < 0 then print("  open failed (root required?)") end
    local info = fd >= 0 and ffi.new("struct input_absinfo") or nil
    local seen, absent = {}, {}
    for _, code in ipairs(ORDER) do
      if not has(code) then
        -- One compact line for every absent axis, rather than fourteen
        -- `present=no` lines per keyboard: still diffable, far less noise.
        absent[#absent + 1] = NAMES[code]
      elseif info and ffi.C.ioctl(fd, EVIOCGABS(code), info) == 0 then
        seen[code] = { min = info.minimum, max = info.maximum }
        print(string.format(
          "  %-20s min=%-8d max=%-8d fuzz=%-5d flat=%-5d res=%d",
          NAMES[code], info.minimum, info.maximum,
          info.fuzz, info.flat, info.resolution))
      else
        print(string.format("  %-20s range=unavailable", NAMES[code]))
      end
    end
    if fd >= 0 then ffi.C.close(fd) end
    print("  absent: " .. (#absent > 0 and table.concat(absent, " ") or "(none)"))
    -- One greppable line carrying both issues' answers.
    print(string.format(
      "  summary: mt_slots=%s mt_slot_max=%s pressure=%s tilt_x=%s tilt_y=%s distance=%s",
      seen[0x2f] and tostring(seen[0x2f].max + 1) or "absent",
      seen[0x2f] and tostring(seen[0x2f].max) or "absent",
      range(seen[0x18]), range(seen[0x1a]), range(seen[0x1b]), range(seen[0x19])))
  end
end
ABSPROBE
  then
    echo "cannot stage the abs probe in ${TMPDIR:-/tmp}"
  # shellcheck disable=SC2086
  elif ! "$abs_luajit" "$abs_probe" $abs_nodes; then
    echo "abs probe failed"
  fi
  rm -f "$abs_probe" 2>/dev/null || true
fi
# KOReader parks the pen at Input.main_finger_slot + 4 = slot 4. If
# mt_slots above is > 4 the pen sits inside the panel's slot space and
# the collision pinned by quirk:pen-slot-collision
# (pinenote/tools/koreader-input/) is reachable on this unit --
# doc/upstream-register.md item 11.

echo "== suspend state"
cat /sys/power/mem_sleep 2>/dev/null || echo "mem_sleep unavailable"
printf 'ebc_irq=%s\n' "$(grep fdec0000.ebc /proc/interrupts | awk '{print $2}')"
echo "== end"
