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
# doc/device-access.md).  The transfer is the guix copy nar pipe (guix
# archive --export | ssh | guix archive --import) over plain OpenSSH, so
# ~/.ssh/config aliases and the per-slot UserKnownHostsFile apply; guix
# copy itself uses Guile-SSH/libssh, which ignores them.
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
  # The trial runs the helper the TARGET generation ships, not the running
  # one: a fix to how a kexec is prepared must apply to the first kexec that
  # needs it (2026-09-02: the running helper could not skip the GRF init).
  timeout 90 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "root@$device" "\$(cat /boot/gen-$gen/system)/profile/bin/wilkbook-generation trial $gen" || true
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
echo "== 2/7 transfer: only what root@$device is missing (the guix copy algorithm over OpenSSH)"
closure=$(guix gc --references -R "$system")
total=$(printf '%s\n' "$closure" | grep -c .)
missing=$(printf '%s\n' "$closure" | ssh_cmd "guix archive --missing")
count=$(printf '%s\n' "$missing" | grep -c . || true)
echo "   $count of $total store paths missing on the device"
if [ "$count" -gt 0 ]; then
  # export sorts its arguments topologically; the device's daemon verifies
  # the signature against /etc/guix/acl (pinenote-guix-acl seeds it).
  printf '%s\n' "$missing" | xargs guix archive --export | ssh_cmd "guix archive --import"
fi
ssh_cmd "test -f $system/parameters" || { echo "the system is not in the device store after import" >&2; exit 1; }
echo "== 3/7 add"
gen=$(ssh_cmd "wilkbook-generation add $system" | tail -n 1 | sed -n 's/^generation //p')
[ -n "$gen" ] || { echo "add did not report a generation number" >&2; exit 1; }
echo "   generation $gen"
trial_health_promote "$gen" "$system" "$keep"
