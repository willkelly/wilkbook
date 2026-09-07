# Replay the book-reader fixture through the pinned native KOReader frontend.
# Override KOREADER_BUNDLE to avoid resolving it through Guix.

check:
	./test-timeout-owner.sh
	./run-tests.sh "$(KOREADER_BUNDLE)"

mutation-check:
	./run-mutation-tests.sh "$(KOREADER_BUNDLE)"

.PHONY: check mutation-check
