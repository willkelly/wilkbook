#!/bin/sh
# Offline check for rescue-generation.sh (make os1-rescue-check).
#
# Every privileged step of the script goes through `sudo -n`, so a stub sudo
# on PATH stands in for os1: it records each call, answers the mounts and the
# in-chroot helper check, and plays the generation helper against a small
# ledger kept in a state directory.  findmnt and sync are stubbed too.  Pins
# the two things its first os1 run (2026-09-26) got wrong -- the helper looked
# for inside the chroot, and a profile PATH for it -- and what the reviews of
# that run asked for: the refusals, arguments checked before any mount, plain
# ro (never noload) for list and log, rw for writes, no /sys bind, an empty
# ledger failing loudly, the extlinux DEFAULT beside the ledger, the
# not-pinned note, cleanup on HUP/INT/TERM, and `sh -s` from stdin.  Runs
# under sh, and under dash and bash when they are on PATH.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script=$here/rescue-generation.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bin=$tmp/bin
mkdir -p "$bin"
helper=/var/guix/profiles/system/profile/bin/wilkbook-generation
prof=/var/guix/profiles/system/profile

cat > "$bin/findmnt" <<'EOF'
#!/bin/sh
case "$*" in
  "-n -o SOURCE /") echo "${T_ROOT:-/dev/mmcblk0p5}" ;;
  *"-S /dev/mmcblk0p6"*)
    [ "${T_P6_MOUNTED:-0}" = 1 ] || exit 1
    case "$*" in *TARGET*) echo /mnt/os2 ;; esac ;;
  *) echo "findmnt stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
cat > "$bin/sync" <<'EOF'
#!/bin/sh
echo "sync" >> "$T_STATE/calls"
EOF
# The stub sudo.  State: $T_STATE/default (the promoted number) and calls.
cat > "$bin/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] || { echo "sudo stub: not -n: $*" >&2; exit 98; }
shift
echo "$*" >> "$T_STATE/calls"
gens="10 16 18 19 20 21 22 23"; pinned=" 10 16 18 "
ledger() {
  d=$(cat "$T_STATE/default")
  for g in $gens; do
    line="gen-$g  /gnu/store/fake-$g-system"
    [ "$g" = "$d" ] && line="$line  [promoted]"
    case $pinned in *" $g "*) line="$line  [pinned]" ;; esac
    echo "$line"
  done
}
case "$1" in
  mkdir|umount) exit 0 ;;
  mount)
    case "$*" in *--bind*) exit 0 ;; esac
    [ "${T_MOUNT_FAIL:-0}" = 1 ] && { echo "mount: failed" >&2; exit 32; }
    exit 0 ;;
  tail) echo "log line 1"; echo "log line 2"; exit 0 ;;
  sed)  # the DEFAULT extlinux boots; T_EXTLINUX makes it disagree
    if [ -n "${T_EXTLINUX:-}" ]; then echo "$T_EXTLINUX"; else echo "gen-$(cat "$T_STATE/default")"; fi
    exit 0 ;;
  /usr/sbin/chroot)  # the in-chroot helper check
    [ "${T_HELPER:-1}" = 1 ]; exit $? ;;
  /usr/bin/env)
    shift; path=$1; shift
    [ "$1 $2 $3" = "/usr/sbin/chroot /mnt/os2 $T_HELPER_PATH" ] || { echo "sudo stub: bad helper call $*" >&2; exit 97; }
    [ "$path" = "PATH=$T_PROF/bin:$T_PROF/sbin" ] || { echo "sudo stub: bad PATH $path" >&2; exit 96; }
    shift 3
    [ "${T_READ_STDIN:-0}" = 1 ] && cat > /dev/null
    case "$1" in
      list)
        [ "${T_EMPTY:-0}" = 1 ] && exit 0
        if [ "${T_HANG:-0}" = 1 ]; then sleep 30 & echo $! > "$T_STATE/sleeppid"; wait $!; fi
        ledger ;;
      promote) echo "$2" > "$T_STATE/default"; echo "promoted generation $2" ;;
      demote)
        d=$(cat "$T_STATE/default"); prev=
        for g in $gens; do [ "$g" -lt "$d" ] && prev=$g; done
        echo "$prev" > "$T_STATE/default"; echo "promoted generation $prev" ;;
      *) echo "sudo stub: helper $1?" >&2; exit 95 ;;
    esac
    exit 0 ;;
  *) echo "sudo stub: unexpected $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$bin/findmnt" "$bin/sync" "$bin/sudo"

