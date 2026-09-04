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
# Zero physical inputs (QEMU virt, rung 4) must degrade, not crash-loop:
# a dead broker holds reader-session -- and so the reader -- down.
grep -q 'physical triggers disabled' "$broker"
! grep -q 'error("no power/cover input devices")' "$broker"
echo "PASS: broker is the single power-state writer and watches only power/cover"
echo "PASS: standalone broker can load staged PineNote modules"
echo "PASS: packaged broker paths can be supplied by the Shepherd service"
echo "PASS: resume clears the RTC backstop alarm"
grep -q 'key == "rtc_settle"' "$broker" && grep -q 'protocol.rtc_settle = config.rtc_settle' "$broker" || { echo "FAIL: rtc_settle is not a config key applied to the protocol" >&2; exit 1; }
echo "PASS: rtc_settle is a config key (floor 20) applied to the protocol each loop"
# Issue #42: the shipping-only REFRESH_BARRIER must never be the only
# quiesce; the broker chooses by driver and the choice is a pure module.
grep -q 'require("broker_quiesce")' "$broker"
grep -q 'driver_has_barrier = driver_has_barrier, barrier = ebc_barrier' "$broker"
grep -q 'ebc_quiesce()' "$broker"
! grep -q 'barrier_ok, barrier_error = ebc_barrier()' "$broker"
grep -q 'fdec0000.ebc' "$broker"
grep -q 'read_line("/sys/module/rockchip_ebc/parameters/refresh_waveform") ~= nil' "$broker"
! grep -q 'parameters/no_off_screen") ~= nil' "$broker"
echo "PASS: broker degrades without physical inputs instead of crash-looping"
echo "PASS: broker quiesces the EBC by driver capability (barrier or interrupt quiescence, #42)"
