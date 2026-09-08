#!/bin/sh
# Hermetic entry point for every Guix evaluation and derivation graph query.
set -eu
umask 077

usage () {
    echo "usage: $0 PRIVATE_ROOT MODULE_VIEW PACKAGE_VIEW CHANNELS BOOTSTRAP_GUIX GUIX_ARGUMENT..." >&2
    exit 2
}

[ "$#" -ge 6 ] || usage
private_root=$1
module_view=$2
package_view=$3
channels=$4
bootstrap_guix=$5
shift 5
subcommand=$1
shift
case $subcommand in repl|shell) ;; *)
    echo "FAIL: pinned source boundary admits only repl or shell" >&2
    exit 2
esac

case $private_root:$module_view:$package_view:$channels in
    /*:/*:/*:/*) ;;
    *) usage ;;
esac
case $bootstrap_guix in /gnu/store/*-guix-command) ;; *) usage ;; esac
[ -f "$bootstrap_guix" ] && [ -x "$bootstrap_guix" ] \
    && [ ! -L "$bootstrap_guix" ] \
    && [ "$(/usr/bin/readlink -f -- "$bootstrap_guix")" = "$bootstrap_guix" ] || {
        echo "FAIL: bootstrap Guix is not one canonical immutable store command" >&2
        exit 1
    }
for directory in "$module_view" "$package_view"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] \
        && [ "$(CDPATH= cd -- "$directory" && pwd -P)" = "$directory" ] || {
            echo "FAIL: source view is not a canonical real directory: $directory" >&2
            exit 1
        }
done
[ -f "$channels" ] && [ ! -L "$channels" ] || {
    echo "FAIL: channels source is not regular" >&2
    exit 1
}
[ ! -e "$private_root" ] && [ ! -L "$private_root" ] || {
    echo "FAIL: private process root must be absent" >&2
    exit 1
}
mkdir -m 700 "$private_root"
for name in home cache config data state tmp empty-path compiled; do
    mkdir -m 700 "$private_root/$name"
done

# env -i removes caller HOME/XDG caches before the first Guix/Guile process.
# The only project load path is the explicit positive module/local-file view;
# both the bootstrap and pinned Guix package-discovery paths are a separate
# directory proven to contain zero Scheme files.
exec /usr/bin/env -i \
    HOME="$private_root/home" \
    XDG_CACHE_HOME="$private_root/cache" \
    XDG_CONFIG_HOME="$private_root/config" \
    XDG_DATA_HOME="$private_root/data" \
    XDG_STATE_HOME="$private_root/state" \
    TMPDIR="$private_root/tmp" \
    PATH="$private_root/empty-path" \
    LANG=C LC_ALL=C \
    GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_PATH="$module_view" \
    GUILE_LOAD_COMPILED_PATH="$private_root/compiled" \
    GUILE_EXTENSIONS_PATH= \
    BOOK_STATE_MODULE_VIEW="$module_view" \
    BOOK_STATE_PACKAGE_VIEW="$package_view" \
    "$bootstrap_guix" time-machine -L "$package_view" \
      -C "$channels" --no-substitutes -- \
      "$subcommand" -L "$package_view" "$@"
