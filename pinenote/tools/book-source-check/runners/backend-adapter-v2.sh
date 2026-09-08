#!/bin/sh
# Public successor for the accepted backend-adapter v2 functional gate.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: backend-adapter-v2.sh PREPARED_ROOT RUN_ROOT" >&2
    exit 2
}
prepared=$1
run_root=$2
case "$prepared:$run_root" in /*:/*) ;; *) exit 2 ;; esac
repo="$prepared/repo"
backend="$prepared/views/backend-v2"
protocol="$repo/pinenote/tools/book-protocol"
state="$repo/pinenote/tools/book-state-protocol"
private_helper="$repo/pinenote/tools/book-source-check/private-environment.sh"
mkdir -m 700 "$run_root/ccache" "$run_root/empty" \
    "$run_root/empty-package-view"
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"

expected_roster="$run_root/backend-roster.expected"
actual_roster="$run_root/backend-roster.actual"
{
    sed -n 's/^[0-9a-f][0-9a-f]*  //p' "$backend/MANIFEST.sha256"
    echo MANIFEST.sha256
} | LC_ALL=C sort >"$expected_roster"
(cd "$backend" && find . -type f -printf '%P\n' | LC_ALL=C sort) >"$actual_roster"
cmp "$expected_roster" "$actual_roster"
(cd "$backend" && sha256sum --check --strict MANIFEST.sha256)

"$BOOK_SOURCE_GUIX" time-machine -C "$repo/channels.scm" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$run_root/empty-package-view" \
    -m "$state/backend-adapter-v2-test-manifest.scm" -- sh -c '
      set -eu
      state=$1
      backend=$2
      protocol=$3
      run_root=$4
      private_helper=$5
      private_environment=$6
      BOOK_SOURCE_GUIX=$7
      export BOOK_SOURCE_GUIX
      ccache=$run_root/ccache
      . "$private_helper"
      book_source_enter_guix_shell_environment "$private_environment" \
        "$ccache" backend-adapter "$run_root/private-environment.log"
      compile () {
        output=$1
        source=$2
        guild compile -Warity-mismatch -Wformat \
          -L "$protocol" -L "$backend" -L "$state" \
          -o "$ccache/$output" "$source"
      }
      compile book-protocol.go "$protocol/book-protocol.scm"
      compile book-state.go "$backend/book-state.scm"
      compile book-state-operation-id.go "$state/book-state-operation-id.scm"
      compile book-state-protocol.go "$state/book-state-protocol.scm"
      compile book-state-backend-adapter.go \
        "$state/book-state-backend-adapter.scm"
      compile test-book-state-backend-adapter.go \
        "$state/test-book-state-backend-adapter.scm"

      export GUILE_LOAD_PATH="$protocol:$backend:$state:$package_load"
      cd "$run_root/empty"

      export GUILE_LOAD_COMPILED_PATH="$package_compiled"
      guile --no-auto-compile "$state/assert-book-state-adapter-v2-load.scm" \
        "$protocol" "$protocol/book-protocol.scm" "$backend/book-state.scm" \
        "$state/book-state-backend-adapter.scm" \
        "$state/book-state-operation-id.scm" "$state/book-state-protocol.scm"
      export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
      guile --no-auto-compile \
        "$state/assert-book-state-adapter-v2-ccache.scm" "$ccache"
      guile --no-auto-compile "$state/test-book-state-backend-adapter.scm" \
        | tee "$run_root/adapter-tests.log"
      grep -F "# of expected passes      42" "$run_root/adapter-tests.log"
      if grep -F "unexpected failures" "$run_root/adapter-tests.log"; then
        exit 1
      fi
    ' sh "$state" "$backend" "$protocol" "$run_root" \
        "$private_helper" "$private_environment" "$BOOK_SOURCE_GUIX"

if grep -Eq '\(book-state\)|\(sqlite3\)|guile-sqlite3' \
        "$state/book-state-operation-id.scm"; then
    echo "SQLite-free operation-ID module imports trusted storage" >&2
    exit 1
fi
printf '%s\n' \
    "PASS: public backend-adapter v2 source successor" \
    "PASS: accepted backend v2 exact source packet reconstructed" \
    "PASS: no machine-local protocol packet or mutable review was read"
