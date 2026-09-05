#!/bin/sh
# turn-check.sh -- ON THE DEVICE (root).  The injected-page-turn instrument
# that does not fall into the file-manager trap (doc/testing.md, "EBC IRQ
# counts"): opens the last book (start_with=last, for this run only), starts
# the optics-inject uinput device, restarts the reader so it enumerates it,
# confirms the "opening file" line, injects N KEY 158 page turns 3 s apart,
# and logs per turn the EBC IRQ total (at 0.6 s and 3 s), runtime_status, an
# md5 of /dev/fb0 (what KOReader wrote) and a hash of the driver's packed
# belief buffer (what the driver blitted).  Restores the settings file after.
# Needs, in T: optics-inject.lua, belief-grab.lua and ebclib.lua (this
# directory and pinenote/tools/optics).  No make target: copy to
# /data/wilkbook/tools/ and run `sh turn-check.sh 6`; the log is
# /root/turn-check.log.  Real turns cost ~47 IRQs each on the direct driver;
# 0 means the page did not change (2026-09-04).
set -u
N=${1:-6}
T=${T:-/data/wilkbook/tools}
# KOReader's bundled luajit (the one with the ffi the lab tools use): the
# running reader's, else the newest bundle in the store.
LJ=${LJ:-$(readlink -f /proc/$(pgrep -n -x luajit 2>/dev/null)/exe 2>/dev/null)}
[ -x "$LJ" ] || LJ=$(ls -d /gnu/store/*-koreader-bin-*/lib/koreader/luajit 2>/dev/null | tail -1)
[ -x "$LJ" ] || { echo "no luajit found; set LJ=" >&2; exit 2; }
F=/root/.config/koreader/settings.reader.lua
LOG=/root/turn-check.log
RL=/var/log/reader-session.log
irq() { awk '/fdec0000.ebc/ {print $2+$3+$4+$5}' /proc/interrupts; }
rs() { cat /sys/bus/platform/devices/fdec0000.ebc/power/runtime_status; }
belief() { LUA_PATH="$T/?.lua;;" $LJ $T/belief-grab.lua --out-prefix /root/tc >/dev/null 2>&1; sha256sum /root/tc-packed.bin | cut -c1-16; rm -f /root/tc-*.bin; }
# the framebuffer's own content (what KOReader wrote), separate from the driver's belief
fb() { md5sum /dev/fb0 | cut -c1-12; }
echo "== $(date -u +%T) start N=$N irq=$(irq) rs=$(rs) fb0/state=$(cat /sys/class/graphics/fb0/state 2>/dev/null) suspend_stats=$(cat /sys/power/suspend_stats/success)/$(cat /sys/power/suspend_stats/fail)" > $LOG
# rotation decides which way 158 turns (KOReader remaps RPgBack/RPgFwd at modes 1 and 2)
echo "rotation: closed_rotation_mode=$(grep -o '\["closed_rotation_mode"\] = [0-9]*' $F | grep -o '[0-9]*$') sidecar=$(grep -h -o '\["rotation_mode"\] = [0-9]*' /data/books/*.sdr/metadata.*.lua 2>/dev/null | grep -o '[0-9]*$' | tr '\n' ' ')" >> $LOG
herd stop reader-session >/dev/null 2>&1; sleep 2
echo "after reader stop: irq=$(irq)" >> $LOG
cp $F $F.pre-turncheck
if grep -q '"start_with"' $F; then sed -i 's/\["start_with"\] = "[a-z_]*"/["start_with"] = "last"/' $F
else sed -i 's/^return {/return {\n    ["start_with"] = "last",/' $F; fi
echo "settings: $(grep -o '\["start_with"\] = "[a-z_]*"' $F)" >> $LOG
rm -f /run/optics-inject.fifo /run/optics-inject.pid
setsid $LJ $T/optics-inject.lua </dev/null >/root/inject2.log 2>&1 &
i=0; while [ ! -e /run/optics-inject.pid ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
echo "injector: $(cat /root/inject2.log | tr '\n' ' ')" >> $LOG
n0=$(grep -a -c . $RL)
herd start reader-session >/dev/null 2>&1; sleep 12
echo "reader after start:" >> $LOG
tail -n +$n0 $RL | grep -a -E 'opening file|pn-refresh|optics' | head -6 | cut -c1-150 >> $LOG
echo "pre: irq=$(irq) rs=$(rs) fb=$(fb) belief=$(belief)" >> $LOG
for t in $(seq 1 $N); do
  echo KEY 158 > /run/optics-inject.fifo
  sleep 0.6; r1=$(rs); i1=$(irq); sleep 2.4
  echo "turn=$t irq@0.6s=$i1 irq@3s=$(irq) rs@0.6s=$r1 rs@3s=$(rs) fb=$(fb) belief=$(belief)" >> $LOG
done
echo "pn-refresh lines since restart: $(tail -n +$n0 $RL | grep -a -c pn-refresh)" >> $LOG
tail -n +$n0 $RL | grep -a pn-refresh | tail -3 | cut -c1-150 >> $LOG
echo QUIT > /run/optics-inject.fifo; sleep 1
herd stop reader-session >/dev/null 2>&1; sleep 2; cp $F.pre-turncheck $F; herd start reader-session >/dev/null 2>&1
echo "== $(date -u +%T) done; settings restored ($(grep -c '"start_with"' $F) start_with lines); dmesg WARN/timeout: $(dmesg | grep -c -E 'WARNING:|timed out'); threads $(ps -eo comm | grep -c '^ebc-')" >> $LOG
