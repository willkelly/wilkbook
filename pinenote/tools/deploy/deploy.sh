#!/bin/sh
# wilkbook deploy: build -> guix copy -> add -> trial (kexec) -> health -> promote.
# doc/update-path.md.  Every step refuses rather than guesses; a failed
# health check leaves DEFAULT on the previous generation and exits 1.
#
#   usage: deploy.sh DEVICE [FLAVOR] [KEEP]        (FLAVOR default reader, KEEP 5)
#          deploy.sh DEVICE --rollback N           trial+health+promote an existing generation
#
# WILKBOOK_UART=/dev/ttyUSB0 (optional): with the debug cable attached, a
# trial that never boots is recovered hands-free -- the watchdog resets the
# device, the U-Boot menu is driven back to os2, the previous DEFAULT boots.
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

# The UART watcher (armed in trial_health_promote) is reaped as a process
# group on EVERY exit from the trial -- success, refusal, recovery -- and
# never through a bare kill: under set -e a kill of an already-exited
# watcher (the very case the watcher exists for -- it picked os2 and left)
# aborted the deployer between a passed ssh wait and health/promote,
# silently (review 2026-09-04).
reap_watcher() { [ -z "${watcher:-}" ] || kill -- -"$watcher" 2>/dev/null || true; }

wait_for_ssh() {
  i=0
  while [ "$i" -lt 60 ]; do
    if ssh_cmd true 2>/dev/null; then return 0; fi
    sleep 5; i=$((i + 1))
  done
  return 1
}

# A trial that never answers: the helper armed the SoC watchdog before
# kexec -e, so a kernel that never reached its drivers resets the device
# into U-Boot on its own (~45-90 s); U-Boot's default lands on os1.  With
# a UART configured (WILKBOOK_UART=/dev/ttyUSB0) the menu is driven back
# to os2 here, and extlinux boots the previous DEFAULT -- no hands.
# Without one, this reports what to do.  Either way: exit 1, nothing
# promoted.
recover_after_failed_trial() {
  gen=$1; watcher=${2:-}
  if [ -n "$watcher" ]; then
    echo "NOT PROMOTED: generation $gen never answered; the watcher armed before the kexec waits for the watchdog reset and picks os2 at the U-Boot menu ($WILKBOOK_UART)" >&2
    log=${TMPDIR:-/tmp}/wilkbook-uart-recover-$$.log
    if wait "$watcher" && wait_for_ssh; then
      echo "back on $(ssh_cmd 'readlink /run/current-system') (the previous DEFAULT); UART capture in $log" >&2
    else
      echo "the device did not come back on its own: power-cycle it; the U-Boot default is os1 and extlinux's DEFAULT is still the previous generation" >&2
    fi
    # the picker's UART reader outlives it by design; reap it once the boot is captured
    reap_watcher
  else
    echo "NOT PROMOTED: generation $gen never answered; the watchdog resets it into U-Boot (default os1) -- pick os2 at the menu, or set WILKBOOK_UART=/dev/ttyUSB0 to have this done for you" >&2
  fi
  exit 1
}

trial_health_promote() {
  gen=$1; expect=$2; keep=$3
  # The UART watcher must be listening BEFORE kexec -e: a trial that dies is
  # reset by the watchdog within minutes, U-Boot's menu shows for 15 s, and
  # its default is os1.  Started after the ssh wait (as until 2026-09-04)
  # the watcher always arrived after the menu was gone.
  watcher=""
  if [ -n "${WILKBOOK_UART:-}" ] && [ -e "$WILKBOOK_UART" ]; then
    uart_log=${TMPDIR:-/tmp}/wilkbook-uart-recover-$$.log
    # Its own process group (setsid execs in place from a non-interactive
    # shell, so $! IS the group leader): the picker leaves its `cat` of the
    # UART running by design, and killing only the sh orphaned one reader
    # per deploy -- two readers on one tty split the bytes and the menu
    # match can miss (review 2026-09-04).
    setsid sh "$repo/pinenote/scripts/uart/uboot-pick-slot.sh" "$uart_log" --slot os2 --tty "$WILKBOOK_UART" > "$uart_log.pick" 2>&1 &
    watcher=$!
    echo "== UART watcher armed on $WILKBOOK_UART (pid $watcher): a dead trial resets into U-Boot and is picked back to os2"
  fi
  echo "== trial: kexec into generation $gen (DEFAULT unchanged; the ssh link dies at the helper's Wi-Fi off, before the kexec)"
  # The trial runs the helper the TARGET generation ships, not the running
  # one: a fix to how a kexec is prepared must apply to the first kexec that
  # needs it (2026-09-02: the running helper could not skip the GRF init).
  # The helper's words are kept in a file so its exit status survives: 255
  # (ssh gave up on its keepalives) or 124 (the timeout) is the link dying
  # with the old kernel -- the SUCCESS signature; anything else is the helper
  # itself exiting, which it only does to refuse, after undoing its teardown
  # (radio back, reader back).  That is not a dead trial, no watchdog is
  # counting, and the five-minute wait would only obscure it (2026-09-04).
  trial_log=${TMPDIR:-/tmp}/wilkbook-trial-$$.log
  trial_rc=0
  timeout 90 ssh -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "root@$device" "\$(cat /boot/gen-$gen/system)/profile/bin/wilkbook-generation trial $gen" > "$trial_log" 2>&1 || trial_rc=$?
  sed 's/^/   trial> /' "$trial_log"
  case $trial_rc in
    0|255|124) ;;
    *)
      reap_watcher
      echo "NOT PROMOTED: the trial helper refused (exit $trial_rc); it undid its teardown (reader and radio back), DEFAULT is unchanged -- its reason is in the trial output above" >&2
      exit 1;;
  esac
  echo "== waiting for the new generation to answer ssh"
  sleep 15
  if wait_for_ssh; then
    reap_watcher
  else
    recover_after_failed_trial "$gen" "$watcher"
  fi
  # A refusal said after the link had already dropped (the keepalives give
  # the helper ~15 s past its radio-off; an EBC that never goes idle alone
  # takes 10 of them) looks like a success up to here: the helper leaves a
  # record for this boot, and the reconnected system is the OLD one.  Ask
  # the target generation's helper -- the one that ran the trial.
  if refusal=$(ssh_cmd "\$(cat /boot/gen-$gen/system)/profile/bin/wilkbook-generation last-trial" 2>/dev/null); then
    echo "NOT PROMOTED: the trial helper refused after the ssh link had dropped; it undid its teardown (reader and radio back), DEFAULT is unchanged" >&2
    printf '%s\n' "$refusal" | sed 's/^/   /' >&2
    exit 1
  fi
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

flavor=${2:-reader}
keep=${3:-5}
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
