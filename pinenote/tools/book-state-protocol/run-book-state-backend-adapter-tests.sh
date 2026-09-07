#!/bin/sh
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
backend_snapshot="$repo/pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v1"

cd "$repo"
cat <<'EOF' | sha256sum -c -
3e5567cad0f5c43f54a0b2abb6916dcbd3c1c7dbd922a6fb8642eb3d4c84e3cc  pinenote/tools/book-state-protocol/book-state-protocol.scm
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  pinenote/tools/book-protocol/book-protocol.scm
eeb572ef8c97873fd7d2b3295ac20552bcc72bf2916d8c1bdca8004ba5fbd3d4  pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v1/book-state.scm
70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb  pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v1/schema-v1.sql
EOF

guix time-machine -C channels.scm --no-substitutes -- \
  shell --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
  -m "$tool_dir/backend-adapter-test-manifest.scm" -- sh -c '
    set -eu
    tool_dir=$1
    backend_snapshot=$2
    protocol_dir=$3
    guild compile -Warity-mismatch -Wformat \
      -L "$protocol_dir" -L "$backend_snapshot" -L "$tool_dir" \
      -o /tmp/opencode/book-state-operation-id.go \
      "$tool_dir/book-state-operation-id.scm"
    guild compile -Warity-mismatch -Wformat \
      -L "$protocol_dir" -L "$backend_snapshot" -L "$tool_dir" \
      -o /tmp/opencode/book-state-backend-adapter.go \
      "$tool_dir/book-state-backend-adapter.scm"
    guild compile -Warity-mismatch -Wformat \
      -L "$protocol_dir" -L "$backend_snapshot" -L "$tool_dir" \
      -o /tmp/opencode/test-book-state-backend-adapter.go \
      "$tool_dir/test-book-state-backend-adapter.scm"
    GUILE_AUTO_COMPILE=0 guile --no-auto-compile \
      -L "$protocol_dir" -L "$backend_snapshot" -L "$tool_dir" \
      "$tool_dir/test-book-state-backend-adapter.scm"
  ' sh "$tool_dir" "$backend_snapshot" \
    "$repo/pinenote/tools/book-protocol"

if grep -Eq '\(book-state\)|\(sqlite3\)' \
     "$tool_dir/book-state-operation-id.scm"; then
  echo "SQLite-free operation-ID module imports trusted storage" >&2
  exit 1
fi

printf '%s\n' \
  "PASS: lightweight operation-ID module has no Book State/SQLite import" \
  "PASS: real backend adapter host gate (network/substitutes disabled)"
