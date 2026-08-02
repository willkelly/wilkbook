#!/bin/sh
# Prove a HUMAN can wake the device from deep.  Auto-suspend is unsafe
# until this passes: without it the device sleeps and never comes back.
#
# An RTC alarm at +SAFETY seconds is armed as a backstop, so the device
# always returns even if the button does nothing.  A wake well before the
# alarm means the button worked.
set -u
E=/tmp/wake-test; rm -rf $E; mkdir -p $E; LOG=$E/wake.log
SAFETY=${SAFETY:-90}
log() { echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }

restore() {
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	echo fcc00000.usb > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
	herd start reader-session >/dev/null 2>&1
	echo DONE > $E/COMPLETE
}
trap restore EXIT HUP INT TERM

herd stop reader-session >/dev/null 2>&1; sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank 2>/dev/null
echo "" > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
sleep 2

echo deep > /sys/power/mem_sleep
case "$(cat /sys/power/mem_sleep)" in *"[deep]"*) ;; *) log "ABORT: no deep"; exit 1 ;; esac

# snapshot the power-key event counter so we can tell if it actually fired
KEY0=$(awk '/^ *[0-9]+:/ && /rk8/ {for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' /proc/interrupts)

echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + SAFETY)) > /sys/class/rtc/rtc0/wakealarm
log "safety alarm armed +${SAFETY}s. PRESS THE POWER BUTTON NOW."
echo "<0>WILKBOOK: wake-test entering deep -- press power button" > /dev/kmsg
sync

T0=$(date +%s)
echo mem > /sys/power/state 2>> "$E/err"; rc=$?
T1=$(date +%s); EL=$((T1-T0))
echo "<0>WILKBOOK: wake-test resumed after ${EL}s" > /dev/kmsg

ALARM_LEFT=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
KEY1=$(awk '/^ *[0-9]+:/ && /rk8/ {for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' /proc/interrupts)
log "RESUMED rc=$rc after ${EL}s (safety was ${SAFETY}s)"
log "rk8xx irq delta: $((KEY1-KEY0))   alarm field now: [${ALARM_LEFT}]"
if [ "$EL" -lt $((SAFETY - 15)) ]; then
	log "VERDICT: PASS -- woke at ${EL}s, well before the ${SAFETY}s safety alarm."
	log "         A human CAN wake this device from deep."
else
	log "VERDICT: FAIL -- only the RTC safety alarm brought it back."
	log "         Auto-suspend would strand the device."
fi
# drain any key event so it does not land in the reader
timeout 2 cat /dev/input/event0 > /dev/null 2>&1 || true
exit 0
