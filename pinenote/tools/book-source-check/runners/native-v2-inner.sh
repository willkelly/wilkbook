#!/bin/sh
# Native-v2 functional body without the separately retained 45-path profile gate.
set -eu

[ "$#" -eq 4 ] || {
    echo "usage: native-v2-inner.sh SNAPSHOT_ROOT RUN_ROOT PRIVATE_HELPER PRIVATE_ENVIRONMENT" >&2
    exit 2
}
snapshot=$1
run_root=$2
private_helper=$3
private_environment=$4
case "$snapshot:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$snapshot" && pwd -P)" = "$snapshot" ]

integration="$snapshot/integration"
protocol="$snapshot/accepted-inputs/book-protocol"
state_protocol="$snapshot/accepted-inputs/state-protocol"
backend="$snapshot/accepted-inputs/backend"
session="$snapshot/accepted-inputs/session"
ccache="$run_root/ccache"
mkdir -m 700 "$ccache" "$ccache/book-protocol" "$ccache/checks" \
    "$run_root/empty" "$run_root/empty-package-view"
. "$private_helper"
book_source_enter_bootstrap_environment "$private_environment"

"$BOOK_SOURCE_GUIX" time-machine -C "$snapshot/accepted-inputs/channels.scm" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$run_root/empty-package-view" \
    -m "$integration/test-manifest.scm" -- sh -c '
      set -eu
      snapshot=$1
      run_root=$2
      private_helper=$3
      private_environment=$4
      BOOK_SOURCE_GUIX=$5
      export BOOK_SOURCE_GUIX
      integration=$snapshot/integration
      protocol=$snapshot/accepted-inputs/book-protocol
      state_protocol=$snapshot/accepted-inputs/state-protocol
      backend=$snapshot/accepted-inputs/backend
      session=$snapshot/accepted-inputs/session
      ccache=$run_root/ccache
      . "$private_helper"
      book_source_enter_guix_shell_environment "$private_environment" \
        "$ccache" native-v2 "$run_root/private-environment.log"

      sh "$integration/test-source-gate.sh" "$snapshot" "$run_root"
      compile () {
        output=$1
        source=$2
        guild compile -Warity-mismatch -Wformat \
          -L "$protocol" -L "$backend" -L "$state_protocol" \
          -L "$session" -L "$integration" -o "$ccache/$output" "$source"
      }
      compile book-protocol.go "$protocol/book-protocol.scm"
      compile book-protocol/blocking-io.go \
        "$protocol/book-protocol/blocking-io.scm"
      compile book-state.go "$backend/book-state.scm"
      compile book-state-operation-id.go \
        "$state_protocol/book-state-operation-id.scm"
      compile book-state-protocol.go "$state_protocol/book-state-protocol.scm"
      compile book-state-backend-adapter.go \
        "$state_protocol/book-state-backend-adapter.scm"
      compile book-state-session-delegate.go \
        "$session/book-state-session-delegate.scm"
      compile book-session.go "$session/book-session.scm"
      compile book-state-integration.go "$integration/book-state-integration.scm"
      compile checks/native-authority.go "$integration/native-authority.scm"
      compile checks/lost-ack-authority.go "$integration/lost-ack-authority.scm"
      compile checks/fixture-book.go "$integration/fixture-book.scm"
      compile checks/lost-ack-book.go "$integration/lost-ack-book.scm"
      compile checks/test-native-factory.go "$integration/test-native-factory.scm"
      compile checks/verify-module-origins.go \
        "$integration/verify-module-origins.scm"

      python3 -I -S -X pycache_prefix="$run_root/pycache" -m py_compile \
        "$protocol/book_protocol.py" "$integration/python-fixture-launcher.py" \
        "$integration/fixture_book.py" "$integration/test_native_restart.py"

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
      export BOOK_FIXTURE_GUILE_LOAD_PATH="$protocol:$(dirname "$json_source")"
      export BOOK_FIXTURE_GUILE_LOAD_COMPILED_PATH="$(dirname "$json_compiled")"
      export BOOK_FIXTURE_PYTHON_LAUNCHER="$integration/python-fixture-launcher.py"
      export BOOK_FIXTURE_PYTHON_CODEC="$protocol/book_protocol.py"
      export BOOK_STATE_SNAPSHOT_ROOT="$snapshot"
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

      if grep -Eq '\''\(book-state|\(sqlite3'\'' \
          "$integration/fixture-book.scm" "$integration/lost-ack-book.scm"; then
        echo "Guile fixture imports trusted state authority" >&2
        exit 1
      fi
      if grep -Eq '\''(^|[^A-Za-z_])(sqlite3|book_state)([^A-Za-z_]|$)'\'' \
          "$integration/fixture_book.py"; then
        echo "Python fixture imports trusted state authority" >&2
        exit 1
      fi
    ' sh "$snapshot" "$run_root" "$private_helper" "$private_environment" \
        "$BOOK_SOURCE_GUIX"

printf '%s\n' \
    "PASS: exact native-v2 source snapshot executed after identity gate" \
    "PASS: Python codec and Scheme module origins matched the private snapshot" \
    "PASS: native Book State v2 functional integration" \
    "INFO: native execution is trusted-host, not sandbox runtime isolation" \
    "INFO: the historical exact 45-path profile remains a retained-runtime gate"
