.PHONY: check

# The live-iteration lab's host suite: ABI packers pinned against the
# hardware-proven GLOBAL_REFRESH constant, discovery over fake trees,
# and page-flip's renderer extracted verbatim.  Needs only luajit.
check:
	mkdir -p build
	luajit test-ebc-lab.lua
