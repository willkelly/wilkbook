#!/bin/sh
# Source-only, no-fetch host gate for the finite Book State guest candidate.
set -eu

[ "$#" -eq 0 ] || {
    echo "run-tests.sh accepts no arguments" >&2
    exit 2
}

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd -P)
channels="$repo/channels.scm"

python3 -I -S "$tool_dir/test_source.py"

run_root=$(mktemp -d /tmp/opencode/book-state-guest-host.XXXXXX)
chmod 700 "$run_root"
trap 'rm -rf -- "$run_root"' EXIT HUP INT TERM
mkdir -m 700 "$run_root/ccache" "$run_root/ccache/book-protocol"

env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
    -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP -u PYTHONUSERBASE \
    guix time-machine -C "$channels" --no-substitutes -- \
    shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
    -m "$tool_dir/test-manifest.scm" -- sh -c '
      set -eu
      repo=$1
      tool=$2
      out=$3
      join="$repo/pinenote/tools/book-state-reader-join"
      protocol="$repo/pinenote/tools/book-protocol"
      backend="$repo/pinenote/tools/book-state"
      state="$repo/pinenote/tools/book-state-protocol"
      session="$repo/pinenote/tools/book-state-protocol/session-integration"
      execution="$repo/pinenote/tools/book-execution-spike"
      ui="$repo/pinenote/tools/book-state-reader"
      load="$tool:$execution:$ui:$join:$join/empty-action-successor:$protocol:$backend:$state:$session"
      package_load=${GUILE_LOAD_PATH-}
      package_compiled=${GUILE_LOAD_COMPILED_PATH-}
      test -n "$package_load"
      test -n "$package_compiled"
      export GUILE_LOAD_PATH="$load:$package_load"
      export GUILE_LOAD_COMPILED_PATH="$out/ccache:$package_compiled"
      export GUILE_AUTO_COMPILE=0
      export TMPDIR="$out"

      # First executable gate: the exact BSG-1 FD-3-free precondition and the
      # occupied/aliased/closed-stdio matrix must pass before broader modules.
      python3 -I -S "$tool/test-fd3-exec.py"

      guild compile -Warity-mismatch -Wformat \
        -L "$tool" -L "$execution" -L "$ui" -L "$join" \
        -L "$join/empty-action-successor" -L "$protocol" -L "$backend" \
        -L "$state" -L "$session" \
        -o "$out/ccache/book-state-guest-authority.go" \
        "$tool/book-state-guest-authority.scm"
      guild compile -Warity-mismatch -Wformat \
        -o "$out/ccache/runsc-fd3-exec.go" "$tool/runsc-fd3-exec.scm"
      guild compile -Warity-mismatch -Wformat \
        -L "$execution" -o "$out/ccache/oci-book-bundle.go" \
        "$tool/oci-state-book-bundle.scm"

      # BSG-2: the real authority poll must return cooperatively, while the
      # accepted external process owner must contain deliberately uninterruptible
      # wait/revoke/join fixtures.  timeout is only a fail-safe for the host test;
      # assertions require the inner guardian to return its own timeout result.
      (
        cd "$out"
        timeout --signal=TERM --kill-after=2 20 \
          guile --no-auto-compile \
            -l "$execution/guest-book-protocol.scm" \
            -s "$tool/test-liveness-boundary.scm" \
            "$tool" "$(command -v guile)"
      )

      cd "$out"
      guile --no-auto-compile \
        -l "$execution/guest-book-protocol.scm" \
        -s "$tool/test-guest-modules.scm" || {
          cat book-state-guest-modules.log >&2
          exit 1
        }
    ' sh "$repo" "$tool_dir" "$run_root"

env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
    guix time-machine -C "$channels" --no-substitutes -- \
    repl -L "$repo" -- "$tool_dir/check-system.scm"

printf '%s\n' \
    "PASS: finite guest source/provenance checks" \
    "PASS: cooperative guest poll plus hard outer wait/revoke/join containment" \
    "PASS: actual accepted Guile backend/bridge modules and mocked UI transport" \
    "PASS: static Guix system graph (no realization, image, QEMU, runsc, or ARM)"
