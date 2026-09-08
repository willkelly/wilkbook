#!/bin/sh
# Reproduce the caller-cache counterexample, then prove public Guile entry is closed.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: test-private-cache.sh PREPARED_ROOT RUN_ROOT" >&2
    exit 2
}
prepared=$1
run_root=$2
case "$prepared:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$prepared" && pwd -P)" = "$prepared" ]
[ "$(CDPATH= cd -- "$run_root" && pwd -P)" = "$run_root" ]

repo="$prepared/repo"
tool="$repo/pinenote/tools/book-source-check"
runner="$tool/runners/core-source-units.sh"
private_helper="$tool/private-environment.sh"
manifest="$tool/source-test-manifest.scm"
channels="$repo/channels.scm"
empty_view="$run_root/empty-package-view"
mkdir -m 700 "$empty_view"
. "$private_helper"
book_source_require_guix_launcher
setup_environment="$run_root/setup-private-environment"
book_source_create_private_environment "$setup_environment"

tool_paths=$("$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$empty_view" -m "$manifest" -- sh -c '
      set -eu
      guild_link=$(command -v guild)
      guild_real=$(readlink -f "$guild_link")
      guile_real=$(readlink -f "$(command -v guile)")
      case "$guild_link:$guild_real:$guile_real" in
        /gnu/store/*:/gnu/store/*:/gnu/store/*) ;;
        *) exit 1 ;;
      esac
      printf "%s\n%s\n%s\n" "$guild_link" "$guild_real" "$guile_real"
    ')
guild_link=$(printf '%s\n' "$tool_paths" | sed -n '1p')
guild_real=$(printf '%s\n' "$tool_paths" | sed -n '2p')
guile_real=$(printf '%s\n' "$tool_paths" | sed -n '3p')
[ -n "$guild_link" ] && [ -n "$guild_real" ] && [ -n "$guile_real" ]
[ "$(printf '%s\n' "$tool_paths" | wc -l)" -eq 3 ]
cp "$guild_real" "$run_root/compiler-guild"
chmod 500 "$run_root/compiler-guild"

seed_poison () {
    label=$1
    attacker_home=$2
    attacker_xdg=$3
    canary=$4
    mkdir -m 700 -p "$attacker_home" "$attacker_xdg"
    malicious="$run_root/malicious-guild-$label.scm"
    cat >"$malicious" <<EOF
(define-module (guild) #:export (main))
(define (main args)
  (call-with-output-file "$canary"
    (lambda (port) (display "ambient $label ccache executed\\n" port)))
  93)
EOF
    chmod 400 "$malicious"
    cache_file=$(env HOME="$attacker_home" XDG_CACHE_HOME="$attacker_xdg" \
        GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH="$setup_environment/empty-load" \
        GUILE_LOAD_COMPILED_PATH="$setup_environment/empty-compiled" \
        GUILE_EXTENSIONS_PATH="$setup_environment/empty-extensions" \
        "$guile_real" --no-auto-compile -c \
        '(use-modules (system base compile))
         (display (compiled-file-name (cadr (command-line))))' \
        "$guild_link")
    case "$cache_file" in "$attacker_xdg"/guile/ccache/*/gnu/store/*/bin/guild.go) ;;
        *) echo "unexpected Guile cache path: $cache_file" >&2; exit 1 ;;
    esac
    mkdir -m 700 -p "$(dirname "$cache_file")"

    "$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- \
        shell --pure --no-grafts --max-jobs=1 --cores=2 \
        -L "$empty_view" bubblewrap bash-minimal -- sh -c '
          set -eu
          run_root=$1
          malicious=$2
          guild_link=$3
          guild_real=$4
          guile_real=$5
          cache_file=$6
          setup_environment=$7
          bwrap --die-with-parent --new-session --ro-bind / / \
            --dev /dev --proc /proc --bind "$run_root" "$run_root" \
            --bind "$malicious" "$guild_real" \
            --setenv HOME "$setup_environment/home" \
            --setenv XDG_CACHE_HOME "$setup_environment/xdg-cache" \
            --setenv XDG_CONFIG_HOME "$setup_environment/xdg-config" \
            --setenv XDG_DATA_HOME "$setup_environment/xdg-data" \
            --setenv XDG_STATE_HOME "$setup_environment/xdg-state" \
            --setenv GUILE_AUTO_COMPILE 0 \
            --setenv GUILE_LOAD_PATH "$setup_environment/empty-load" \
            --setenv GUILE_LOAD_COMPILED_PATH "$setup_environment/empty-compiled" \
            --setenv GUILE_EXTENSIONS_PATH "$setup_environment/empty-extensions" \
            "$guile_real" -e "(@@ (guild) main)" \
              -s "$run_root/compiler-guild" compile -o "$cache_file" \
              "$guild_link"
        ' sh "$run_root" "$malicious" "$guild_link" "$guild_real" \
            "$guile_real" "$cache_file" "$setup_environment"
    [ -f "$cache_file" ] && [ ! -e "$canary" ]
    printf '%s\n' \
        "CACHE-POISON-LABEL=$label" \
        "CACHE-POISON-GUILD=$guild_link" \
        "CACHE-POISON-GUILD-REAL=$guild_real" \
        "CACHE-POISON-GUILE-REAL=$guile_real" \
        "CACHE-POISON-PATH=$cache_file" \
        "CACHE-POISON-CANARY=$canary"
}

default_home="$run_root/attacker-default-home"
default_xdg="$default_home/.cache"
explicit_home="$run_root/attacker-explicit-home"
explicit_xdg="$run_root/attacker-explicit-xdg"
default_canary="$run_root/default-home-canary"
explicit_canary="$run_root/explicit-xdg-canary"
seed_poison default-home "$default_home" "$default_xdg" "$default_canary"
seed_poison explicit-xdg "$explicit_home" "$explicit_xdg" "$explicit_canary"

run_poisoned_pipeline () {
    label=$1
    attacker_home=$2
    xdg_mode=$3
    attacker_xdg=$4
    canary=$5
    output="$run_root/pipeline-$label"
    mkdir -m 700 "$output"
    if [ "$xdg_mode" = unset ]; then
        env -u XDG_CACHE_HOME HOME="$attacker_home" \
            XDG_CONFIG_HOME="$run_root/poison-config" \
            XDG_DATA_HOME="$run_root/poison-data" \
            XDG_STATE_HOME="$run_root/poison-state" \
            GUILE="$run_root/unlisted-guile" \
            GUILE_FLAGS='--unlisted-flag' \
            GUILE_LOAD_PATH="$run_root/poison-load" \
            GUILE_LOAD_COMPILED_PATH="$run_root/poison-compiled" \
            GUILE_EXTENSIONS_PATH="$run_root/poison-extensions" \
            GUIX_PACKAGE_PATH="$run_root/poison-packages" \
            GUIX_BUILD_OPTIONS='--unlisted-option' \
            GUIX_EXTENSIONS_PATH="$run_root/poison-guix-extensions" \
            sh "$runner" "$repo" "$output" protocol
    else
        env HOME="$attacker_home" XDG_CACHE_HOME="$attacker_xdg" \
            XDG_CONFIG_HOME="$run_root/poison-config" \
            XDG_DATA_HOME="$run_root/poison-data" \
            XDG_STATE_HOME="$run_root/poison-state" \
            GUILE="$run_root/unlisted-guile" \
            GUILE_FLAGS='--unlisted-flag' \
            GUILE_LOAD_PATH="$run_root/poison-load" \
            GUILE_LOAD_COMPILED_PATH="$run_root/poison-compiled" \
            GUILE_EXTENSIONS_PATH="$run_root/poison-extensions" \
            GUIX_PACKAGE_PATH="$run_root/poison-packages" \
            GUIX_BUILD_OPTIONS='--unlisted-option' \
            GUIX_EXTENSIONS_PATH="$run_root/poison-guix-extensions" \
            sh "$runner" "$repo" "$output" protocol
    fi
    [ ! -e "$canary" ] || {
        echo "unlisted caller bytecode executed for $label" >&2
        exit 1
    }
    expected_home="$output/private-environment/home"
    expected_cache="$output/private-environment/xdg-cache"
    grep -Fx "PRIVATE-GUILE-HOME=$expected_home" \
        "$output/private-environment.log" >/dev/null
    grep -Fx "PRIVATE-GUILE-XDG-CACHE=$expected_cache" \
        "$output/private-environment.log" >/dev/null
    grep -Fx "BOOK_PROTOCOL_GUILE_ORIGIN=$repo/pinenote/tools/book-protocol/book-protocol.scm" \
        "$output/guile-module-origins.log" >/dev/null
    echo "PASS: $label preseed could not execute before the legitimate protocol pipeline"
}

run_poisoned_pipeline default-home "$default_home" unset "$default_xdg" \
    "$default_canary"
run_poisoned_pipeline explicit-xdg "$explicit_home" set "$explicit_xdg" \
    "$explicit_canary"
echo "PASS: private cache boundary rejects both caller Guile ccache locations"
