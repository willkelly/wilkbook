#!/bin/sh
# Exact Linux process identity helpers: PID plus /proc start time. This file is
# sourced by the timeout owner and its regression test; it performs no action
# by itself.

owned_process_details() {
    [ "$#" -eq 1 ] || return 1
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -r "/proc/$1/stat" ] || return 1
    owned_stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    owned_rest=${owned_stat##*) }
    [ "$owned_rest" != "$owned_stat" ] || return 1
    set -- $owned_rest
    [ "$#" -ge 20 ] || return 1
    owned_state=$1
    shift 19
    owned_start=$1
}

owned_process_start_time() {
    owned_process_details "$1" || return 1
    printf '%s\n' "$owned_start"
}

owned_process_alive() {
    [ "$#" -eq 2 ] || return 1
    owned_process_details "$1" || return 1
    [ "$owned_start" = "$2" ] && [ "$owned_state" != Z ]
}

owned_process_matches() {
    [ "$#" -eq 2 ] || return 1
    owned_process_details "$1" || return 1
    [ "$owned_start" = "$2" ]
}

owned_process_record_alive() {
    [ "$#" -eq 1 ] && [ -r "$1" ] || return 1
    read -r owned_pid owned_recorded_start <"$1" || return 1
    owned_process_alive "$owned_pid" "$owned_recorded_start"
}

owned_process_record_matches() {
    [ "$#" -eq 1 ] && [ -r "$1" ] || return 1
    read -r owned_pid owned_recorded_start <"$1" || return 1
    owned_process_matches "$owned_pid" "$owned_recorded_start"
}

owned_process_terminate() {
    [ "$#" -eq 2 ] || return 1
    owned_pid=$1
    owned_recorded_start=$2
    if ! owned_process_alive "$owned_pid" "$owned_recorded_start"; then
        return 0
    fi

    kill -TERM "$owned_pid" 2>/dev/null || true
    owned_i=0
    while [ "$owned_i" -lt 20 ]; do
        if ! owned_process_alive "$owned_pid" "$owned_recorded_start"; then
            return 0
        fi
        sleep 0.1
        owned_i=$((owned_i + 1))
    done

    if owned_process_alive "$owned_pid" "$owned_recorded_start"; then
        kill -KILL "$owned_pid" 2>/dev/null || true
    fi
    owned_i=0
    while [ "$owned_i" -lt 20 ]; do
        if ! owned_process_alive "$owned_pid" "$owned_recorded_start"; then
            return 0
        fi
        sleep 0.1
        owned_i=$((owned_i + 1))
    done
    ! owned_process_alive "$owned_pid" "$owned_recorded_start"
}

owned_process_terminate_record() {
    [ "$#" -eq 1 ] && [ -r "$1" ] || return 0
    read -r owned_pid owned_recorded_start <"$1" || return 1
    owned_process_terminate "$owned_pid" "$owned_recorded_start"
}
