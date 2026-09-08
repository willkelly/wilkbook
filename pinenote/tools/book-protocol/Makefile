PYTHON ?= python3
GUIX ?= guix
CHANNELS ?= ../../../channels.scm
GUIX_SHELL ?= $(GUIX) time-machine -C $(CHANNELS) -- shell

.PHONY: check python-check guile-check conformance-check
check:
	$(GUIX_SHELL) guile guile-json python -- sh -c '\
		PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest -v && \
		guile --no-auto-compile -L . test-book-protocol.scm'

python-check:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest -v test_book_protocol.py

guile-check:
	$(GUIX_SHELL) guile guile-json -- \
		guile --no-auto-compile -L . test-book-protocol.scm

conformance-check:
	$(GUIX_SHELL) guile guile-json python -- \
		env PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest -v \
			test_guile_conformance.py
