.PHONY: check

# Verbatim-extraction unit tests plus a real loopback round trip against
# the shipped daemon.  No root, no network, no device: every packet stays
# on 127.0.0.1 and the daemon runs --dry-run, so no clock is ever set.
check:
	luajit test-timesync.lua timesync.lua ../../services/timesync.scm