fails=0; cases=0
fail() { echo "FAIL [$sh] $name: $*"; fails=$((fails + 1)); }
# run NAME SHELL ARGS... -- fresh state, default 23; env T_* from the caller.
run() {
  name=$1; shift
  st=$tmp/state-$cases; rm -rf "$st"; mkdir -p "$st"
  echo 23 > "$st/default"; : > "$st/calls"
  cases=$((cases + 1))
  set +e
  out=$(env PATH="$bin:$PATH" T_STATE="$st" T_HELPER_PATH="$helper" T_PROF="$prof" "$sh" "$script" "$@" 2>&1)
  rc=$?
  set -e
  calls=$(cat "$st/calls")
}
has() { printf '%s\n' "$out" | grep -q -- "$1" || fail "output lacks '$1'"; }
called() { printf '%s\n' "$calls" | grep -q -- "$1" || fail "no call matching '$1'"; }
notcalled() { ! printf '%s\n' "$calls" | grep -q -- "$1" || fail "unexpected call matching '$1'"; }
rc_is() { [ "$rc" = "$1" ] || fail "exit $rc, want $1"; }
unmounted() {  # the binds, then p6, after the mount
  last=$(printf '%s\n' "$calls" | grep -n '^umount /mnt/os2$' | tail -1 | cut -d: -f1)
  [ -n "$last" ] || { fail "p6 never unmounted"; return; }
  m=$(printf '%s\n' "$calls" | grep -n '^mount -o' | head -1 | cut -d: -f1)
  [ "$last" -gt "$m" ] || fail "p6 unmounted before it was mounted"
}

