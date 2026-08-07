.PHONY: check power-capabilities-check ebc-sleep-frame-check autosuspend-policy-check

check: autosuspend-policy-check
	guile -L ../../.. test-power
	python3 test-reader-energy.py

# The daemon's post-wake policy, run against the verbatim shipped source.
# It also cross-checks the service's idle/backstop defaults, which are the
# ones that actually reach the device.
autosuspend-policy-check:
	luajit test-autosuspend-policy.lua autosuspend.lua ../../services/autosuspend.scm

power-capabilities-check:
	luajit test-power-capabilities.lua ../../packages/koreader-device/frontend/device/pinenote/power_capabilities.lua

ebc-sleep-frame-check:
	luajit test-ebc-barrier.lua ../../packages/koreader-device/frontend/device/pinenote/ebc_barrier.lua
	luajit test-ebc-sleep-frame.lua ../../packages/koreader-device/frontend/device/pinenote/ebc_sleep_frame.lua
