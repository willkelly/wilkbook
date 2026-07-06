# Host-side tests for KOReader's input routing (offline testing ladder).
#
# Nothing to compile: test-mixedrouter.lua runs under the native
# koreader-bin bundle's own luajit, exercising the bundle's *verbatim*
# frontend/device/input.lua + gesturedetector.lua and the repo's
# device/pinenote/mixedrouter.lua.  The bundle is resolved at run time
# with `guix build -L <repo> koreader-bin` (cached -- seconds), or via
# KOREADER_BUNDLE=/gnu/store/...
#
#   make check [KOREADER_BUNDLE=/gnu/store/...-koreader-bin-...]

check:
	./run-tests.sh $(KOREADER_BUNDLE)

.PHONY: check