shells=sh
for s in dash bash; do command -v "$s" >/dev/null 2>&1 && shells="$shells $s"; done
for sh in $shells; do
  # No arguments means list (dash's bare shift used to exit here).
  run no-args; rc_is 0; has "gen-23 .*\[promoted\]"; has "extlinux DEFAULT: gen-23"
  # Refusals and usage: nothing privileged runs.
  T_ROOT=/dev/mmcblk0p6 run not-os1 list; rc_is 1; has "REFUSE: / is not"; [ -z "$calls" ] || fail "calls made: $calls"
  T_P6_MOUNTED=1 run p6-mounted list; rc_is 1; has "already mounted"; has "umount -R"; [ -z "$calls" ] || fail "calls made: $calls"
  for bad in "frob" "promote" "promote abc" "promote 2x" "log x" "add /gnu/store/x" "trial 23" "prune --keep 1" "pin 23"; do
    # shellcheck disable=SC2086
    run "usage:$bad" $bad; rc_is 2; has "usage:"; [ -z "$calls" ] || fail "calls made: $calls"
  done
  # list: plain ro, proc and dev bound but not sys, the helper by profile PATH.
  run list list; rc_is 0; has "extlinux DEFAULT: gen-23"
  called '^mount -o ro /dev/mmcblk0p6 /mnt/os2$'; notcalled 'noload'; notcalled 'rw'
  called '^mount --bind /proc /mnt/os2/proc$'; called '^mount --bind /dev /mnt/os2/dev$'; notcalled 'bind /sys'
  called "^/usr/sbin/chroot /mnt/os2 /bin/sh -c test -x \"\$1\" sh $helper\$"
  called "^/usr/bin/env PATH=$prof/bin:$prof/sbin /usr/sbin/chroot /mnt/os2 $helper list\$"
  unmounted
  # An empty ledger is a broken chroot, not an empty ledger.
  T_EMPTY=1 run empty-ledger list; rc_is 1; has "listed no generations"; unmounted
  # The ledger and extlinux disagree (a write cut short).
  T_EXTLINUX=gen-22 run mismatch list; rc_is 1; has "MISMATCH"; unmounted
  # The helper is missing from the promoted system.
  T_HELPER=0 run no-helper list; rc_is 1; has "REFUSE: no generation helper"; notcalled '/usr/bin/env'; unmounted
  # promote: rw, the write, the ledger again, the not-pinned note.
  run promote-22 promote 22; rc_is 0; called '^mount -o rw /dev/mmcblk0p6 /mnt/os2$'
  called "$helper promote 22\$"; has "gen-22 .*\[promoted\]"; has "extlinux DEFAULT: gen-22"
  has "NOTE: the new DEFAULT is not \[pinned\]"; has "DEFAULT changed on os2"; unmounted
  run promote-16 promote 16; rc_is 0; has "extlinux DEFAULT: gen-16"
  ! printf '%s\n' "$out" | grep -q "NOTE:" || fail "a pinned DEFAULT got the not-pinned note"
  run demote demote; rc_is 0; has "promoted generation 22"; has "extlinux DEFAULT: gen-22"; unmounted
  # A failed mount leaves nothing to unmount and runs nothing else.
  T_MOUNT_FAIL=1 run mount-fails promote 22; [ "$rc" != 0 ] || fail "exit 0"; notcalled '/usr/bin/env'; notcalled '^umount'
  # log: ro, tail, no chroot.
  run log log 5; rc_is 0; has "log line 2"; called '^tail -n 5 /mnt/os2/var/log/messages$'
  called '^mount -o ro '; notcalled 'chroot'; unmounted
  # A signal mid-run still unmounts p6 (dash runs no EXIT trap for an
  # untrapped signal).  A background job starts with INT ignored, and a
  # signal ignored on entry cannot be trapped, so the script is started
  # with default dispositions (env --default-signal, coreutils 8.31+).
  for sig in HUP:129 INT:130 TERM:143; do
    want=${sig#*:}; sig=${sig%:*}
    st=$tmp/state-$cases; rm -rf "$st"; mkdir -p "$st"; echo 23 > "$st/default"; : > "$st/calls"
    cases=$((cases + 1)); name=signal-$sig
    env --default-signal=HUP,INT,TERM PATH="$bin:$PATH" T_STATE="$st" T_HELPER_PATH="$helper" T_PROF="$prof" T_HANG=1 \
      "$sh" "$script" list > "$st/out" 2>&1 &
    pid=$!
    n=0; while [ ! -s "$st/sleeppid" ] && [ $n -lt 100 ]; do n=$((n + 1)); sleep 0.1; done
    [ -s "$st/sleeppid" ] || fail "helper never started"
    kill -"$sig" "$pid" 2>/dev/null || fail "the script had already exited"
    # The shell runs the trap once its foreground child returns; end the
    # stub helper's sleep (its own pid, nothing else) so it does.
    kill "$(cat "$st/sleeppid")" 2>/dev/null || true
    set +e; wait "$pid"; rc=$?; set -e
    calls=$(cat "$st/calls"); out=$(cat "$st/out")
    rc_is "$want"
    unmounted
  done
  # sh -s from stdin, with a helper that reads stdin: </dev/null keeps it
  # from eating the rest of the script.
  st=$tmp/state-$cases; rm -rf "$st"; mkdir -p "$st"; echo 23 > "$st/default"; : > "$st/calls"
  cases=$((cases + 1)); name=stdin
  set +e
  out=$(env PATH="$bin:$PATH" T_STATE="$st" T_HELPER_PATH="$helper" T_PROF="$prof" T_READ_STDIN=1 \
    "$sh" -s -- promote 22 < "$script" 2>&1); rc=$?
  set -e
  calls=$(cat "$st/calls"); rc_is 0; has "extlinux DEFAULT: gen-22"; has "DEFAULT changed on os2"; unmounted
done

if [ "$fails" -gt 0 ]; then echo "os1-rescue-check: $fails failure(s) in $cases cases ($shells)"; exit 1; fi
echo "os1-rescue-check: $cases cases pass ($shells)"
