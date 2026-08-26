.PHONY: check

check:
	luajit test-orientation.lua ../../..
	luajit orientation-bridge.lua --uinput-self-test
	luajit orientation-bridge.lua --signal-self-test
