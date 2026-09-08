#!/bin/sh
# Prepare and run the finite Book State guest gate from a fresh candidate tree.
set -eu
umask 077

[ "$#" -eq 0 ] || {
    echo "run-tests.sh accepts no arguments" >&2
    exit 2
}
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(CDPATH= cd -- "$tool/../../.." && pwd -P)
roster=$tool/CAPSULE-ROSTER.tsv
preparer=$tool/prepare-source-capsule.py
[ -f "$roster" ] && [ ! -L "$roster" ] || exit 1
[ -f "$preparer" ] && [ ! -L "$preparer" ] || exit 1

# Authenticate the only candidate-tree program that executes before the private
# capsule exists.  The versioned roster itself is frozen by the review packet.
tab=$(printf '\t')
expected=
rows=0
while IFS="$tab" read -r relative digest mode role; do
    if [ "$relative" = "pinenote/tools/book-state-guest/prepare-source-capsule.py" ]; then
        expected=$digest
        rows=$((rows + 1))
    fi
done <"$roster"
[ "$rows" -eq 1 ] && [ -n "$expected" ] || {
    echo "FAIL: capsule roster does not select exactly one preparer" >&2
    exit 1
}
record=$(/usr/bin/sha256sum -- "$preparer")
actual=${record%% *}
[ "$actual" = "$expected" ] || {
    echo "FAIL: source preparer does not match capsule roster" >&2
    exit 1
}

python_link=$(command -v python3) || { echo "FAIL: python3 not found" >&2; exit 1; }
guix_link=$(command -v guix) || { echo "FAIL: guix not found" >&2; exit 1; }
python=$(/usr/bin/readlink -f -- "$python_link")
bootstrap_guix=$(/usr/bin/readlink -f -- "$guix_link")
case $python in /gnu/store/*-python-*/bin/python*) ;; *) exit 1 ;; esac
case $bootstrap_guix in /gnu/store/*-guix-command) ;; *) exit 1 ;; esac

run_root=$(mktemp -d /tmp/opencode/book-state-guest-source.XXXXXX)
chmod 700 "$run_root"
cleanup () {
    chmod -R u+w "$run_root" 2>/dev/null || true
    rm -rf -- "$run_root"
}
trap cleanup EXIT HUP INT TERM
for name in home cache config data state tmp; do mkdir -m 700 "$run_root/$name"; done
capsule=$run_root/capsule

/usr/bin/env -i \
    HOME="$run_root/home" XDG_CACHE_HOME="$run_root/cache" \
    XDG_CONFIG_HOME="$run_root/config" XDG_DATA_HOME="$run_root/data" \
    XDG_STATE_HOME="$run_root/state" TMPDIR="$run_root/tmp" \
    PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    GUILE_AUTO_COMPILE=0 GUILE_LOAD_PATH= GUILE_LOAD_COMPILED_PATH= \
    GUILE_EXTENSIONS_PATH= \
    "$python" -I -S -B "$preparer" --source-root "$repo" --output "$capsule"

sh "$capsule/repo/pinenote/tools/book-state-guest/run-prepared.sh" \
    "$capsule" "$bootstrap_guix"
