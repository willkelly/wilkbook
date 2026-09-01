.PHONY: check

# The pen tools' host suite: extracted-verbatim geometry, event parsing,
# publish, discovery, and the DRM ioctl ABI pinned against the
# hardware-proven GLOBAL_REFRESH constant.  Needs only luajit.
check:
	mkdir -p build
	luajit test-scribble.lua scribble.lua ebc-mode.lua
