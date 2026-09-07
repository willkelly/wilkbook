#!/bin/sh
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
protocol_dir="$repo/pinenote/tools/book-protocol"
backend_snapshot="$repo/pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2"
protocol_packet=/tmp/opencode/book-state-protocol-v2-code-only.kZnkPM
run_root=$(mktemp -d /tmp/opencode/book-state-adapter-v2-run.XXXXXX)
chmod 700 "$run_root"
trap 'rm -rf "$run_root"' EXIT HUP INT TERM
mkdir -m 700 "$run_root/ccache" "$run_root/empty"

cd "$repo"
cat <<'EOF' | sha256sum -c -
10f0b2cf3f8921300ca2644c25d2cabfec2f5cb36dbcdad3d220fbe7128a5e09  doc/reviews/2026-09-06-book-state-protocol-adversarial.md
1c0482da1d1c89b9f153ae5470df3f7317e4a3abf962e5cf756738f3c45adc0c  doc/reviews/2026-09-06-book-state-backend-adapter-adversarial.md
4cd0629b72c56e37ded959483d14c53e448565cac41b116910d51ebce0ee7b46  doc/reviews/2026-09-06-book-state-backend-adversarial.md
d4bc141b24020cf4df8316835a9d4aa1c7eb3c0c0d906ebd1143fee9e996a2f3  pinenote/tools/book-state/build/book-state-backend-review-packet-v2.txt
6520e5ed592cbec37be4605544b7606387d8032335a474ce596a485c022f5426  pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2/MANIFEST.sha256
7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9  pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2/book-state.scm
70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb  pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2/schema-v1.sql
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  pinenote/tools/book-protocol/book-protocol.scm
dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee  pinenote/tools/book-state-protocol/book-state-operation-id.scm
425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257  pinenote/tools/book-state-protocol/book-state-protocol.scm
349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769  pinenote/tools/book-state-protocol/book-state-backend-adapter.scm
ac8ab91a86a9269ab789a5aeb0654948f5a736bfc4e13377180445763149258e  pinenote/tools/book-state-protocol/test-book-state-backend-adapter.scm
19131a0e025fad63b4aeca638e8f27d4a0978b4d655b4370bf71009868b1ecf6  pinenote/tools/book-state-protocol/backend-adapter-v2-test-manifest.scm
34d2e10815fb44952ae806c8747e64cce28d30bca5b83050375a8ea422fd678f  pinenote/tools/book-state-protocol/assert-book-state-adapter-v2-load.scm
48aee5748ae32e2826e72d300aa3f105803b0d45713582a876e0482d21ce2793  pinenote/tools/book-state-protocol/assert-book-state-adapter-v2-ccache.scm
EOF

test -d "$protocol_packet"
printf '%s  %s\n' \
  4410ad29c116c8f5e4199203c4d3da520805c3156c8298e36407d609321d4b64 \
  "$protocol_packet/packet-manifest.json" | sha256sum -c -

(cd "$backend_snapshot" && sha256sum -c MANIFEST.sha256)

guix time-machine -C channels.scm --no-substitutes -- \
  shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
  -m "$tool_dir/backend-adapter-v2-test-manifest.scm" -- sh -c '
    set -eu
    tool_dir=$1
    backend_snapshot=$2
    protocol_dir=$3
    run_root=$4
    ccache=$run_root/ccache

    compile_module () {
      output=$1
      source=$2
      guild compile -Warity-mismatch -Wformat \
        -L "$protocol_dir" -L "$backend_snapshot" -L "$tool_dir" \
        -o "$ccache/$output" "$source"
    }

    compile_module book-protocol.go "$protocol_dir/book-protocol.scm"
    compile_module book-state.go "$backend_snapshot/book-state.scm"
    compile_module book-state-operation-id.go \
      "$tool_dir/book-state-operation-id.scm"
    compile_module book-state-protocol.go "$tool_dir/book-state-protocol.scm"
    compile_module book-state-backend-adapter.go \
      "$tool_dir/book-state-backend-adapter.scm"
    compile_module test-book-state-backend-adapter.go \
      "$tool_dir/test-book-state-backend-adapter.scm"

    inherited_load=${GUILE_LOAD_PATH-}
    inherited_compiled=${GUILE_LOAD_COMPILED_PATH-}
    export GUILE_LOAD_PATH="$protocol_dir:$backend_snapshot:$tool_dir${inherited_load:+:$inherited_load}"
    export GUILE_AUTO_COMPILE=0
    export XDG_CACHE_HOME="$run_root/xdg-cache"
    mkdir -m 700 "$XDG_CACHE_HOME"
    cd "$run_root/empty"

    export GUILE_LOAD_COMPILED_PATH="$inherited_compiled"
    guile --no-auto-compile "$tool_dir/assert-book-state-adapter-v2-load.scm" \
      "$protocol_dir" \
      "$protocol_dir/book-protocol.scm" \
      "$backend_snapshot/book-state.scm" \
      "$tool_dir/book-state-backend-adapter.scm" \
      "$tool_dir/book-state-operation-id.scm" \
      "$tool_dir/book-state-protocol.scm"
    export GUILE_LOAD_COMPILED_PATH="$ccache${inherited_compiled:+:$inherited_compiled}"
    guile --no-auto-compile \
      "$tool_dir/assert-book-state-adapter-v2-ccache.scm" "$ccache"
    guile --no-auto-compile "$tool_dir/test-book-state-backend-adapter.scm" \
      | tee "$run_root/adapter-tests.log"
    grep -F "# of expected passes      42" "$run_root/adapter-tests.log"
    if grep -F "unexpected failures" "$run_root/adapter-tests.log"; then
      exit 1
    fi
  ' sh "$tool_dir" "$backend_snapshot" "$protocol_dir" "$run_root"

if grep -Eq '\(book-state\)|\(sqlite3\)|guile-sqlite3' \
     "$tool_dir/book-state-operation-id.scm"; then
  echo "SQLite-free operation-ID module imports trusted storage" >&2
  exit 1
fi

printf '%s\n' \
  "PASS: accepted backend v2 snapshot was the loaded Book State module" \
  "PASS: unique private ccache prevented ambient compiled-module selection" \
  "PASS: real backend adapter v2 join gate (network/substitutes disabled)" \
  "PASS: guile-sqlite3 remained in the trusted host-test closure only"
