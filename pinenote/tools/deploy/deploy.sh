#!/bin/sh
# wilkbook deploy: build -> guix copy -> add -> trial (kexec) -> health -> promote.
# doc/update-path.md.  Every step refuses rather than guesses; a failed
# health check leaves DEFAULT on the previous generation and exits 1.
#
#   usage: deploy.sh DEVICE [FLAVOR] [KEEP]        (FLAVOR default reader-direct, KEEP 3)
#          deploy.sh DEVICE --rollback N           trial+health+promote an existing generation
#
# DEVICE is an ssh destination for root (an alias in ~/.ssh/config that
# carries the per-slot UserKnownHostsFile is the documented way --
# doc/device-access.md).  guix copy uses the same ssh configuration.
set -eu
device=${1:?usage: deploy.sh DEVICE [FLAVOR] [KEEP] | DEVICE --rollback N}
repo=$(cd "$(dirname "$0")/../../.." && pwd)
ssh_cmd() { ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$device" "$@"; }

wait_for_ssh() {
  i=0
  while [ "$i" -lt 60 ]; do
    if ssh_cmd true 2>/dev/null; then return 0; fi
    sleep 5; i=$((i + 1))
  done
  return 1
}

trial_health_promote() {
  gen=$1; expect=$2; keep=$3
  echo "== trial: kexec into generation $gen (DEFAULT unchanged; the ssh link dies with the old kernel)"
  timeout 90 ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$device" "wilkbook-generation trial $gen" || true
  echo "== waiting for the new generation to answer ssh"
  sleep 15
  wait_for_ssh || { echo "NOT PROMOTED: generation $gen never answered; a power-cycle boots the previous DEFAULT" >&2; exit 1; }
  echo "== health"
  if ! ssh_cmd "wilkbook-generation health --expect $expect"; then
    echo "NOT PROMOTED: health check failed on generation $gen; DEFAULT still names the previous one" >&2
    exit 1
  fi
  echo "== promote"
  ssh_cmd "wilkbook-generation promote $gen"
  [ -z "$keep" ] || ssh_cmd "wilkbook-generation prune --keep $keep"
  echo "DEPLOY OK -- generation $gen is DEFAULT ($expect)"
}

if [ "${2:-}" = "--rollback" ]; then
  gen=${3:?--rollback needs a generation number}
  expect=$(ssh_cmd "cat /boot/gen-$gen/system") || { echo "no generation $gen on $device" >&2; exit 1; }
  trial_health_promote "$gen" "$expect" ""
  exit 0
fi

flavor=${2:-reader-direct}
keep=${3:-3}
echo "== 1/7 build: pinenote-$flavor (cross, aarch64-linux-gnu)"
system=$(cd "$repo" && guix system build --no-grafts -L . --target=aarch64-linux-gnu \
           "pinenote/systems/pinenote-$flavor.scm" | tail -n 1)
case "$system" in /gnu/store/*-system) ;; *) echo "build did not yield a system: $system" >&2; exit 1;; esac
echo "   $system"
echo "== 2/7 guix copy --to=root@$device"
guix copy --to="root@$device" "$system"
echo "== 3/7 add"
gen=$(ssh_cmd "wilkbook-generation add $system" | tail -n 1 | sed -n 's/^generation //p')
[ -n "$gen" ] || { echo "add did not report a generation number" >&2; exit 1; }
echo "   generation $gen"
trial_health_promote "$gen" "$system" "$keep"
