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

# --- after-resume recovery (2026-09-03): a resume whose brcmfmac attach timed
# out leaves the SDIO functions unbound and wlan0 absent; `on` must rebind
# function 2 and wait again.  A supplicant that comes up unassociated is
# restarted once.  Waits are in tenths of a second, set to nothing here.
t2=$(mktemp -d)
trap 'rm -rf "$tmp" "$t2"' EXIT HUP INT TERM
mkdir -p "$t2/bin" "$t2/proc" "$t2/sys/class/net" "$t2/run" "$t2/sys/bus/sdio/drivers/brcmfmac" "$t2/sys/bus/sdio/devices/mmc1:0001:1" "$t2/sys/bus/sdio/devices/mmc1:0001:2"
printf 'network={}\n' > "$t2/wlan0.conf"
printf '0\n' > "$t2/counter"
for command in rfkill dhcpcd; do printf '#!/bin/sh\nexit 0\n' > "$t2/bin/$command"; chmod +x "$t2/bin/$command"; done
# the mock supplicant: a fresh pid per start, its /proc entry matching the ownership contract
cat > "$t2/bin/wpa_supplicant" <<MOCK
#!/bin/sh
pidfile=; while [ \$# -gt 0 ]; do case \$1 in -P) pidfile=\$2; shift;; esac; shift; done
n=\$(( \$(cat "$t2/counter") + 1 )); printf '%s\n' "\$n" > "$t2/counter"
mkdir -p "$t2/proc/\$n"; printf 'wpa_supplicant -B -i wlan0 -c %s' "$t2/wlan0.conf" > "$t2/proc/\$n/cmdline"
printf '%s\n' "\$n" > "\$pidfile"
MOCK
chmod +x "$t2/bin/wpa_supplicant"
printf '#!/bin/sh\nrm -rf "%s/proc/$1"\n' "$t2" > "$t2/bin/kill"; chmod +x "$t2/bin/kill"
: > "$t2/sys/bus/sdio/drivers/brcmfmac/bind"; : > "$t2/sys/bus/sdio/drivers/brcmfmac/unbind"
run2() { env PATH="$t2/bin:$PATH" PINENOTE_WIFI_RUN_DIR="$t2/run" PINENOTE_WIFI_PROC_ROOT="$t2/proc" PINENOTE_WIFI_SYS_ROOT="$t2/sys" PINENOTE_WIFI_CONF="$t2/wlan0.conf" PINENOTE_WIFI_WPA_SUPPLICANT="$t2/bin/wpa_supplicant" PINENOTE_WIFI_KILL="$t2/bin/kill" PINENOTE_WIFI_RFKILL="$t2/bin/rfkill" PINENOTE_WIFI_DHCPCD="$t2/bin/dhcpcd" PINENOTE_WIFI_IFACE_WAIT=0 PINENOTE_WIFI_REBIND_WAIT=0 PINENOTE_WIFI_ASSOC_WAIT="${ASSOC_WAIT:-0}" sh "$script" "$@"; }

# 1. wlan0 absent, function 2 bound to a driver that gave up: unbind + bind, then honest failure
ln -s ../../drivers/brcmfmac "$t2/sys/bus/sdio/devices/mmc1:0001:2/driver"
err=$(run2 on 2>&1 >/dev/null) && fail "on succeeded without wlan0" || pass "on fails when wlan0 never appears"
[ "$(cat "$t2/sys/bus/sdio/drivers/brcmfmac/unbind")" = "mmc1:0001:2" ] || fail "function 2 not unbound first"
[ "$(cat "$t2/sys/bus/sdio/drivers/brcmfmac/bind")" = "mmc1:0001:2" ] || fail "function 2 not rebound"
case "$err" in *"rebinding the driver"*"rebound brcmfmac on mmc1:0001:2"*"unavailable after rebind"*) pass "rebind is attempted and reported";; *) fail "rebind messages: $err";; esac
[ ! -e "$t2/run/wpa_supplicant-wlan0.pid" ] || fail "supplicant started without an interface"

# 2. wlan0 present and associated: no rebind, supplicant started once
: > "$t2/sys/bus/sdio/drivers/brcmfmac/bind"; : > "$t2/sys/bus/sdio/drivers/brcmfmac/unbind"
mkdir -p "$t2/sys/class/net/wlan0"; printf '1\n' > "$t2/sys/class/net/wlan0/carrier"
ASSOC_WAIT=2 run2 on >/dev/null 2>&1 && pass "on starts the supplicant when wlan0 is present" || fail "on with wlan0"
[ -z "$(cat "$t2/sys/bus/sdio/drivers/brcmfmac/bind")" ] || fail "rebind attempted with wlan0 present"
[ "$(cat "$t2/run/wpa_supplicant-wlan0.pid")" = 1 ] || fail "first supplicant pid"
run2 off >/dev/null 2>&1 || fail "off after on"

# 3. wlan0 present but never associated: the supplicant is restarted exactly once, and on still succeeds
printf '0\n' > "$t2/sys/class/net/wlan0/carrier"
err=$(ASSOC_WAIT=2 run2 on 2>&1 >/dev/null) && pass "on succeeds without an AP in range" || fail "on without association: $err"
case "$err" in *"restarting the supplicant once"*"still no association"*) pass "one association retry, reported";; *) fail "association retry messages: $err";; esac
[ "$(cat "$t2/run/wpa_supplicant-wlan0.pid")" = 3 ] || fail "supplicant restarted once (pid $(cat "$t2/run/wpa_supplicant-wlan0.pid"))"
[ ! -e "$t2/proc/2" ] || fail "first supplicant of the retry not stopped"
run2 status >/dev/null && pass "status reports on after the retry" || fail "status after retry"
