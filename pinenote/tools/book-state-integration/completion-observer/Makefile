.PHONY: check

check:
	@test -n "$(SOURCE_ROOT)" || { \
		echo "SOURCE_ROOT=/absolute/fresh-candidate is required" >&2; exit 2; }
	./run-public-source-check.sh "$(SOURCE_ROOT)"
