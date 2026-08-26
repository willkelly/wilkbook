#!/bin/sh
# Live CLUT table swap ON THE DEVICE -- the no-image-write iteration
# path for waveform-table experiments (A2-in-the-DU-slot and friends).
# Scripted form of the procedure the GL16:GC16 experiment proved by
# hand (doc/status.md 2026-08-26 part 3): stop the reader, unbind the
# driver, install the table, rebind, restart.
#
# The swap is SESSION-SCOPED by design: the boot-time clut one-shot
# recompiles the identity table on the next boot, so a bad experiment
# is always one reboot from gone.  Never install an experiment table
# into the image.
#
# Usage: clut-swap.sh /path/to/table.bin [--no-reader]
set -eu

TABLE=${1:?usage: clut-swap.sh TABLE.bin [--no-reader]}
NO_READER=${2:-}
FW=/lib/firmware/rockchip/custom_wf.bin
DRV=/sys/bus/platform/drivers/rockchip-ebc
DEV=fdec0000.ebc

[ "$(head -c 8 "$TABLE")" = "CLUT0002" ] || {
	echo "ABORT: $TABLE has no CLUT0002 magic" >&2
	exit 1
}

if [ "$NO_READER" != "--no-reader" ]; then
	echo "[clut-swap] stopping reader-session"
	herd stop reader-session
fi

echo "[clut-swap] unbinding $DEV"
echo "$DEV" > "$DRV/unbind"

cp "$TABLE" "$FW"
sync
echo "[clut-swap] installed $(sha256sum "$FW" | cut -c1-16)... ($(stat -c %s "$FW") bytes)"

echo "[clut-swap] rebinding"
echo "$DEV" > "$DRV/bind"
sleep 1

if dmesg | tail -20 | grep -q "Initialized rockchip-ebc"; then
	echo "[clut-swap] probe OK"
else
	echo "[clut-swap] WARNING: no probe line in recent dmesg -- check manually" >&2
fi

if [ "$NO_READER" != "--no-reader" ]; then
	echo "[clut-swap] restarting reader-session"
	herd start reader-session
fi
echo "[clut-swap] done (reboot restores the identity table)"
