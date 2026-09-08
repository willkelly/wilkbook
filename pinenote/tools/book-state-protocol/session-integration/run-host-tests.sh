#!/bin/sh
set -eu

integration_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tool_dir=$(CDPATH= cd -- "$integration_dir/.." && pwd)
repo=$(CDPATH= cd -- "$integration_dir/../../../.." && pwd)
book_session_dir="$repo/pinenote/tools/book-session"
book_protocol_dir="$repo/pinenote/tools/book-protocol"
run_root=$(mktemp -d /tmp/opencode/book-session-state-integration.XXXXXX)
chmod 700 "$run_root"
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
mkdir -m 700 "$run_root/private" "$run_root/ccache" "$run_root/empty"

cd "$repo"
cat <<'EOF' | sha256sum -c -
f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668  pinenote/tools/book-session/book-session.scm
dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec  pinenote/tools/book-session/test-book-session.scm
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  pinenote/tools/book-protocol/book-protocol.scm
dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee  pinenote/tools/book-state-protocol/book-state-operation-id.scm
425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257  pinenote/tools/book-state-protocol/book-state-protocol.scm
d60757f38812bd82b03d1e075303036dd0dae740bca4b5f2ba8e5f4b7b7ec813  pinenote/tools/book-state-protocol/session-integration/candidate/book-session.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  pinenote/tools/book-state-protocol/session-integration/book-state-session-delegate.scm
a7bc9c2a6571ba5c6725e5980d8daa41d6d8ee0c7d573602e36390e880f4a065  pinenote/tools/book-state-protocol/session-integration/test-book-session-state-integration.scm
42fafd8f34d6ff1a64d4c50824e210119e0efd3e2a1b36fb8fa1104d17aac050  pinenote/tools/book-state-protocol/session-integration/book-session-state-delegate.patch
d8bc9e8d542262d2888993859361aa87d7149de1e678f08972aac9a1d33f1d7c  pinenote/tools/book-state-protocol/session-integration/test-manifest.scm
EOF

cp "$book_session_dir/book-session.scm" "$run_root/private/book-session.scm"
patch -s "$run_root/private/book-session.scm" \
  < "$integration_dir/book-session-state-delegate.patch"
printf '%s  %s\n' \
  d60757f38812bd82b03d1e075303036dd0dae740bca4b5f2ba8e5f4b7b7ec813 \
  "$run_root/private/book-session.scm" | sha256sum -c -
cmp "$run_root/private/book-session.scm" \
    "$integration_dir/candidate/book-session.scm"

guix time-machine -C channels.scm --no-substitutes -- \
  shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
  -m "$integration_dir/test-manifest.scm" -- sh -c '
    set -eu
    run_root=$1
    integration_dir=$2
    tool_dir=$3
    book_session_dir=$4
    book_protocol_dir=$5
    ccache=$run_root/ccache
    private=$run_root/private

    compile_module () {
      output=$1
      source=$2
      guild compile -Warity-mismatch -Wformat \
        -L "$private" -L "$integration_dir" -L "$tool_dir" \
        -L "$book_protocol_dir" -o "$ccache/$output" "$source"
    }

    compile_module book-protocol.go "$book_protocol_dir/book-protocol.scm"
    compile_module book-state-operation-id.go "$tool_dir/book-state-operation-id.scm"
    compile_module book-state-protocol.go "$tool_dir/book-state-protocol.scm"
    compile_module book-state-session-delegate.go \
      "$integration_dir/book-state-session-delegate.scm"
    compile_module book-session.go "$private/book-session.scm"
    compile_module test-book-session.go "$book_session_dir/test-book-session.scm"
    compile_module test-book-session-state-integration.go \
      "$integration_dir/test-book-session-state-integration.scm"

    inherited_load=${GUILE_LOAD_PATH-}
    inherited_compiled=${GUILE_LOAD_COMPILED_PATH-}
    export GUILE_LOAD_PATH="$private:$integration_dir:$tool_dir:$book_protocol_dir${inherited_load:+:$inherited_load}"
    export GUILE_LOAD_COMPILED_PATH="$ccache${inherited_compiled:+:$inherited_compiled}"
    export GUILE_AUTO_COMPILE=0
    export XDG_CACHE_HOME="$run_root/xdg-cache"
    mkdir -m 700 "$XDG_CACHE_HOME"
    cd "$run_root/empty"

    guile --no-auto-compile "$book_session_dir/test-book-session.scm" \
      | tee "$run_root/accepted-regression.log"
    grep -F "# of expected passes      227" \
      "$run_root/accepted-regression.log"
    if grep -F "unexpected failures" "$run_root/accepted-regression.log"; then
      exit 1
    fi

    guile --no-auto-compile \
      "$integration_dir/test-book-session-state-integration.scm" \
      | tee "$run_root/focused-integration.log"
    grep -F "# of expected passes      30" \
      "$run_root/focused-integration.log"
    if grep -F "unexpected failures" "$run_root/focused-integration.log"; then
      exit 1
    fi
  ' sh "$run_root" "$integration_dir" "$tool_dir" \
    "$book_session_dir" "$book_protocol_dir"

if grep -Eq '\(book-state\)|\(sqlite3\)|guile-sqlite3' \
     "$integration_dir/book-state-session-delegate.scm" \
     "$integration_dir/candidate/book-session.scm" \
     "$integration_dir/test-book-session-state-integration.scm"; then
  echo "session integration candidate imports trusted storage/SQLite" >&2
  exit 1
fi

printf '%s\n' \
  "PASS: accepted Book Session core source remained unchanged" \
  "PASS: private patch reproduced the exact candidate source" \
  "PASS: one-slot state worker kept surface pump responsive" \
  "PASS: no Book State backend or SQLite dependency entered this candidate" \
  "PASS: host-only session integration gate (network/substitutes disabled)"
