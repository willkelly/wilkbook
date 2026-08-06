#!/bin/sh
# Deep-suspend draw audit: does manually killing every peripheral before
# suspend change the suspended draw?
#
# Null hypothesis: no -- the suspend path powers all of it down already,
# and D1 == D2.  A delta names a leak.  20.6 mA suspended is high for
# this class of device (Kindle-class is 2-6 mA), so this is worth
# falsifying properly.
#
#   D1: deep suspend the way auto-suspend does it (gadget unbound, all
#       else normal), WINDOW seconds by RTC alarm.
#   D2: wifi driver removed, BT serdev unbound, touch (tt21000) and pen
#       (w9013) unbound, reader/bridge stopped, fbcon unbound -- then the
#       same window.
#
# Also answers, for free: does bl31's resume path preserve a non-boot
# DDR rate (device enters at 324 MHz)?
#
# Everything restores unconditionally at the end (trap); results also go
# to /data (survives reboot and reflash).  If the wifi rebind fails the
# operator recovers by UART reboot, which restores everything anyway.
set -u
W=${W:-900}
B=/sys/class/power_supply/rk817-battery
D=/sys/kernel/debug/ddr-dvfs-test
G=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
OUT=/tmp/deep-audit.txt
: > "$OUT"
say() { echo "$(date +%s) $*" >> "$OUT"; cp "$OUT" /data/wilkbook-staging/deep-audit.txt 2>/dev/null; }

deep() { # $1 label -> writes rate + suspend stats
	UDC=$(cat $G 2>/dev/null); [ -n "$UDC" ] && { printf '\n' > $G; sleep 1; }
	echo deep > /sys/power/mem_sleep
	echo 0 > /sys/class/rtc/rtc0/wakealarm
	echo $(( $(cat /sys/class/rtc/rtc0/since_epoch) + W )) > /sys/class/rtc/rtc0/wakealarm
	S0=$(cat /sys/power/suspend_stats/success)
	C0=$(cat $B/charge_now); T0=$(date +%s)
	sync
	echo mem > /sys/power/state 2>/dev/null
	C1=$(cat $B/charge_now); T1=$(date +%s)
	S1=$(cat /sys/power/suspend_stats/success)
	[ -n "$UDC" ] && printf '%s' "$UDC" > $G 2>/dev/null
	SEC=$((T1-T0))
	R=$(awk -v a=$C0 -v b=$C1 -v s=$SEC 'BEGIN{printf "%.1f", (a-b)/1000.0*3600.0/s}')
	say "DEEP $1: ${R} mA over ${SEC}s  suspends $S0->$S1  ddr_after=$(cat $D/current 2>/dev/null | cut -d" " -f1)"
}

say "=== deep-suspend draw audit, W=${W}s, cap=$(cat $B/capacity)%, ddr=$(cat $D/current 2>/dev/null | cut -d' ' -f1) ==="

# ---------- D1: the normal path ----------
deep "D1-normal"

# bl31 resume may have reset the rate; re-assert 324 for D2 comparability
# (EBC will be quiesced below before we switch)
RATE_AFTER_D1=$(cat $D/current 2>/dev/null | cut -d' ' -f1)

# ---------- D2 prep: kill everything ----------
RESTORE_WIFI=0; RESTORE_BT=0; RESTORE_TOUCH=""; RESTORE_PEN=""
restore() {
	say "RESTORE begin"
	[ "$RESTORE_WIFI" = 1 ] && { modprobe brcmfmac 2>/dev/null; sleep 3; say "  wifi: modprobe brcmfmac rc=$?"; }
	[ "$RESTORE_BT" = 1 ] && { printf 'serial0-0\n' > /sys/bus/serial/drivers/hci_uart_bcm/bind 2>/dev/null; say "  bt rebound"; }
	[ -n "$RESTORE_TOUCH" ] && { printf '%s\n' "$RESTORE_TOUCH" > /sys/bus/i2c/drivers/tt21000/bind 2>/dev/null \
		|| printf '%s\n' "$RESTORE_TOUCH" > "$(cat /tmp/touch-drv 2>/dev/null)/bind" 2>/dev/null; say "  touch rebound ($RESTORE_TOUCH)"; }
	[ -n "$RESTORE_PEN" ] && { printf '%s\n' "$RESTORE_PEN" > "$(cat /tmp/pen-drv 2>/dev/null)/bind" 2>/dev/null; say "  pen rebound ($RESTORE_PEN)"; }
	# back to boot DDR rate via module unload (requires EBC idle: reader
	# is still stopped here), then bring userspace back
	rmmod ddr_dvfs_test 2>/dev/null && say "  ddr module unloaded (boot rate restored)"
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
	herd start orientation-bridge >/dev/null 2>&1
	herd start reader-session >/dev/null 2>&1
	rm -f /var/lib/pinenote/autosuspend.conf
	say "RESTORE done: scmi_ddr=$(grep clk_scmi_ddr /sys/kernel/debug/clk/clk_summary | awk '{print $5}') reader=$(pgrep -c -f 'reade[r].lua')"
	cp "$OUT" /data/wilkbook-staging/deep-audit.txt 2>/dev/null
	echo DONE > /tmp/deep-audit.done
}
trap restore EXIT INT TERM

herd stop reader-session >/dev/null 2>&1
P=$(pgrep -f 'reade[r].lua' | head -3); [ -n "$P" ] && kill $P 2>/dev/null
herd stop orientation-bridge >/dev/null 2>&1
sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank 2>/dev/null

# re-assert 324 if resume reset it (EBC idle: everything display-side stopped)
A=$(grep " fdec0000.ebc" /proc/interrupts | awk '{print $2+$3+$4+$5}'); sleep 4
Z=$(grep " fdec0000.ebc" /proc/interrupts | awk '{print $2+$3+$4+$5}')
if [ "$((Z-A))" = "0" ] && [ "$RATE_AFTER_D1" != "324000000" ]; then
	echo 324 > $D/set_rate 2>/dev/null
	say "re-asserted 324 after D1 resume (was $RATE_AFTER_D1)"
fi

# touch: find the tt21000 i2c device + driver
for dev in /sys/bus/i2c/devices/*; do
	case "$(cat $dev/name 2>/dev/null)" in
	tt21000)
		RESTORE_TOUCH=$(basename $dev)
		readlink -f $dev/driver > /tmp/touch-drv
		printf '%s\n' "$RESTORE_TOUCH" > "$(readlink -f $dev/driver)/unbind" && say "touch unbound ($RESTORE_TOUCH)" ;;
	w9013)
		RESTORE_PEN=$(basename $dev)
		readlink -f $dev/driver > /tmp/pen-drv
		printf '%s\n' "$RESTORE_PEN" > "$(readlink -f $dev/driver)/unbind" && say "pen unbound ($RESTORE_PEN)" ;;
	esac
done
# BT
if [ -e /sys/bus/serial/devices/serial0-0/driver ]; then
	printf 'serial0-0\n' > /sys/bus/serial/devices/serial0-0/driver/unbind && RESTORE_BT=1 && say "bt unbound"
fi
# wifi last (kills ssh)
ip link set wlan0 down 2>/dev/null
if rmmod brcmfmac 2>/dev/null; then RESTORE_WIFI=1; say "wifi: brcmfmac removed"; else
	say "wifi: rmmod failed, leaving driver (D2 less clean)"; fi
sleep 3

# ---------- D2: everything dead ----------
deep "D2-stripped"

say "=== audit complete; restoring ==="
# trap runs restore on exit
