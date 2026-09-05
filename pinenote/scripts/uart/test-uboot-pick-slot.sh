#!/bin/sh
# Offline test of uboot-pick-slot.sh (make uart-pick-check): the picker
# against a pseudo-terminal replaying the real captured U-Boot bytes.  No
# device, no /dev/ttyUSB*.  The cases and what they pin are in
# test-uboot-pick-slot.py.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for tool in python3 setsid stty; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is needed (python3 for the pty pair, setsid and stty for the script under test)" >&2; exit 1; }
done
exec python3 "$here/test-uboot-pick-slot.py" "$@"
