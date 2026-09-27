.PHONY: check image-metrics-check trajectory-input-check
check:
	luajit -e 'assert(loadfile("export-line.lua"))'
	luajit test-sample.lua
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	  GUILE_AUTO_COMPILE=0 guile --no-auto-compile -s test-cli.scm "$$tmp"

# Pure Python scoring checks; no model download or ML dependencies.
image-metrics-check:
	python3 test-image-metrics.py

trajectory-input-check:
	python3 test-trajectory-input.py
