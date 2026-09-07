#!/bin/sh
# Public source successor for completion-observer v1.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: completion-observer.sh PREPARED_ROOT RUN_ROOT" >&2
    exit 2
}
prepared=$1
run_root=$2
repo="$prepared/repo"
closure="$prepared/closure"
observer="$closure/observer-v1"
accepted="$closure/native-v2/accepted-inputs"
bsd1="$repo/pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4"
book_session="$repo/pinenote/tools/book-session"
private_helper="$repo/pinenote/tools/book-source-check/private-environment.sh"
mkdir -m 700 "$run_root/private" "$run_root/ccache" "$run_root/empty" \
    "$run_root/book-load" "$run_root/empty-package-view"
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"

sh "$closure/join/verify-source-closure.sh" "$closure"

"$BOOK_SOURCE_GUIX" time-machine -C "$accepted/channels.scm" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$run_root/empty-package-view" \
    -m "$observer/test-manifest.scm" -- sh -c '
      set -eu
      run_root=$1
      observer=$2
      accepted=$3
      bsd1=$4
      book_session=$5
      private_helper=$6
      private_environment=$7
      BOOK_SOURCE_GUIX=$8
      export BOOK_SOURCE_GUIX
      private=$run_root/private
      ccache=$run_root/ccache
      . "$private_helper"
      book_source_enter_guix_shell_environment "$private_environment" \
        "$ccache" completion-observer "$run_root/private-environment.log"

      cp "$observer/base/book-session-v4.scm" "$private/book-session.scm"
      chmod u+w "$private/book-session.scm"
      patch -s "$private/book-session.scm" \
        <"$observer/book-session-completion-observer.patch"
      cmp "$private/book-session.scm" "$observer/candidate/book-session.scm"
      cp "$observer/candidate/book-session.scm" "$private/book-session-inverse.scm"
      chmod u+w "$private/book-session-inverse.scm"
      patch -Rs "$private/book-session-inverse.scm" \
        <"$observer/book-session-completion-observer.patch"
      cmp "$private/book-session-inverse.scm" "$observer/base/book-session-v4.scm"

      : >"$run_root/compile.log"
      compile () {
        output=$1
        source=$2
        mkdir -p "$(dirname "$ccache/$output")"
        guild compile -Warity-mismatch -Wformat \
          -L "$private" -L "$observer" -L "$accepted/book-protocol" \
          -L "$accepted/state-protocol" -L "$accepted/backend" \
          -o "$ccache/$output" "$source" >>"$run_root/compile.log" 2>&1
      }
      compile book-protocol.go "$accepted/book-protocol/book-protocol.scm"
      compile book-protocol/blocking-io.go \
        "$accepted/book-protocol/book-protocol/blocking-io.scm"
      compile book-state-operation-id.go \
        "$accepted/state-protocol/book-state-operation-id.scm"
      compile book-state-protocol.go \
        "$accepted/state-protocol/book-state-protocol.scm"
      compile book-state-backend-adapter.go \
        "$accepted/state-protocol/book-state-backend-adapter.scm"
      compile book-state.go "$accepted/backend/book-state.scm"
      compile book-state-session-delegate.go \
        "$observer/book-state-session-delegate.scm"
      compile book-session.go "$private/book-session.scm"
      compile test-book-session.go "$book_session/test-book-session.scm"
      compile test-book-session-state-integration.go \
        "$bsd1/test-book-session-state-integration.scm"
      compile test-completion-observer.go "$observer/test-completion-observer.scm"
      compile test-real-completion-observer.go \
        "$observer/test-real-completion-observer.scm"
      compile observer-book.go "$observer/observer-book.scm"
      cat "$run_root/compile.log"
      if grep -i "warning:" "$run_root/compile.log"; then exit 1; fi

      module_root=$(guile --no-auto-compile -c \
        "(display (car %load-path))")
      export GUILE_LOAD_PATH="$private:$observer:$accepted/book-protocol:$accepted/state-protocol:$accepted/backend:$package_load"
      export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
      ln -s "$module_root/json.scm" "$run_root/book-load/json.scm"
      ln -s "$module_root/json" "$run_root/book-load/json"
      test ! -e "$run_root/book-load/sqlite3.scm"
      export OBSERVER_BOOK_SOURCE="$observer/observer-book.scm"
      export OBSERVER_BOOK_GUILE_LOAD_PATH="$run_root/book-load:$accepted/book-protocol"
      export OBSERVER_BOOK_GUILE_LOAD_COMPILED_PATH=""

      run_test () {
        label=$1
        expected=$2
        seconds=$3
        source=$4
        output=$run_root/$label.log
        timeout "$seconds" guile --no-auto-compile "$source" >"$output" 2>&1
        cat "$output"
        grep -F "# of expected passes      $expected" "$output"
        if grep -F "unexpected failures" "$output"; then exit 1; fi
      }
      cd "$run_root/empty"
      run_test accepted-book-session 227 120 "$book_session/test-book-session.scm"
      run_test accepted-bsd1 61 120 \
        "$bsd1/test-book-session-state-integration.scm"
      run_test focused-observer 37 90 "$observer/test-completion-observer.scm"
      run_test real-backend-native-book 37 120 \
        "$observer/test-real-completion-observer.scm"
    ' sh "$run_root" "$observer" "$accepted" "$bsd1" "$book_session" \
        "$private_helper" "$private_environment" "$BOOK_SOURCE_GUIX"

printf '%s\n' \
    "PASS: exact observer v1 source packet reconstructed and authenticated" \
    "PASS: accepted 227/61 regressions and observer 37/37" \
    "PASS: real adapter/backend/SQLite and native book 37/37" \
    "PASS: frozen provenance used; live append-only reviews were not read"
