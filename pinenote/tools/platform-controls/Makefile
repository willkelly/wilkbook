.PHONY: check

sources = ../../packages/platform-controls
device = ../../packages/koreader-device/frontend/device/pinenote

check:
	luajit -e 'assert(loadfile("$(sources)/pinenote-power-broker.lua"))'
	luajit test-broker-protocol.lua $(sources)/broker_protocol.lua
	luajit test-driver.lua $(device)
	luajit test-frontlight-toggle.lua $(device)
	./test-wifi-control.sh $(sources)/pinenote-wifi-control
	./test-static.sh
	./test-integration.sh
