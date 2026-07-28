.PHONY: check power-capabilities-check ebc-sleep-frame-check

check:
	guile -L ../../.. test-power
	python3 test-reader-energy.py

power-capabilities-check:
	luajit test-power-capabilities.lua ../../packages/koreader-device/frontend/device/pinenote/power_capabilities.lua

ebc-sleep-frame-check:
	luajit test-ebc-barrier.lua ../../packages/koreader-device/frontend/device/pinenote/ebc_barrier.lua
	luajit test-ebc-sleep-frame.lua ../../packages/koreader-device/frontend/device/pinenote/ebc_sleep_frame.lua
