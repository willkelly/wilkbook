#!/bin/sh
# Blinded pen arm.  usage: arm.sh N random | arm.sh N swap M | arm.sh N all|none|fast|pair1|pair2
# The DU/FAST assignment is written to assign-N (and pair-order) and never printed here.
set -eu
D=/tmp/du-test
cd "$D"
N=$1; MODE=${2:-random}
LUA=$(cat luajit-path)
[ -f scribble.pid ] && kill "$(cat scribble.pid)" 2>/dev/null || true
[ -f cap.pid ] && kill "$(cat cap.pid)" 2>/dev/null || true
rm -f scribble.pid cap.pid
sleep 0.3
coin() { [ $(( $(od -An -N1 -tu1 /dev/urandom) % 2 )) -eq 0 ]; }
case "$MODE" in
  random) if coin; then side=low; else side=high; fi ;;
  swap)   if [ "$(cat "assign-$3")" = low ]; then side=high; else side=low; fi ;;
  pair1)  if coin; then echo "fast all" > pair-order; else echo "all fast" > pair-order; fi
          side=$(cut -d' ' -f1 pair-order) ;;
  pair2)  side=$(cut -d' ' -f2 pair-order) ;;
  *)      side=$MODE ;;
esac
echo "$side" > "assign-$N"
# Every arm starts from NORMAL; a FAST arm switches over only after its clear.
"$LUA" ebc-mode.lua --normal > "mode-$N.log" 2>&1
case "$side" in
  low)  "$LUA" rect-hints.lua --default 32 --rect 0,0,936,1404:0 >/dev/null ;;
  high) "$LUA" rect-hints.lua --default 32 --rect 936,0,936,1404:0 >/dev/null ;;
  all)  "$LUA" rect-hints.lua --default 0 >/dev/null ;;
  none|fast) "$LUA" rect-hints.lua --default 32 >/dev/null ;;
esac
stylus=""
for n in /sys/class/input/event*/device/name; do
  case "$(cat "$n")" in *Stylus*) stylus=/dev/input/$(basename "$(dirname "$(dirname "$n")")") ;; esac
done
[ -n "$stylus" ] || { echo "no stylus node"; exit 1; }
nohup "$LUA" scribble.lua --clear > "arm-$N.log" 2>&1 < /dev/null &
echo $! > scribble.pid
sleep 1.5
case "$side" in low|high) "$LUA" divider.lua > "divider-$N.log" 2>&1 ;; esac
sleep 0.8
# One full-panel flash per arm: FAST's entry refresh, or an explicit wash.
if [ "$side" = fast ]; then "$LUA" ebc-mode.lua --fast >> "mode-$N.log" 2>&1
else "$LUA" frame-clock.lua --wash > "wash-$N.log" 2>&1; fi
nohup cat "$stylus" > "pen-$N.bin" 2>/dev/null < /dev/null &
echo $! > cap.pid
echo "arm $N ready (stylus $stylus, scribble pid $(cat scribble.pid))"
