#!/bin/sh
# Stop the current arm; show only the last few ink batches (the tap), not the assignment.
D=/tmp/du-test; cd "$D"; N=$1
[ -f scribble.pid ] && kill "$(cat scribble.pid)" 2>/dev/null || true
[ -f cap.pid ] && kill "$(cat cap.pid)" 2>/dev/null || true
rm -f scribble.pid cap.pid
echo "batches: $(grep -c 'batch=' "arm-$N.log" || true)  pen bytes: $(wc -c < "pen-$N.bin")"
grep 'batch=' "arm-$N.log" | tail -3
