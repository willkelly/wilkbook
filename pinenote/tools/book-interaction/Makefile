GUIX ?= guix
CHANNELS ?= ../../../channels.scm

.PHONY: check control-check integration-check qemu-mode-check

check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile guile-json guile-gcrypt python -- sh -c '\
		guile --no-auto-compile -L . test-private-control.scm && \
		./run-tests.sh "$$1"' sh "$(KOREADER_BUNDLE)"

control-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile -- \
		guile --no-auto-compile -L . test-private-control.scm

integration-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile guile-json guile-gcrypt python -- \
		./run-tests.sh "$(KOREADER_BUNDLE)"

qemu-mode-check:
	@test -n "$(KOREADER_BUNDLE)" || { \
		echo "KOREADER_BUNDLE is required for qemu-mode-check" >&2; exit 2; }
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile python -- \
		./run-qemu-mode-tests.sh "$(KOREADER_BUNDLE)"
