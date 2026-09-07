PYTHON ?= python3
GUIX ?= guix
CHANNELS ?= ../../../channels.scm
PROTOCOL_DIR ?= ../book-protocol

.PHONY: check guile-check python-check python-oracle-check

check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile guile-json guile-gcrypt python -- sh -c '\
		guile --no-auto-compile -L $(PROTOCOL_DIR) -L . \
			test-book-session.scm && \
		PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$(PROTOCOL_DIR) \
			$(PYTHON) -m unittest -v test_book_session.py'

guile-check:
	$(GUIX) time-machine -C $(CHANNELS) -- \
		shell guile guile-json guile-gcrypt -- \
		guile --no-auto-compile -L $(PROTOCOL_DIR) -L . \
			test-book-session.scm

python-check:
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$(PROTOCOL_DIR) \
		$(PYTHON) -m unittest -v test_book_session.py

python-oracle-check: python-check
