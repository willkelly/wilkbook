PYTHON ?= python3
GUIX ?= guix
CHANNELS ?= ../../../../channels.scm
GVISOR_SOURCE ?= /tmp/opencode/gvisor-fd2f6b2674

.PHONY: check source-check inventory-check review-drift-check host-check system-check

check: source-check inventory-check review-drift-check host-check system-check

source-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) \
		../protocol-fixture/check_pinned_gvisor_fd_seam.py "$(GVISOR_SOURCE)"
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) \
		../check_pinned_gvisor_null_netns.py "$(GVISOR_SOURCE)"

inventory-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) ../check_protocol_guest_inventory.py

review-drift-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) ../test_protocol_review_drift_guard.py

host-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile@3.0.9 guile-json@4.7.3 guile-gcrypt@0.5.0 python -- \
		env GUILE_AUTO_COMPILE=0 PYTHONDONTWRITEBYTECODE=1 \
		$(PYTHON) -m unittest discover -v -s .. -p 'test_*book*.py'

system-check:
	$(GUIX) time-machine -C $(CHANNELS) -- repl -L ../../../.. -q \
		../check-protocol-control-system.scm
