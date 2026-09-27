.PHONY: check
check:
	luajit -e 'assert(loadfile("export-line.lua"))'
	luajit test-sample.lua
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	  GUILE_AUTO_COMPILE=0 guile --no-auto-compile -s test-cli.scm "$$tmp"
