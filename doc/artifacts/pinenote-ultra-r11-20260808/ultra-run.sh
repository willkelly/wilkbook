#!/bin/sh
# One supervised suspend for the ultra firmware-handshake test.
#   $1 = label (r9-control | r10-armed)
#   $2 = ultra_arm value written immediately before the suspend (0 or 5)
#
# Mirrors the PROVEN path in pinenote/tools/power/autosuspend.lua, because
# a hand-rolled `echo mem > /sys/power/state` does NOT reach firmware:
#   * mem_sleep must be forced to deep AND verified (else s2idle silently)
#   * the ACM gadget must be unbound from the UDC first -- otherwise dwc3
#     returns -EAGAIN and PM unwinds before bl31 is ever asked (observed
#     2026-08-07, aborted the first control run at 5 s)
#   * the EBC must be quiet before entry or the glass cache desyncs
# Evidence lands on p7 so it survives an os2 reflash AND a no-resume.
set -u
LBL="$1"; ARM="${2:-0}"
P=/sys/module/rockchip_suspend_mode_drv/parameters/ultra_arm
UDC=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
OUT=/data/wilkbook/ultra-$LBL.log
B=/sys/class/power_supply/rk817-battery

ebc_irq() { grep -i ebc /proc/interrupts | awk '{s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s}' | head -1; }

{
echo "=== $LBL START $(date -Is)"
echo "battery: $(cat $B/capacity)% $(cat $B/status) charge_now=$(cat $B/charge_now)"
echo "vcom-regulator:"
grep -r . /sys/kernel/debug/regulator/vcom/fdec0000.ebc-vcom/ 2>/dev/null | head -6
echo "suspend_stats before: ok=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"

# 1. deep, verified -- refuse rather than silently do s2idle
echo deep > /sys/power/mem_sleep
MS=$(cat /sys/power/mem_sleep)
echo "mem_sleep=$MS"
case "$MS" in
  *"[deep]"*) ;;
  *) echo "ABORT: deep unavailable"; exit 1 ;;
esac

# 2. EBC quiet: 5 consecutive equal samples at 500 ms
i=0; stable=0; last=$(ebc_irq)
while [ $i -lt 40 ]; do
  sleep 0.5; cur=$(ebc_irq)
  if [ "$cur" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
  last=$cur; i=$((i + 1))
  [ $stable -ge 5 ] && break
done
echo "ebc idle: stable=$stable irq=$last (after $i samples)"
if [ $stable -lt 5 ]; then echo "ABORT: EBC still active"; exit 1; fi

# 3. quiesce the gadget -- the step whose absence aborted the first run
SAVED=$(cat $UDC 2>/dev/null || echo "")
echo "udc saved=[$SAVED] -- unbinding"
printf '\n' > $UDC
echo "udc now=[$(cat $UDC 2>/dev/null)]"

# 4. arm (or explicitly disarm) the firmware handshake
echo "$ARM" > "$P"
echo "ultra_arm armed to: $(cat $P)"

# 5. RTC backstop
echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + 60)) > /sys/class/rtc/rtc0/wakealarm
echo "wakealarm=$(cat /sys/class/rtc/rtc0/wakealarm) now=$NOW"
sync

echo "### WILKBOOK $LBL ENTERING SUSPEND arm=$ARM ###" > /dev/console
T0=$(cat /sys/class/rtc/rtc0/since_epoch)
echo mem > /sys/power/state
RC=$?
T1=$(cat /sys/class/rtc/rtc0/since_epoch)
echo "### WILKBOOK $LBL RESUMED rc=$RC slept=$((T1 - T0))s ###" > /dev/console

echo "resumed rc=$RC slept=$((T1 - T0))s at $(date -Is)"
echo "ultra_arm after (0 = consumed and self-cleared): $(cat $P)"
echo "suspend_stats after: ok=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"
echo "battery: $(cat $B/capacity)% charge_now=$(cat $B/charge_now)"

# 6. restore the gadget
[ -n "$SAVED" ] && printf '%s' "$SAVED" > $UDC
echo "udc restored=[$(cat $UDC 2>/dev/null)]"
echo "dmesg tail:"
dmesg | tail -25
echo "=== $LBL END $(date -Is)"
} >> "$OUT" 2>&1
sync
