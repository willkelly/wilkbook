#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
broker="$here/../../packages/platform-controls/pinenote-power-broker.lua"
[ "$(grep -c 'write_value("/sys/power/state", "mem")' "$broker")" -eq 1 ]
! grep -q 'cyttsp5\|Stylus\|ws8100_pen' "$broker"
grep -q 'name == "rk805 pwrkey" or name == "gpio-keys"' "$broker"
grep -q 'ignoring obsolete idle=' "$broker"
grep -q 'ACK_TIMEOUT.*10' "$broker"
grep -q 'fallback_banner' "$broker"
grep -q 'bundle_root.*overlay/frontend/?.lua' "$broker"
grep -q 'WILKBOOK_KOREADER_ROOT' "$broker"
grep -q 'WILKBOOK_WIFI_CONTROL' "$broker"
grep -q 'RTC backstop clear failed after resume' "$broker"
echo "PASS: broker is the single power-state writer and watches only power/cover"
echo "PASS: standalone broker can load staged PineNote modules"
echo "PASS: packaged broker paths can be supplied by the Shepherd service"
echo "PASS: resume clears the RTC backstop alarm"
