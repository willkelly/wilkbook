#!/bin/sh
# validate-ebc-card-resolution.sh -- the EBC's DRM card index is NOT
# stable across images: whichever DRM driver probes first takes card0,
# and on the direct-mode image that is the panfrost GPU.  On 2026-08-25
# (glass) KOReader's hardcoded /dev/dri/card0 sent every wash to the GPU
# as a malformed job (dmesg JOB_CONFIG_FAULT) and the panel was never
# washed.  Every on-device EBC-ioctl path must therefore RESOLVE the
# card by driver name (DRIVER=rockchip-ebc in
# /sys/class/drm/cardN/device/uevent -- both the shipping and the
# direct-mode driver register that platform-driver name) and never carry
# a /dev/dri/card<index> literal.
#
# Host tests that INJECT a fake card path (tools/power/test-*.lua, the
# koreader-input expectations) are deliberately NOT in the roster: an
# injected literal is data, not a probe.
set -eu
cd "$(dirname "$0")/../../.."

fail=0
pattern='/dev/dri/card[0-9]'

# Positive control: prove the pattern still matches the bug before
# trusting its silence -- a broken pattern would pass every roster path.
if ! printf '%s\n' "C.open('/dev/dri/card0', 2)" | grep -Eq "$pattern"; then
	echo "FAIL: positive control -- the pattern no longer matches a card0 hardcode" >&2
	exit 1
fi
echo "PASS: positive control: the pattern matches a card0 hardcode"

# 1. No on-device EBC path may carry a card-index literal.
roster="
pinenote/packages/koreader-device
pinenote/services
pinenote/packages/ebc-test.scm
pinenote/tools/power/autosuspend.lua
pinenote/tools/ebc-barrier/pinenote-ebc-sleep-frame-test.c
pinenote/tools/ebc-logic/ebc-dump-grab.c
pinenote/tools/pen/scribble.lua
pinenote/tools/pen/ebc-mode.lua
pinenote/tools/ebc-lab
"
for path in $roster; do
	if [ ! -e "$path" ]; then
		echo "FAIL: roster path missing: $path (moved? update this script)" >&2
		fail=1
		continue
	fi
	if hits=$(grep -rEn "$pattern" "$path"); then
		echo "FAIL: hardcoded DRM card index in an on-device path:" >&2
		printf '%s\n' "$hits" >&2
		fail=1
	else
		echo "PASS: no /dev/dri/cardN literal under $path"
	fi
done

# 2. Every wash/ioctl path must carry the resolution probe itself.
for path in \
	pinenote/packages/koreader-device/frontend/device/pinenote/device.lua \
	pinenote/services/reader-session.scm \
	pinenote/packages/ebc-test.scm \
	pinenote/tools/ebc-barrier/pinenote-ebc-sleep-frame-test.c \
	pinenote/tools/ebc-logic/ebc-dump-grab.c \
	pinenote/tools/pen/ebc-mode.lua \
	pinenote/tools/ebc-lab/ebclib.lua
do
	if grep -q 'DRIVER=rockchip-ebc' "$path"; then
		echo "PASS: $path resolves the EBC card by driver name"
	else
		echo "FAIL: $path does not carry the DRIVER=rockchip-ebc probe" >&2
		fail=1
	fi
done

exit "$fail"
