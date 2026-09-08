PYTHON ?= python3
GUIX ?= guix
CHANNELS ?= ../../../../channels.scm
GVISOR_SOURCE ?= /tmp/opencode/gvisor-fd2f6b2674

.PHONY: check host-check source-check

check: source-check host-check

source-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) \
		check_pinned_gvisor_fd_seam.py "$(GVISOR_SOURCE)"

host-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile@3.0.9 guile-json@4.7.3 guile-gcrypt@0.5.0 python -- \
		env GUILE_AUTO_COMPILE=0 PYTHONDONTWRITEBYTECODE=1 \
		$(PYTHON) -m unittest -v test_protocol_fixture.py
