#!/bin/sh
set -eu

integration_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tool_dir=$(CDPATH= cd -- "$integration_dir/../.." && pwd)
repo=$(CDPATH= cd -- "$integration_dir/../../../../.." && pwd)
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
d60757f38812bd82b03d1e075303036dd0dae740bca4b5f2ba8e5f4b7b7ec813  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/base/book-session-v3.scm
f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/candidate/book-session.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/book-state-session-delegate.scm
4008d9e4491e814b8a33d9a015038eb8684f2c9a0378966839cfd21309055562  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/test-book-session-state-integration.scm
d779ed2c257d9fe0e995011e5a8c83ba9c6945b7eb189648067a29ed7a7d0280  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/book-session-state-delegate.patch
c229c218f48debd36d7209dd1106d22b6e5b9ec34c9f35e979b4ea8682a32d74  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/book-session-bsd1-correction.patch
d8bc9e8d542262d2888993859361aa87d7149de1e678f08972aac9a1d33f1d7c  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/test-manifest.scm
EOF

cp "$book_session_dir/book-session.scm" "$run_root/private/book-session.scm"
patch -s "$run_root/private/book-session.scm" \
  < "$integration_dir/book-session-state-delegate.patch"
printf '%s  %s\n' \
  f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301 \
  "$run_root/private/book-session.scm" | sha256sum -c -
cmp "$run_root/private/book-session.scm" \
    "$integration_dir/candidate/book-session.scm"

cp "$integration_dir/base/book-session-v3.scm" \
   "$run_root/private/book-session-v3.scm"
chmod u+w "$run_root/private/book-session-v3.scm"
printf '%s  %s\n' \
  d60757f38812bd82b03d1e075303036dd0dae740bca4b5f2ba8e5f4b7b7ec813 \
  "$run_root/private/book-session-v3.scm" | sha256sum -c -
patch -s "$run_root/private/book-session-v3.scm" \
  < "$integration_dir/book-session-bsd1-correction.patch"
cmp "$run_root/private/book-session-v3.scm" \
    "$integration_dir/candidate/book-session.scm"

cp "$run_root/private/book-session.scm" \
   "$run_root/private/book-session-inverse.scm"
patch -Rs "$run_root/private/book-session-inverse.scm" \
  < "$integration_dir/book-session-state-delegate.patch"
cmp "$run_root/private/book-session-inverse.scm" \
    "$book_session_dir/book-session.scm"

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
    grep -F "# of expected passes      61" \
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
  "PASS: full patch reproduced the candidate and reversed to accepted source" \
  "PASS: focused BSD-1 patch reproduced the successor from blocked v3" \
  "PASS: 24681-byte escaped-state bound and completion fail-close held" \
  "PASS: one-slot state worker kept surface pump responsive" \
  "PASS: no Book State backend or SQLite dependency entered this candidate" \
  "PASS: host-only session integration gate (network/substitutes disabled)"
