GUILE ?= guile
GUILD ?= guild

.PHONY: check compile-check

check: compile-check
	GUILE_AUTO_COMPILE=0 $(GUILE) --no-auto-compile \
	  -L ../book-protocol -L . test-book-state-protocol.scm

compile-check:
	$(GUILD) compile -Warity-mismatch -Wformat \
	  -L ../book-protocol -L . -o /tmp/opencode/book-state-operation-id.go \
	  book-state-operation-id.scm
	$(GUILD) compile -Warity-mismatch -Wformat \
	  -L ../book-protocol -L . -o /tmp/opencode/book-state-protocol.go \
	  book-state-protocol.scm
	$(GUILD) compile -Warity-mismatch -Wformat \
	  -L ../book-protocol -L . -o /tmp/opencode/test-book-state-protocol.go \
	  test-book-state-protocol.scm
