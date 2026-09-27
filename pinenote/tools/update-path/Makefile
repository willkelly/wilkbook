.PHONY: check
sources = ../../packages/update-path
check:
	luajit -e 'assert(loadfile("$(sources)/wilkbook-generation.lua"))'
	luajit test-generation-ledger.lua $(sources)/generation_ledger.lua
	luajit test-health.lua $(sources)/wilkbook-generation.lua
	GUILE_AUTO_COMPILE=0 guile --no-auto-compile -s test-trial.scm
	./test-static.sh
