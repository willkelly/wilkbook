.PHONY: export-candidate prepare check check-retained replay-retained

SOURCE_ROOT ?=
OUTPUT ?=
ARTIFACT_ROOT ?=

require-source-root:
	@test -n "$(SOURCE_ROOT)" || { \
		echo "SOURCE_ROOT=/absolute/fresh-candidate is required" >&2; exit 2; }

export-candidate: require-source-root
	@test -n "$(OUTPUT)" || { echo "OUTPUT=/absolute/empty-dir is required" >&2; exit 2; }
	./run.sh export-candidate --source-root "$(SOURCE_ROOT)" --output "$(OUTPUT)"

prepare: require-source-root
	@test -n "$(OUTPUT)" || { echo "OUTPUT=/absolute/empty-dir is required" >&2; exit 2; }
	./run.sh prepare --source-root "$(SOURCE_ROOT)" --output "$(OUTPUT)"

check: require-source-root
	"$(SOURCE_ROOT)/pinenote/tools/book-source-check/run.sh" check \
		--source-root "$(SOURCE_ROOT)" $(if $(OUTPUT),--output "$(OUTPUT)",)

check-retained:
	@test -n "$(ARTIFACT_ROOT)" || { \
		echo "ARTIFACT_ROOT=/absolute/authenticated-root is required" >&2; exit 2; }
	./check-retained.sh "$(ARTIFACT_ROOT)"

replay-retained: require-source-root
	@test -n "$(ARTIFACT_ROOT)" || { \
		echo "ARTIFACT_ROOT=/absolute/authenticated-root is required" >&2; exit 2; }
	"$(SOURCE_ROOT)/pinenote/tools/book-source-check/replay-retained.sh" \
		"$(SOURCE_ROOT)" "$(ARTIFACT_ROOT)" $(if $(OUTPUT),"$(OUTPUT)",)
