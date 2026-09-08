#!/bin/sh
# Seed executable caller bytecode, then prove pinned entry excludes both caches.
set -eu
umask 077

[ "$#" -eq 3 ] || {
    echo "usage: $0 ABSOLUTE_CAPSULE ABSOLUTE_RUN_ROOT ABSOLUTE_BOOTSTRAP_GUIX" >&2
    exit 2
}
capsule=$1
run_root=$2
bootstrap_guix=$3
repo=$capsule/repo
module_view=$capsule/module-view
package_view=$capsule/package-view
tool=$repo/pinenote/tools/book-state-guest
launcher=$tool/pinned-guix.sh
channels=$repo/channels.scm
mkdir -m 700 "$run_root"

# Obtain the exact pinned Guile tools through the already-private time machine.
tools_record=$run_root/pinned-tools.txt
sh "$launcher" "$run_root/tool-private" "$module_view" "$package_view" \
    "$channels" "$bootstrap_guix" \
    shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
    -m "$tool/test-manifest.scm" -- sh -c '
      set -eu
      printf "%s\n%s\n" "$(readlink -f "$(command -v guile)")" \
        "$(readlink -f "$(command -v guild)")"
    ' >"$tools_record"
guile=$(sed -n '1p' "$tools_record")
guild=$(sed -n '2p' "$tools_record")
case $guile:$guild in /gnu/store/*-guile-*/bin/guile:/gnu/store/*-guile-*/bin/guild) ;;
    *) echo "FAIL: pinned shell returned unexpected Guile tools" >&2; exit 1 ;;
esac

source_file=$module_view/pinenote/systems/pinenote-book-state-reader.scm
malicious=$run_root/malicious-reader.scm
cat >"$malicious" <<EOF
(define-module (pinenote systems pinenote-book-state-reader)
  #:export (pinenote-book-state-reader-operating-system))
(call-with-output-file (getenv "BOOK_STATE_POISON_CANARY")
  (lambda (port) (display "caller cache executed\n" port)))
(define pinenote-book-state-reader-operating-system #f)
EOF
chmod 400 "$malicious"

seed_one () {
    label=$1
    xdg_mode=$2
    attacker_home=$3
    attacker_cache=$4
    canary=$5
    mkdir -m 700 -p "$attacker_home" "$attacker_cache"
    run_attacker () {
      if [ "$xdg_mode" = unset ]; then
        /usr/bin/env -u XDG_CACHE_HOME HOME="$attacker_home" "$@"
      else
        /usr/bin/env HOME="$attacker_home" XDG_CACHE_HOME="$attacker_cache" "$@"
      fi
    }
    compiled=$(run_attacker /usr/bin/env \
      GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH="$module_view" \
      GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
      "$guile" --no-auto-compile -c \
      '(use-modules (system base compile))
       (display (compiled-file-name (cadr (command-line))))' "$source_file")
    case $compiled in "$attacker_cache"/guile/ccache/*) ;;
      *) echo "FAIL: unexpected caller cache path: $compiled" >&2; exit 1 ;;
    esac
    mkdir -m 700 -p "$(dirname "$compiled")"
    run_attacker /usr/bin/env \
      GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH="$module_view" \
      GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
      "$guild" compile -o "$compiled" "$malicious"
    /usr/bin/touch -d 'next hour' "$compiled"

    # The negative control must execute the poison; otherwise this is not a
    # cache-boundary regression test.
    run_attacker /usr/bin/env \
      GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH="$module_view" \
      GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
      BOOK_STATE_POISON_CANARY="$canary" \
      "$guile" --no-auto-compile -c \
      '(resolve-interface (quote (pinenote systems pinenote-book-state-reader)))'
    [ -f "$canary" ] || { echo "FAIL: caller poison control did not execute" >&2; exit 1; }
    rm -f "$canary"

    run_attacker /usr/bin/env \
      GUILE_LOAD_PATH="$run_root/poison-load" \
      GUILE_LOAD_COMPILED_PATH="$run_root/poison-compiled" \
      GUILE_EXTENSIONS_PATH="$run_root/poison-extensions" \
      GUILE_SYSTEM_PATH="$run_root/poison-system" \
      GUILE_SYSTEM_COMPILED_PATH="$run_root/poison-system-compiled" \
      GUIX_PACKAGE_PATH="$run_root/poison-packages" \
      GUIX_BUILD_OPTIONS=--poison GUIX_ENVIRONMENT="$run_root/poison-env" \
      BOOK_STATE_POISON_CANARY="$canary" \
      sh "$launcher" "$run_root/safe-$label" "$module_view" "$package_view" \
        "$channels" "$bootstrap_guix" repl -q -- "$tool/check-module-origins.scm" \
        >"$run_root/safe-$label.log"
    [ ! -e "$canary" ] || {
        echo "FAIL: private pinned entry executed caller cache: $label" >&2
        exit 1
    }
    grep -F "PASS: all project module origins are the exact private positive view" \
      "$run_root/safe-$label.log" >/dev/null
    echo "PASS: $label executable caller cache excluded before project module load"
}

seed_one default-home unset "$run_root/attacker-default-home" \
    "$run_root/attacker-default-home/.cache" "$run_root/default-canary"
seed_one explicit-xdg set "$run_root/attacker-explicit-home" \
    "$run_root/attacker-explicit-cache" "$run_root/explicit-canary"
echo "PASS: caller HOME and XDG Guile cache boundaries are closed"
