.PHONY: check
sources = ../../packages/update-path
check:
	luajit -e 'assert(loadfile("$(sources)/wilkbook-generation.lua"))'
	luajit test-generation-ledger.lua $(sources)/generation_ledger.lua
	./test-static.sh
