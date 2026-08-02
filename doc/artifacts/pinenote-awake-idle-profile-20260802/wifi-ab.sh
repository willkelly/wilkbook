#!/bin/sh
# Attribute the Wi-Fi share of awake-idle draw.  Detached: phase B takes
# the interface down, which kills ssh.
set -u
E=/tmp/wifi-ab; rm -rf $E; mkdir -p $E; LOG=$E/wifi.log
P=${P:-480}
log() { echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
chg() { cat /sys/class/power_supply/rk817-battery/charge_now; }
rate() { awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN{printf "%.1f", (a-b)/1000.0*3600.0/s}'; }
irqsum() { awk '/dw-mci|brcmf|mmc/{for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END{print s+0}' /proc/interrupts; }

restore() {
	ip link set wlan0 up 2>/dev/null
	herd start networking >/dev/null 2>&1 || true
	sleep 20
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	herd start reader-session >/dev/null 2>&1
	log "restored: wlan0=$(ip -br link show wlan0 2>/dev/null | awk '{print $2}')"
	echo DONE > $E/COMPLETE
}
trap restore EXIT HUP INT TERM

herd stop reader-session >/dev/null 2>&1; sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank 2>/dev/null; sleep 2
log "=== WIFI AB START (${P}s per phase) ==="

# A: wifi up (as measured before)
a0=$(chg); i0=$(irqsum); t0=$(date +%s); sleep "$P"
a1=$(chg); i1=$(irqsum); t1=$(date +%s); ta=$((t1-t0))
log "PHASE A wifi-UP  : ${ta}s $a0 -> $a1 uAh, $(rate $a0 $a1 $ta) mA, sdio+mmc irqs $(( (i1-i0)/ta ))/s"

# B: wifi down
ip link set wlan0 down 2>/dev/null
sleep 5
b0=$(chg); j0=$(irqsum); s0=$(date +%s); sleep "$P"
b1=$(chg); j1=$(irqsum); s1=$(date +%s); tb=$((s1-s0))
log "PHASE B wifi-DOWN: ${tb}s $b0 -> $b1 uAh, $(rate $b0 $b1 $tb) mA, sdio+mmc irqs $(( (j1-j0)/tb ))/s"

RA=$(rate $a0 $a1 $ta); RB=$(rate $b0 $b1 $tb)
awk -v ra="$RA" -v rb="$RB" 'BEGIN{ printf "wifi share: %.1f mA (%.0f%% of awake-idle)\n", ra-rb, (ra-rb)/ra*100 }' >> "$LOG"
exit 0
