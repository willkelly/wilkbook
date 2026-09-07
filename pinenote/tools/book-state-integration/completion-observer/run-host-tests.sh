#!/bin/sh
set -eu

observer_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$observer_dir/../../../.." && pwd)
integration_dir="$repo/pinenote/tools/book-state-integration"
accepted="$integration_dir/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs"
bsd1="$repo/pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4"
book_session="$repo/pinenote/tools/book-session"
run_root=$(mktemp -d /tmp/opencode/book-state-completion-observer.XXXXXX)
chmod 700 "$run_root"
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
mkdir -m 700 "$run_root/private" "$run_root/ccache" \
  "$run_root/empty" "$run_root/book-load"

mkdir -p "$observer_dir/build"
host_log="$observer_dir/build/completion-observer-host-check-v1.log"
temporary_log="$run_root/host-check.log"

if env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
     guix time-machine -C "$accepted/channels.scm" --no-substitutes -- \
       shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
       -m "$observer_dir/test-manifest.scm" -- sh -c '
    set -eu
    run_root=$1
    repo=$2
    observer_dir=$3
    accepted=$4
    bsd1=$5
    book_session=$6
    private=$run_root/private
    ccache=$run_root/ccache

    cd "$repo"
    sha256sum -c "$observer_dir/SOURCE-IDENTITIES.sha256"
    cat <<EOF | sha256sum -c -
