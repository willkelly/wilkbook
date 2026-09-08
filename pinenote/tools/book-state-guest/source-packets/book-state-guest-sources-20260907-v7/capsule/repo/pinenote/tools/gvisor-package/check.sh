#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=${1:-${GVISOR_SOURCE:-}}

if [ -z "$source" ]; then
    echo "usage: $0 PINNED-GVISOR-SOURCE" >&2
    exit 2
fi

PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_inventory.py" "$here/inventory.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_vendor.py" \
    "$here/vendor_manifest.py" \
    "$here/vendor_inputs.py" \
    "$here/release-vendor-manifest.json" \
    "$here/emit_guix_inputs.py" \
    "$here/../../packages/gvisor-dependencies.scm"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/vendor_inputs.py" check \
    "$here/release-vendor-manifest.json" --artifacts "$here"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/gvisor-package-check.XXXXXX")
tmp=$tmpdir/inventory.json
err=$tmpdir/inventory.err
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

expect_rejected() {
    expected=$1
    shift
    if "$@" >"$tmp" 2>"$err"
    then
        echo "inventory unexpectedly accepted mutation: $expected" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$err"
    then
        cat "$err" >&2
        echo "rejection did not name expected boundary: $expected" >&2
        exit 1
    fi
}

python3 "$here/inventory.py" "$source" --output "$tmp"
cmp "$here/pinned-source-inventory.json" "$tmp"

expect_rejected 'a generated MODULE.bazel.lock is required' \
    python3 "$here/inventory.py" "$source" --require-lock
expect_rejected 'http_file:google_root_pem' \
    python3 "$here/inventory.py" "$source" --require-explicit-hashes

python3 "$here/inventory.py" "$source" --output "$tmp"
python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    result = json.load(source)
assert result["source"]["commit"] == "fd2f6b2674208086e324c2f739155eb7e1b48ff2"
assert len(result["bazel"]["direct_modules"]) == 18
assert len(result["bazel"]["explicit_http_downloads"]) == 9
assert result["packaging"]["explicit_content_addressed_count"] == 8
assert result["packaging"]["explicit_unhashed_ids"] == ["http_file:google_root_pem"]
assert len(result["go"]["selected_modules"]) == 122
assert result["go"]["go_sum_line_counts"] == {
    "content": 161,
    "go_mod": 284,
    "total": 445,
}
assert result["packaging"]["ready_for_networkless_source_build"] is False
PY

# Build the complete scanner-facing source surface without copying the 77 MiB
# tree.  --source-commit is valid here only because each mutation starts from
# the already-verified fixed source and the exact metadata hashes remain gates.
mutation=$tmpdir/source
mkdir -p "$mutation/tools/bazeldefs/extensions"
for relative in .bazelversion LICENSE MODULE.bazel go.mod go.sum
do
    cp "$source/$relative" "$mutation/$relative"
done
cp "$source"/tools/bazeldefs/extensions/*.bzl \
    "$mutation/tools/bazeldefs/extensions/"
python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2 \
    --output "$tmp"
cmp "$here/pinned-source-inventory.json" "$tmp"

printf '%s\n' '9.0.0' > "$mutation/.bazelversion"
expect_rejected 'pinned source file hash changed: .bazelversion' \
    python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2
rm "$mutation/.bazelversion"
expect_rejected 'pinned source file is missing: .bazelversion' \
    python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2
cp "$source/.bazelversion" "$mutation/.bazelversion"

cat >> "$mutation/tools/bazeldefs/extensions/coral_crosstool.bzl" <<'EOF'

def _mutation_impl(ctx):
    ctx.download("https://example.invalid/source.tar.gz", "source.tar.gz")

mutation_repo = repository_rule(implementation = _mutation_impl)
mutation_repo(name = "mutation")
EOF
expect_rejected 'unsupported dynamic repository primitive ctx.download' \
    python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2
cp "$source/tools/bazeldefs/extensions/coral_crosstool.bzl" \
    "$mutation/tools/bazeldefs/extensions/coral_crosstool.bzl"

printf '%s\n' '# benign mutation must still move the extension identity' >> \
    "$mutation/tools/bazeldefs/extensions/coral_crosstool.bzl"
expect_rejected 'traversed local extension hash changed' \
    python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2
cp "$source/tools/bazeldefs/extensions/coral_crosstool.bzl" \
    "$mutation/tools/bazeldefs/extensions/coral_crosstool.bzl"

cat >> "$mutation/tools/bazeldefs/extensions/coral_crosstool.bzl" <<'EOF'
load(":mutation-repository.bzl", "mutation_repo")
EOF
cat > "$mutation/tools/bazeldefs/extensions/mutation-repository.bzl" <<'EOF'
def _impl(ctx):
    ctx.download_and_extract("https://example.invalid/source.tar.gz")

mutation_repo = repository_rule(implementation = _impl)
EOF
expect_rejected \
    'tools/bazeldefs/extensions/mutation-repository.bzl' \
    python3 "$here/inventory.py" "$mutation" \
    --source-commit fd2f6b2674208086e324c2f739155eb7e1b48ff2

echo "PASS: pinned gVisor source dependency inventory"
