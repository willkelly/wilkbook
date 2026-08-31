#!/bin/sh
set -eu
script=${1:-../../packages/platform-controls/pinenote-wifi-control}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/proc/4242" "$tmp/sys/class/net/wlan0" "$tmp/run"
printf 'network={}\n' > "$tmp/wlan0.conf"
printf 'wpa_supplicant -B -i wlan0 -c %s' "$tmp/wlan0.conf" > "$tmp/proc/4242/cmdline"
for command in rfkill dhcpcd; do
    printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$command"; chmod +x "$tmp/bin/$command"
done
run() { env PATH="$tmp/bin:$PATH" PINENOTE_WIFI_RUN_DIR="$tmp/run" PINENOTE_WIFI_PROC_ROOT="$tmp/proc" PINENOTE_WIFI_SYS_ROOT="$tmp/sys" PINENOTE_WIFI_CONF="$tmp/wlan0.conf" PINENOTE_WIFI_NO_KILL=1 "$script" "$@"; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
run status >/dev/null && pass "stock supplicant is adopted" || fail adoption
[ "$(cat "$tmp/run/wpa_supplicant-wlan0.pid")" = 4242 ] || fail "adopted pid file"
run status >/dev/null && pass "validated supplicant reports on" || fail status
run on >/dev/null && pass "on is idempotent" || fail on
run off >/dev/null && pass "off stops only validated ownership" || fail off
printf 'unrelated -iwlan0' > "$tmp/proc/4242/cmdline"
run status >/dev/null 2>&1 && fail "off status" || pass "off reports off"
printf '9999\n' > "$tmp/run/wpa_supplicant-wlan0.pid"
run off >/dev/null 2>&1 && pass "stale pid is removed without signaling" || fail stale
[ ! -e "$tmp/run/wpa_supplicant-wlan0.pid" ] || fail "stale pid remains"
printf '4242\n' > "$tmp/run/wpa_supplicant-wlan0.pid"
run off >/dev/null 2>&1 && pass "foreign pid is refused" || fail foreign

rm -f "$tmp/run/wpa_supplicant-wlan0.pid"
printf 'wpa_supplicant -B -i wlan0 -c %s' "$tmp/wlan0.conf" > "$tmp/proc/4242/cmdline"
mkdir -p "$tmp/proc/4343"
printf 'wpa_supplicant -B -i wlan0 -c %s' "$tmp/wlan0.conf" > "$tmp/proc/4343/cmdline"
run status >/dev/null 2>&1 && fail "ambiguous adoption" || pass "duplicate supplicants are refused"
[ ! -e "$tmp/run/wpa_supplicant-wlan0.pid" ] || fail "ambiguous pid file created"