42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/MANIFEST.sha256
7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/backend/book-state.scm
70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/backend/schema-v1.sql
425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/state-protocol/book-state-protocol.scm
349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/state-protocol/book-state-backend-adapter.scm
dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/state-protocol/book-state-operation-id.scm
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/book-protocol/book-protocol.scm
543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/book-protocol/book-protocol/blocking-io.scm
f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301  pinenote/tools/book-state-integration/completion-observer/base/book-session-v4.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  pinenote/tools/book-state-integration/completion-observer/book-state-session-delegate.scm
dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec  pinenote/tools/book-session/test-book-session.scm
4008d9e4491e814b8a33d9a015038eb8684f2c9a0378966839cfd21309055562  pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/test-book-session-state-integration.scm
a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab  pinenote/tools/book-state-reader/SHA256SUMS
56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301  doc/reviews/2026-09-06-book-state-reader-adversarial.md
4a3e650c1519ae98c9c17548fad7b752b88c331b3f0040a8db1b7d9607307c34  doc/reviews/2026-09-06-book-session-state-delegate-adversarial.md
16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877  doc/reviews/2026-09-06-book-state-native-integration-adversarial.md
661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1  pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v1/accepted-inputs/channels.scm
EOF

    cp "$observer_dir/base/book-session-v4.scm" "$private/book-session.scm"
    chmod u+w "$private/book-session.scm"
    patch -s "$private/book-session.scm" \
      < "$observer_dir/book-session-completion-observer.patch"
    cmp "$private/book-session.scm" "$observer_dir/candidate/book-session.scm"
    cp "$observer_dir/candidate/book-session.scm" \
      "$private/book-session-inverse.scm"
    chmod u+w "$private/book-session-inverse.scm"
    patch -Rs "$private/book-session-inverse.scm" \
      < "$observer_dir/book-session-completion-observer.patch"
    cmp "$private/book-session-inverse.scm" \
      "$observer_dir/base/book-session-v4.scm"

    compile_log=$run_root/compile.log
    : > "$compile_log"
    compile_module () {
      output=$1
      source=$2
      mkdir -p "$(dirname "$ccache/$output")"
      guild compile -Warity-mismatch -Wformat \
        -L "$private" -L "$observer_dir" \
        -L "$accepted/book-protocol" -L "$accepted/state-protocol" \
        -L "$accepted/backend" \
        -o "$ccache/$output" "$source" >> "$compile_log" 2>&1
    }

    compile_module book-protocol.go \
      "$accepted/book-protocol/book-protocol.scm"
    compile_module book-protocol/blocking-io.go \
      "$accepted/book-protocol/book-protocol/blocking-io.scm"
    compile_module book-state-operation-id.go \
      "$accepted/state-protocol/book-state-operation-id.scm"
    compile_module book-state-protocol.go \
      "$accepted/state-protocol/book-state-protocol.scm"
    compile_module book-state-backend-adapter.go \
      "$accepted/state-protocol/book-state-backend-adapter.scm"
    compile_module book-state.go "$accepted/backend/book-state.scm"
    compile_module book-state-session-delegate.go \
      "$observer_dir/book-state-session-delegate.scm"
    compile_module book-session.go "$private/book-session.scm"
    compile_module test-book-session.go "$book_session/test-book-session.scm"
    compile_module test-book-session-state-integration.go \
      "$bsd1/test-book-session-state-integration.scm"
    compile_module test-completion-observer.go \
      "$observer_dir/test-completion-observer.scm"
    compile_module test-real-completion-observer.go \
      "$observer_dir/test-real-completion-observer.scm"
    compile_module observer-book.go "$observer_dir/observer-book.scm"
    cat "$compile_log"
    if grep -i "warning:" "$compile_log"; then
      echo "compile warnings are forbidden" >&2
      exit 1
    fi

    module_root=$(guile -c "(display (car %load-path))")
    inherited_load=${GUILE_LOAD_PATH-}
    inherited_compiled=${GUILE_LOAD_COMPILED_PATH-}
    export GUILE_LOAD_PATH="$private:$observer_dir:$accepted/book-protocol:$accepted/state-protocol:$accepted/backend${inherited_load:+:$inherited_load}"
    export GUILE_LOAD_COMPILED_PATH="$ccache${inherited_compiled:+:$inherited_compiled}"
    export GUILE_AUTO_COMPILE=0
    export XDG_CACHE_HOME="$run_root/xdg-cache"
    mkdir -m 700 "$XDG_CACHE_HOME"

    ln -s "$module_root/json.scm" "$run_root/book-load/json.scm"
    ln -s "$module_root/json" "$run_root/book-load/json"
    test ! -e "$run_root/book-load/sqlite3.scm"
    export OBSERVER_BOOK_SOURCE="$observer_dir/observer-book.scm"
    export OBSERVER_BOOK_GUILE_LOAD_PATH="$run_root/book-load:$accepted/book-protocol"
    export OBSERVER_BOOK_GUILE_LOAD_COMPILED_PATH=""

    run_test () {
      label=$1
      expected=$2
      seconds=$3
      source=$4
      output=$run_root/$label.log
      if ! timeout "$seconds" guile --no-auto-compile "$source" \
           > "$output" 2>&1; then
        cat "$output"
        echo "$label failed" >&2
        exit 1
      fi
      cat "$output"
      grep -F "# of expected passes      $expected" "$output"
      if grep -F "unexpected failures" "$output"; then
        exit 1
      fi
    }

    cd "$run_root/empty"
    run_test accepted-book-session 227 120 \
      "$book_session/test-book-session.scm"
    run_test accepted-bsd1 61 120 \
      "$bsd1/test-book-session-state-integration.scm"
    run_test focused-observer 37 90 \
      "$observer_dir/test-completion-observer.scm"
    run_test real-backend-native-book 37 120 \
      "$observer_dir/test-real-completion-observer.scm"

    printf "%s\n" \
      "PASS: immutable accepted component inputs authenticated" \
      "PASS: exact observer patch reproduced candidate and reversed to base" \
      "PASS: accepted Book Session regression 227/227" \
      "PASS: accepted BSD-1 focused regression 61/61" \
      "PASS: finite observer focused tests 37/37" \
      "PASS: accepted adapter/backend/SQLite plus native book 37/37" \
      "PASS: 4096-NUL delivery and 24681-byte reservation preserved" \
      "PASS: child load view excludes guile-sqlite3" \
      "PASS: bounded offline Guix host gate"
  ' sh "$run_root" "$repo" "$observer_dir" "$accepted" "$bsd1" \
      "$book_session" > "$temporary_log" 2>&1; then
  cp "$temporary_log" "$host_log"
  cat "$temporary_log"
else
  status=$?
  cp "$temporary_log" "$host_log"
  cat "$temporary_log"
  exit "$status"
fi
