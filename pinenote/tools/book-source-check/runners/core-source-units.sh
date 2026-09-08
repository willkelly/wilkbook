#!/bin/sh
# Run the fresh-source protocol/session/backend/state-protocol units.
set -eu

[ "$#" -eq 3 ] || {
    echo "usage: core-source-units.sh PRIVATE_REPO RUN_ROOT TASK" >&2
    exit 2
}
repo=$1
run_root=$2
task=$3
case "$task" in protocol|session|backend|state-protocol|all) ;; *) exit 2 ;; esac
case "$repo:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$repo" && pwd -P)" = "$repo" ]
[ "$(CDPATH= cd -- "$run_root" && pwd -P)" = "$run_root" ]

tool="$repo/pinenote/tools/book-source-check"
python_loader="$tool/python-unittest-loader.py"
private_helper="$tool/private-environment.sh"
protocol="$repo/pinenote/tools/book-protocol"
session="$repo/pinenote/tools/book-session"
backend="$repo/pinenote/tools/book-state"
state="$repo/pinenote/tools/book-state-protocol"
mkdir -m 700 "$run_root/ccache" "$run_root/ccache/book-protocol" \
    "$run_root/empty" "$run_root/empty-package-view" \
    "$run_root/python-session"
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"

# Python isolated mode does not honor PYTHONPATH.  Give the session oracle an
# adjacent, already-authenticated codec copy so its import origin is explicit.
cp "$protocol/book_protocol.py" "$run_root/python-session/book_protocol.py"
cp "$session/book_session.py" "$run_root/python-session/book_session.py"
cp "$session/test_book_session.py" "$run_root/python-session/test_book_session.py"
chmod 400 "$run_root/python-session"/*

"$BOOK_SOURCE_GUIX" time-machine -C "$repo/channels.scm" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$run_root/empty-package-view" \
    -m "$tool/source-test-manifest.scm" -- sh -c '
      set -eu
      repo=$1
      run_root=$2
      task=$3
      private_helper=$4
      private_environment=$5
      BOOK_SOURCE_GUIX=$6
      export BOOK_SOURCE_GUIX
      protocol=$repo/pinenote/tools/book-protocol
      session=$repo/pinenote/tools/book-session
      backend=$repo/pinenote/tools/book-state
      state=$repo/pinenote/tools/book-state-protocol
      python_loader=$repo/pinenote/tools/book-source-check/python-unittest-loader.py
      ccache=$run_root/ccache
      . "$private_helper"
      book_source_enter_guix_shell_environment "$private_environment" \
        "$ccache" source-units "$run_root/private-environment.log"

      selected () {
        test "$task" = all || test "$task" = "$1"
      }
      compile () {
        output=$1
        source=$2
        guild compile -Warity-mismatch -Wformat \
          -L "$protocol" -L "$session" -L "$backend" -L "$state" \
          -o "$ccache/$output" "$source" >>"$run_root/compile.log" 2>&1
      }
      run_scheme () {
        label=$1
        expected=$2
        source=$3
        log=$run_root/$label.log
        work=$run_root/work-$label
        mkdir -m 700 "$work"
        if test "$label" = book-protocol-guile; then
          cp "$protocol/malformed-object-vectors.json" \
            "$protocol/numeric-wire-vectors.json" "$work/"
          chmod 400 "$work"/*.json
        fi
        (cd "$work" && timeout 150 guile --no-auto-compile "$source") \
          >"$log" 2>&1
        cat "$log"
        grep -E "# of expected passes[[:space:]]+$expected$" "$log" >/dev/null
        if grep -F "unexpected failures" "$log"; then exit 1; fi
      }

      : >"$run_root/compile.log"
      if selected protocol; then
        compile book-protocol.go "$protocol/book-protocol.scm"
        compile book-protocol/blocking-io.go \
          "$protocol/book-protocol/blocking-io.scm"
        compile test-book-protocol.go "$protocol/test-book-protocol.scm"
      fi
      if selected session; then
        compile book-protocol.go "$protocol/book-protocol.scm"
        compile book-protocol/blocking-io.go \
          "$protocol/book-protocol/blocking-io.scm"
        compile book-session.go "$session/book-session.scm"
        compile test-book-session.go "$session/test-book-session.scm"
      fi
      if selected backend; then
        compile book-state.go "$backend/book-state.scm"
        compile test-book-state.go "$backend/test-book-state.scm"
        compile test-worker.go "$backend/test-worker.scm"
      fi
      if selected state-protocol; then
        compile book-protocol.go "$protocol/book-protocol.scm"
        compile book-state-operation-id.go "$state/book-state-operation-id.scm"
        compile book-state-protocol.go "$state/book-state-protocol.scm"
        compile test-book-state-protocol.go "$state/test-book-state-protocol.scm"
      fi
      cat "$run_root/compile.log"
      if grep -i "warning:" "$run_root/compile.log"; then
        echo "compile warnings are forbidden" >&2
        exit 1
      fi

      export GUILE_LOAD_PATH="$session:$protocol:$backend:$state:$package_load"
      export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
      export GUILE_EXTENSIONS_PATH=${GUILE_EXTENSIONS_PATH-}
      unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
      cd "$run_root/empty"

      if selected protocol; then
        protocol_origin=$(guile --no-auto-compile -c \
          "(use-modules (book-protocol))
           (display (search-path %load-path \"book-protocol.scm\"))")
        test "$protocol_origin" = "$protocol/book-protocol.scm"
        echo "BOOK_PROTOCOL_GUILE_ORIGIN=$protocol_origin" \
          | tee "$run_root/guile-module-origins.log"
        run_scheme book-protocol-guile 49 "$protocol/test-book-protocol.scm"
        python3 -I -S "$python_loader" \
          --module book_protocol "$protocol/book_protocol.py" \
          --test "$protocol/test_book_protocol.py"
        python3 -I -S "$python_loader" \
          --module book_protocol "$protocol/book_protocol.py" \
          --test "$protocol/test_guile_conformance.py"
      fi
      if selected session; then
        run_scheme book-session-guile 227 "$session/test-book-session.scm"
        python3 -I -S "$python_loader" \
          --module book_protocol "$run_root/python-session/book_protocol.py" \
          --module book_session "$run_root/python-session/book_session.py" \
          --test "$run_root/python-session/test_book_session.py"
      fi
      if selected backend; then
        run_scheme book-state-guile 92 "$backend/test-book-state.scm"
        python3 -I -S "$backend/test_book_state_crash.py"
      fi
      if selected state-protocol; then
        run_scheme book-state-protocol-guile 147 \
          "$state/test-book-state-protocol.scm"
      fi
    ' sh "$repo" "$run_root" "$task" "$private_helper" \
        "$private_environment" "$BOOK_SOURCE_GUIX"

printf '%s\n' \
    "PASS: fresh-source unit task $task" \
    "PASS: private ccache and Python -I -S direct source views" \
    "PASS: no build packet, review hash, host profile, or historical log used"
