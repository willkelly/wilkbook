#!/bin/sh
# Executed only from an authenticated v2 source snapshot.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: run-host-tests-inner.sh SNAPSHOT_ROOT RUN_ROOT" >&2
    exit 2
}
snapshot=$1
run_root=$2
case "$snapshot:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$snapshot" && pwd -P)" = "$snapshot" ]

integration="$snapshot/integration"
protocol="$snapshot/accepted-inputs/book-protocol"
state_protocol="$snapshot/accepted-inputs/state-protocol"
backend="$snapshot/accepted-inputs/backend"
session="$snapshot/accepted-inputs/session"
channels="$snapshot/accepted-inputs/channels.scm"
ccache="$run_root/ccache"
mkdir -m 700 "$ccache" "$ccache/book-protocol" "$ccache/checks" \
    "$run_root/empty"

env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
    -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP -u PYTHONUSERBASE \
    guix time-machine -C "$channels" --no-substitutes -- \
    shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
    -m "$integration/test-manifest.scm" -- sh -c '
      set -eu
      snapshot=$1
      run_root=$2
      integration=$snapshot/integration
      protocol=$snapshot/accepted-inputs/book-protocol
      state_protocol=$snapshot/accepted-inputs/state-protocol
      backend=$snapshot/accepted-inputs/backend
      session=$snapshot/accepted-inputs/session
      ccache=$run_root/ccache

      sh "$integration/test-source-gate.sh" "$snapshot" "$run_root"
      package_load=${GUILE_LOAD_PATH-}
      package_compiled=${GUILE_LOAD_COMPILED_PATH-}
      test -n "$package_load"
      test -n "$package_compiled"

      compile_module () {
        output=$1
        source=$2
        guild compile -Warity-mismatch -Wformat \
          -L "$protocol" -L "$backend" -L "$state_protocol" \
          -L "$session" -L "$integration" \
          -o "$ccache/$output" "$source"
      }
      compile_module book-protocol.go "$protocol/book-protocol.scm"
      compile_module book-protocol/blocking-io.go \
        "$protocol/book-protocol/blocking-io.scm"
      compile_module book-state.go "$backend/book-state.scm"
      compile_module book-state-operation-id.go \
        "$state_protocol/book-state-operation-id.scm"
      compile_module book-state-protocol.go \
        "$state_protocol/book-state-protocol.scm"
      compile_module book-state-backend-adapter.go \
        "$state_protocol/book-state-backend-adapter.scm"
      compile_module book-state-session-delegate.go \
        "$session/book-state-session-delegate.scm"
      compile_module book-session.go "$session/book-session.scm"
      compile_module book-state-integration.go \
        "$integration/book-state-integration.scm"
      compile_module checks/native-authority.go "$integration/native-authority.scm"
      compile_module checks/lost-ack-authority.go \
        "$integration/lost-ack-authority.scm"
      compile_module checks/fixture-book.go "$integration/fixture-book.scm"
      compile_module checks/lost-ack-book.go "$integration/lost-ack-book.scm"
      compile_module checks/test-native-factory.go \
        "$integration/test-native-factory.scm"
      compile_module checks/verify-module-origins.go \
        "$integration/verify-module-origins.scm"

      python3 -I -S -X pycache_prefix="$run_root/pycache" -m py_compile \
        "$protocol/book_protocol.py" \
        "$integration/python-fixture-launcher.py" \
        "$integration/fixture_book.py" \
        "$integration/test_native_restart.py"

      json_source=$(guile -c \
        '\''(display (or (search-path %load-path "json.scm") ""))'\'')
      json_compiled=$(guile -c \
        '\''(display (or (search-path %load-compiled-path "json.go") ""))'\'')
      test -n "$json_source"
      test -n "$json_compiled"
      json_source=$(readlink -f "$json_source")
      json_compiled=$(readlink -f "$json_compiled")

      export GUILE_LOAD_PATH="$session:$protocol:$backend:$state_protocol:$integration:$package_load"
      export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
      export GUILE_AUTO_COMPILE=0
      export BOOK_FIXTURE_GUILE_LOAD_PATH="$protocol:$(dirname "$json_source")"
      export BOOK_FIXTURE_GUILE_LOAD_COMPILED_PATH="$(dirname "$json_compiled")"
      export BOOK_FIXTURE_PYTHON_LAUNCHER="$integration/python-fixture-launcher.py"
      export BOOK_FIXTURE_PYTHON_CODEC="$protocol/book_protocol.py"
      export BOOK_STATE_SNAPSHOT_ROOT="$snapshot"
      export XDG_CACHE_HOME="$run_root/xdg-cache"
      mkdir -m 700 "$XDG_CACHE_HOME"
      unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
      cd "$run_root/empty"

      guile --no-auto-compile "$integration/verify-module-origins.scm" \
        "$snapshot" "$ccache"
      guile --no-auto-compile "$integration/test-native-factory.scm" \
        | tee "$run_root/native-factory.log"
      grep -F "# of expected passes" "$run_root/native-factory.log"
      if grep -F "unexpected failures" "$run_root/native-factory.log"; then
        exit 1
      fi

      python3 -I -S "$integration/test_native_restart.py" \
        | tee "$run_root/native-restart.log"
      grep -F "PASS: fresh Guile authorities reopened real SQLite state" \
        "$run_root/native-restart.log"
      grep -F "PASS: actual dropped acknowledgement retried unchanged after restart" \
        "$run_root/native-restart.log"
      grep -F "PASS: combined native scenarios used fresh endpoint identities" \
        "$run_root/native-restart.log"
      grep -F "PASS: acknowledged-receipt counterexample rejected by loss oracle" \
        "$run_root/native-restart.log"
      grep -F "PASS: 4,096-byte NUL state crossed the real worker after reopen" \
        "$run_root/native-restart.log"

      if grep -Eq '\''\(book-state|\(sqlite3'\'' "$integration/fixture-book.scm" \
          || grep -Eq '\''\(book-state|\(sqlite3'\'' "$integration/lost-ack-book.scm"; then
        echo "Guile fixture imports trusted state authority" >&2
        exit 1
      fi
      if grep -Eq '\''(^|[^A-Za-z_])(sqlite3|book_state)([^A-Za-z_]|$)'\'' \
          "$integration/fixture_book.py"; then
        echo "Python fixture imports trusted state authority" >&2
        exit 1
      fi
    ' sh "$snapshot" "$run_root"

test "$(guix gc --requisites /gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages | wc -l)" -eq 45
test "$(guix hash -r /gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages)" = \
  1lmksjn9k8k5bxpnckh5bdd0wwnz3ab7q7wp4cnk5wmfayp1dwln

printf '%s\n' \
  "PASS: exact v2 source snapshot executed after pre-execution identity gate" \
  "PASS: accepted backend/protocol/adapter/session identities stayed fixed" \
  "PASS: Python codec origin and Scheme module origins matched snapshot" \
  "PASS: accepted 45-path sandbox closure unchanged; native run is not sandboxed" \
  "PASS: native Book State integration v2 (no QEMU/runsc/ARM/image/hardware)"
