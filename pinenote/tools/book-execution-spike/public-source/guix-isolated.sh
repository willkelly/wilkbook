#!/bin/sh
# Fixed process boundary for every Guix entry point used by the public gate.
set -eu

usage () {
    echo "usage: $0 PRIVATE_ROOT MODULE_VIEW CHANNELS BOOTSTRAP_GUIX GUIX_ARGUMENT..." >&2
    exit 2
}

[ "$#" -ge 5 ] || usage
private_root=$1
module_view=$2
channels=$3
bootstrap_guix=$4
shift 4

case $private_root in /*) ;; *) usage ;; esac
case $module_view in /*) ;; *) usage ;; esac
case $channels in /*) ;; *) usage ;; esac
case $bootstrap_guix in /gnu/store/*-guix-command) ;; *) usage ;; esac

for directory in home cache config data state tmp empty-path; do
    [ -d "$private_root/$directory" ] && [ ! -L "$private_root/$directory" ] || {
        echo "FAIL: missing private process directory: $directory" >&2
        exit 1
    }
done
[ -d "$module_view" ] && [ ! -L "$module_view" ] || {
    echo "FAIL: module view is not a real directory" >&2
    exit 1
}
[ -f "$channels" ] && [ ! -L "$channels" ] || {
    echo "FAIL: channels file is not regular" >&2
    exit 1
}
[ -f "$bootstrap_guix" ] && [ ! -L "$bootstrap_guix" ] || {
    echo "FAIL: bootstrap Guix command is not a regular store file" >&2
    exit 1
}

# env -i is deliberate: caller HOME/XDG caches, Guile compiled/load/extension
# paths, auto-compilation controls, Guix package/build paths, and PATH do not
# cross this boundary.  The absolute immutable bootstrap client may only enter
# the pinned channels.scm time machine; every requested operation runs there.
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
    GUILE_LOAD_COMPILED_PATH= \
    GUILE_EXTENSIONS_PATH= \
    "$bootstrap_guix" time-machine -C "$channels" -- "$@"
