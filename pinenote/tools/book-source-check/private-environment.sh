#!/bin/sh
# Shared trusted-host boundary for every public Guix/Guile runner.

book_source_resolve_guix_launcher () {
    # Resolve the host's selected Guix without executing it.  Never accept an
    # ambient override, and execute only the immutable store target afterward.
    unset BOOK_SOURCE_GUIX
    guix_link=$(command -v guix) || {
        echo "guix is not available on PATH" >&2
        return 1
    }
    case "$guix_link" in /*) ;; *)
        echo "guix command is not an absolute path: $guix_link" >&2
        return 1
        ;;
    esac
    guix_real=$(readlink -f "$guix_link")
    case "$guix_real" in /gnu/store/*) ;; *)
        echo "guix command does not resolve to an immutable store executable" >&2
        return 1
        ;;
    esac
    [ -f "$guix_real" ] && [ -x "$guix_real" ] && [ ! -L "$guix_real" ] || {
        echo "resolved guix launcher is unavailable: $guix_real" >&2
        return 1
    }
    export BOOK_SOURCE_GUIX="$guix_real"
    echo "BOOK_SOURCE_GUIX=$BOOK_SOURCE_GUIX"
}

book_source_require_guix_launcher () {
    case "${BOOK_SOURCE_GUIX-}" in /gnu/store/*) ;; *)
        echo "resolved immutable Guix launcher is absent" >&2
        return 1
        ;;
    esac
    [ -f "$BOOK_SOURCE_GUIX" ] && [ -x "$BOOK_SOURCE_GUIX" ] \
        && [ ! -L "$BOOK_SOURCE_GUIX" ] || {
        echo "resolved immutable Guix launcher is unavailable" >&2
        return 1
    }
    [ "$(readlink -f "$BOOK_SOURCE_GUIX")" = "$BOOK_SOURCE_GUIX" ] || {
        echo "resolved immutable Guix launcher is not canonical" >&2
        return 1
    }
}

book_source_clear_ambient_code_paths () {
    unset GUILE GUILE_FLAGS GUILE_SYSTEM_PATH GUILE_SYSTEM_COMPILED_PATH \
        GUILE_SYSTEM_EXTENSIONS_PATH GUILE_WARN_DEPRECATED \
        GUIX_PACKAGE_PATH GUIX_BUILD_OPTIONS GUIX_ENVIRONMENT \
        GUIX_EXTENSIONS_PATH GUIX_PROFILE GUIX_LOCPATH \
        PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
}

book_source_require_private_directory () {
    directory=$1
    label=$2
    case "$directory" in /*) ;; *) echo "$label is not absolute" >&2; return 1 ;; esac
    [ -d "$directory" ] && [ ! -L "$directory" ] || {
        echo "$label is absent or not a directory: $directory" >&2
        return 1
    }
    [ "$(CDPATH= cd -- "$directory" && pwd -P)" = "$directory" ] || {
        echo "$label is not canonical: $directory" >&2
        return 1
    }
    [ "$(stat -c %a "$directory")" = 700 ] || {
        echo "$label is not mode 0700: $directory" >&2
        return 1
    }
}

book_source_require_store_path_list () {
    value=$1
    label=$2
    allow_empty=$3
    if [ -z "$value" ]; then
        [ "$allow_empty" = yes ] || {
            echo "$label is empty" >&2
            return 1
        }
        return 0
    fi
    old_ifs=$IFS
    IFS=:
    set -- $value
    IFS=$old_ifs
    for directory do
        case "$directory" in /gnu/store/*) ;; *)
            echo "$label contains a non-store path: $directory" >&2
            return 1
            ;;
        esac
        [ -d "$directory" ] && [ ! -L "$directory" ] || {
            echo "$label path is unavailable: $directory" >&2
            return 1
        }
    done
}

book_source_enter_base_environment () {
    root=$1
    book_source_require_private_directory "$root" "private environment root"
    book_source_clear_ambient_code_paths
    export HOME="$root/home"
    export XDG_CACHE_HOME="$root/xdg-cache"
    export XDG_CONFIG_HOME="$root/xdg-config"
    export XDG_DATA_HOME="$root/xdg-data"
    export XDG_STATE_HOME="$root/xdg-state"
    export GUILE_AUTO_COMPILE=0
}

book_source_enter_bootstrap_environment () {
    root=$1
    book_source_enter_base_environment "$root"
    export GUILE_LOAD_PATH="$root/empty-load"
    export GUILE_LOAD_COMPILED_PATH="$root/empty-compiled"
    export GUILE_EXTENSIONS_PATH="$root/empty-extensions"
}

book_source_create_private_environment () {
    root=$1
    case "$root" in /*) ;; *) echo "private environment root is not absolute" >&2; return 1 ;; esac
    [ ! -e "$root" ] || {
        echo "private environment root already exists: $root" >&2
        return 1
    }
    old_umask=$(umask)
    umask 077
    mkdir -m 700 "$root"
    for name in home xdg-cache xdg-config xdg-data xdg-state \
            empty-load empty-compiled empty-extensions; do
        mkdir -m 700 "$root/$name"
    done
    umask "$old_umask"
    book_source_enter_bootstrap_environment "$root"
}

book_source_enter_guix_shell_environment () {
    root=$1
    project_ccache=$2
    stage=$3
    log=$4
    package_load=${GUILE_LOAD_PATH-}
    package_compiled=${GUILE_LOAD_COMPILED_PATH-}
    package_extensions=${GUILE_EXTENSIONS_PATH-}

    book_source_require_guix_launcher

    book_source_require_store_path_list "$package_load" \
        "Guix-shell GUILE_LOAD_PATH" no
    book_source_require_store_path_list "$package_compiled" \
        "Guix-shell GUILE_LOAD_COMPILED_PATH" no
    book_source_require_store_path_list "$package_extensions" \
        "Guix-shell GUILE_EXTENSIONS_PATH" yes
    book_source_require_private_directory "$project_ccache" \
        "private project ccache"

    book_source_enter_base_environment "$root"
    export GUILE_LOAD_PATH="$package_load"
    export GUILE_LOAD_COMPILED_PATH="$project_ccache:$package_compiled"
    if [ -n "$package_extensions" ]; then
        export GUILE_EXTENSIONS_PATH="$package_extensions"
    else
        export GUILE_EXTENSIONS_PATH="$root/empty-extensions"
    fi

    guild_command=$(command -v guild)
    guile_command=$(command -v guile)
    guild_real=$(readlink -f "$guild_command")
    guile_real=$(readlink -f "$guile_command")
    case "$guild_command:$guild_real:$guile_real" in
        /gnu/store/*:/gnu/store/*:/gnu/store/*) ;;
        *) echo "Guix shell selected a non-store Guile tool" >&2; return 1 ;;
    esac
    early_home=$("$guile_command" --no-auto-compile -c \
        '(display (or (getenv "HOME") ""))')
    early_cache=$("$guile_command" --no-auto-compile -c \
        '(display (or (getenv "XDG_CACHE_HOME") ""))')
    [ "$early_home" = "$HOME" ] && [ "$early_cache" = "$XDG_CACHE_HOME" ]
    "$guild_command" --version >"$root/early-guild-version.txt"
    grep -F "guild (GNU Guile) 3.0.9" "$root/early-guild-version.txt" >/dev/null
    if find "$root" -type f -path '*/bin/guild.go' -print -quit | grep -q .; then
        echo "early Guile tooling unexpectedly populated guild.go" >&2
        return 1
    fi
    {
        printf 'PRIVATE-GUILE-STAGE=%s\n' "$stage"
        printf 'PRIVATE-GUILE-HOME=%s\n' "$early_home"
        printf 'PRIVATE-GUILE-XDG-CACHE=%s\n' "$early_cache"
        printf 'PRIVATE-GUILD-COMMAND=%s\n' "$guild_command"
        printf 'PRIVATE-GUILD-REAL=%s\n' "$guild_real"
        printf 'PRIVATE-GUILE-REAL=%s\n' "$guile_real"
        printf 'PRIVATE-GUILE-LOAD-PATH=%s\n' "$GUILE_LOAD_PATH"
        printf 'PRIVATE-GUILE-COMPILED-PATH=%s\n' \
            "$GUILE_LOAD_COMPILED_PATH"
        printf 'PRIVATE-GUILE-EXTENSIONS-PATH=%s\n' \
            "$GUILE_EXTENSIONS_PATH"
    } >"$log"
    cat "$log"
}
