#!/bin/sh
# wifi-cycle.sh -- ON THE DEVICE (root).  Hands-off suspend/resume cycling
# through the platform-controls broker, judged from the device's own logs.
# Copy to /data/wilkbook/tools/ (no make target; a device-side instrument,
# rung 6 -- doc/testing.md).  The 2026-09-03/04 and 2026-09-04 rigs in
# doc/status.md ran this script.
#
#   wifi-cycle.sh start [BACKSTOP_S] [SETTLE_S]
#       autosuspend.conf <- enabled=1 suspend_while_charging=1 backstop=B rtc_settle=S
#       (rtc_settle needs generation 12+), then one injected power tap: the
#       broker suspends, the RTC wakes it B s later, the broker restores
#       Wi-Fi, stays awake S s, re-suspends -- until stop.
#   wifi-cycle.sh koreader-idle SECONDS
#       set KOReader's AutoSuspend timeout (product default 900) so KOReader's
#       own idle timer initiates the sleeps -- the path that turns Wi-Fi off
#       first and must restore it on the wake.  Restarts the reader.
#       TRAP: KOReader's timer never fires while the battery reports
#       Charging (its own rule), and the RK817 flaps to Charging with the USB
#       cable in even at 99 %: unplug the cable or you measure the broker
#       path only (2026-09-04).
#   wifi-cycle.sh stop        autosuspend.conf <- enabled=1 (charging inhibits
#                             suspend again; the cycling ends at the next wake)
#                             -- then write enabled=0 yourself before the
#                             device sleeps, or the next ssh window is the
#                             hourly backstop's 20 s (doc/device-access.md).
#   wifi-cycle.sh report      counts from the broker log and the control
#                             script's own log (/run/wilkbook-power/wifi.log),
#                             for the segment after the LAST start mark.
#
# Host-side driver (what the sessions ran): start, sleep N*(B+S+20) s, then
# stop across the reader's awake windows, then report:
#   ssh DEV 'sh /data/wilkbook/tools/wifi-cycle.sh start 45 300'
#   sleep $((15*(45+300+20)))
#   until ssh DEV 'sh /data/wilkbook/tools/wifi-cycle.sh stop'; do sleep 10; done
#   ssh DEV 'sh /data/wilkbook/tools/wifi-cycle.sh report'
set -u
CONF=/data/wilkbook/autosuspend.conf
BLOG=/var/log/pinenote-platform-controls.log
WLOG=/run/wilkbook-power/wifi.log
cmd=${1:?start|stop|report|koreader-idle}
pwrkey() { for e in /sys/class/input/event*; do [ "$(cat $e/device/name 2>/dev/null)" = "rk805 pwrkey" ] && { echo /dev/input/${e##*/}; return 0; }; done; return 1; }
tap() {
  dev=$(pwrkey) || { echo "no rk805 pwrkey"; return 1; }
  # struct input_event on arm64: timeval (16 bytes) + type u16 + code u16 + value s32
  # = 24 bytes, little-endian; evdev rejects partial events, so each event is
  # ONE printf call (one write).  EV_KEY=1, KEY_POWER=116 (0164 octal), EV_SYN=0.
  key() { printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\001\0\164\0'"$(printf '\\%03o' "$1")"'\0\0\0'; }
  syn() { printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0'; }
  { key 1; syn; sleep 0.3; key 0; syn; } > "$dev"
  echo "tap injected into $dev"
}
case $cmd in
start)
  bs=${2:-60}; settle=${3:-60}
  printf 'enabled=1\nsuspend_while_charging=1\nbackstop=%s\nrtc_settle=%s\n' "$bs" "$settle" > $CONF; cat $CONF
  : > $WLOG 2>/dev/null || true
  sleep 1; echo "== $(date +%T) mark: cycle test start backstop=$bs settle=$settle" >> $BLOG
  tap ;;
stop)
  printf 'enabled=1\n' > $CONF; cat $CONF; echo "== $(date +%T) mark: cycle test stop" >> $BLOG ;;
koreader-idle)
  # Set KOReader's AutoSuspend idle timeout (seconds; the product default is
  # 900) so the rig can make KOReader itself initiate the sleeps -- the path
  # where it turns Wi-Fi off first and must restore it on the wake.  The
  # reader is stopped while its settings file is edited (KOReader rewrites
  # the file on flush) and started again.
  secs=${2:?seconds}; f=/root/.config/koreader/settings.reader.lua
  herd stop reader-session >/dev/null 2>&1; sleep 2
  if grep -q '\["auto_suspend_timeout_seconds"\]' $f; then sed -i "s/\[\"auto_suspend_timeout_seconds\"\] = [0-9]*/[\"auto_suspend_timeout_seconds\"] = $secs/" $f
  else sed -i "s/^return {/return {\n    [\"auto_suspend_timeout_seconds\"] = $secs,/" $f; fi
  grep -o '\["auto_suspend_timeout_seconds"\] = [0-9]*' $f
  herd start reader-session >/dev/null 2>&1; sleep 3; herd status reader-session | sed -n 2p ;;
report)
  # the segment after the LAST start mark (an awk that latches on the first mark counts every earlier run too)
  seg() { tac $BLOG | awk '/mark: cycle test start/{print; exit} {print}' | tac | grep -a .; }
  echo "== broker, since the last start mark:"
  echo "transactions ok:     $(seg | grep -a -c 'transaction complete ok=true')"
  echo "rtc wakes:           $(seg | grep -a -c 'detail=rtc')"
  echo "button wakes:        $(seg | grep -a -c 'detail=button')"
  echo "koreader-initiated:  $(seg | grep -a -c 'trigger=koreader')"
  echo "rtc-initiated:       $(seg | grep -a -c 'trigger=rtc')"
  echo "power-initiated:     $(seg | grep -a -c 'trigger=power')"
  echo "restore failed:      $(seg | grep -a -c 'Wi-Fi restore failed')"
  echo "== control script (wifi.log), since start:"
  for k in "on pid=" "adopted existing" "wlan0 absent" "rebound brcmfmac" "wlan0 unavailable" "associated within" "no association within" "restarting the supplicant" "associated after the restart" "still no association" "supplicant restart failed" "pinenote-wifi: off"; do printf "  %-30s %s\n" "$k" "$(grep -a -c "$k" $WLOG 2>/dev/null || echo 0)"; done
  echo "== last 12 wifi.log lines:"; tail -12 $WLOG 2>/dev/null
  echo "== now: wlan0 carrier $(cat /sys/class/net/wlan0/carrier 2>/dev/null || echo absent); suspend_stats $(cat /sys/power/suspend_stats/success)/$(cat /sys/power/suspend_stats/fail); dmesg warnings: $(dmesg | grep -c -i -E 'WARNING:|brcmf_sdio_bus_rxctl|attach failed')"
  echo "== koreader wifi_was_on now: $(grep -o '\["wifi_was_on"\] = [a-z]*' /root/.config/koreader/settings.reader.lua)" ;;
esac
