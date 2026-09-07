GUIX ?= guix
CHANNELS ?= ../../../channels.scm
GUIX_BUILD_OPTIONS ?= --no-grafts --max-jobs=1 --cores=2

.PHONY: check guile-check crash-check

check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell $(GUIX_BUILD_OPTIONS) -m test-manifest.scm -- sh -c '\
		guile --no-auto-compile -L . test-book-state.scm && \
		PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
			test_book_state_crash.py'

guile-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell $(GUIX_BUILD_OPTIONS) -m runtime-manifest.scm -- \
		guile --no-auto-compile -L . test-book-state.scm

crash-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell $(GUIX_BUILD_OPTIONS) -m test-manifest.scm -- \
		env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
			test_book_state_crash.py
