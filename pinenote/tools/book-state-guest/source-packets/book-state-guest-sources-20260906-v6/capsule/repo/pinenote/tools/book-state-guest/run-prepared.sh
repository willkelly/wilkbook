#!/bin/sh
# Execute source/native/static checks from one authenticated private capsule.
set -eu
umask 077

[ "$#" -eq 2 ] || {
    echo "usage: $0 ABSOLUTE_CAPSULE ABSOLUTE_BOOTSTRAP_GUIX" >&2
    exit 2
}
capsule=$1
bootstrap_guix=$2
case $capsule:$bootstrap_guix in /*:/gnu/store/*-guix-command) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$capsule" && pwd -P)" = "$capsule" ] || {
    echo "FAIL: capsule path is not canonical" >&2
    exit 1
}
repo=$capsule/repo
module_view=$capsule/module-view
package_view=$capsule/package-view
tool=$repo/pinenote/tools/book-state-guest
channels=$repo/channels.scm

python_link=$(command -v python3) || { echo "FAIL: python3 not found" >&2; exit 1; }
python=$(/usr/bin/readlink -f -- "$python_link")
case $python in /gnu/store/*-python-*/bin/python*) ;; *)
    echo "FAIL: Python is not one immutable store interpreter" >&2
    exit 1
esac
[ -f "$python" ] && [ -x "$python" ] && [ ! -L "$python" ] || exit 1

run_root=$(mktemp -d /tmp/opencode/book-state-guest-prepared.XXXXXX)
chmod 700 "$run_root"
cleanup () {
    chmod -R u+w "$run_root" 2>/dev/null || true
    rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM
for name in python-home python-cache python-config python-data python-state python-tmp; do
    mkdir -m 700 "$run_root/$name"
done
clean_python () {
    /usr/bin/env -i \
        HOME="$run_root/python-home" \
        XDG_CACHE_HOME="$run_root/python-cache" \
        XDG_CONFIG_HOME="$run_root/python-config" \
        XDG_DATA_HOME="$run_root/python-data" \
        XDG_STATE_HOME="$run_root/python-state" \
        TMPDIR="$run_root/python-tmp" \
        PATH=/usr/bin:/bin LANG=C LC_ALL=C \
        GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH= GUILE_LOAD_COMPILED_PATH= \
        GUILE_EXTENSIONS_PATH= \
        "$python" -I -S -B "$@"
}

clean_python "$tool/check-source-capsule.py" "$capsule"
clean_python "$tool/test-source-capsule.py" "$capsule"

# Seed both caller cache conventions before any legitimate project module is
# loaded.  The negative control proves the bytecode is executable; the private
# pinned wrapper must then load the canonical module without firing either.
sh "$tool/test-cache-boundary.sh" "$capsule" "$run_root/cache-test" \
    "$bootstrap_guix"

clean_python "$tool/test_source.py"

launcher=$tool/pinned-guix.sh
host_private=$run_root/host-private
host_output=$run_root/host-output
mkdir -m 700 "$host_output" "$host_output/ccache" \
    "$host_output/ccache/book-protocol"
sh "$launcher" "$host_private" "$module_view" "$package_view" \
    "$channels" "$bootstrap_guix" \
    shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
    -m "$tool/test-manifest.scm" -- sh -c '
      set -eu
      repo=$1
      tool=$2
      out=$3
      private_home=$4
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
      package_extensions=${GUILE_EXTENSIONS_PATH-}
      test -n "$package_load"
      test -n "$package_compiled"
      unset GUILE GUILE_FLAGS GUILE_SYSTEM_PATH GUILE_SYSTEM_COMPILED_PATH \
        GUILE_SYSTEM_EXTENSIONS_PATH GUIX_PACKAGE_PATH GUIX_BUILD_OPTIONS \
        GUIX_ENVIRONMENT GUIX_EXTENSIONS_PATH GUIX_PROFILE GUIX_LOCPATH \
        PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
      export HOME="$private_home/home"
      export XDG_CACHE_HOME="$private_home/cache"
      export XDG_CONFIG_HOME="$private_home/config"
      export XDG_DATA_HOME="$private_home/data"
      export XDG_STATE_HOME="$private_home/state"
      export GUILE_LOAD_PATH="$load:$package_load"
      export GUILE_LOAD_COMPILED_PATH="$out/ccache:$package_compiled"
      if test -n "$package_extensions"; then
        export GUILE_EXTENSIONS_PATH="$package_extensions"
      fi
      export GUILE_AUTO_COMPILE=0
      export TMPDIR="$out"

      test "$(guile --no-auto-compile -c '\''(display (getenv "HOME"))'\'')" \
        = "$private_home/home"
      test "$(guile --no-auto-compile -c '\''(display (getenv "XDG_CACHE_HOME"))'\'')" \
        = "$private_home/cache"
      guild --version | grep -F "guild (GNU Guile) 3.0.9" >/dev/null

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
       guild compile -Warity-mismatch -Wformat \
         -o "$out/ccache/sandbox-storage-boundary-guile.go" \
         "$tool/sandbox-storage-boundary-guile.scm"

      (cd "$out" && timeout --signal=TERM --kill-after=2 20 \
        guile --no-auto-compile \
          -l "$execution/guest-book-protocol.scm" \
          -s "$tool/test-liveness-boundary.scm" \
          "$tool" "$(command -v guile)")
      cd "$out"
      guile --no-auto-compile \
        -l "$execution/guest-book-protocol.scm" \
        -s "$tool/test-guest-modules.scm" || {
          cat book-state-guest-modules.log >&2
          exit 1
        }
    ' sh "$repo" "$tool" "$host_output" "$host_private"

origin_private=$run_root/origin-private
sh "$launcher" "$origin_private" "$module_view" "$package_view" \
    "$channels" "$bootstrap_guix" repl -q -- "$tool/check-module-origins.scm"
system_private=$run_root/system-private
sh "$launcher" "$system_private" "$module_view" "$package_view" \
    "$channels" "$bootstrap_guix" repl -q -- "$tool/check-system.scm"

printf '%s\n' \
    "PASS: finite guest source/provenance checks from private capsule" \
    "PASS: caller cache poison cannot precede canonical project modules" \
    "PASS: cooperative guest poll plus hard outer wait/revoke/join containment" \
    "PASS: static Guix system graph (no realization, image, QEMU, runsc, or ARM)"
