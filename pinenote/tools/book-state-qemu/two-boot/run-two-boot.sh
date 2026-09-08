#!/gnu/store/bcxav86yvf57pxf4jazqm695r61dzaai-bash-static-5.2.37/bin/bash -p
# Minimal reviewed bootstrap.  This file and bootstrap.py are the explicit
# non-self-authenticating trust base; all campaign Scheme/Python bytes loaded
# after them are authenticated and retained in a private capsule first.
set -euo pipefail
umask 077

# This interpreter is statically linked and starts in privileged mode.  Before
# the first dynamically linked dependency can run, retain the one shell value
# needed after the boundary and remove every valid inherited environment name
# using Bash builtins only.  This includes the complete LD_* namespace as well
# as GLIBC_TUNABLES, GCONV_PATH, LOCPATH, and any future loader switch.
invocation_working_directory=$PWD
unset BASH_ENV ENV CDPATH GLOBIGNORE
while IFS= read -r -d '' inherited_entry; do
    inherited_name=${inherited_entry%%=*}
    if [[ $inherited_name =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        unset -v "$inherited_name" 2>/dev/null || true
    fi
done < /proc/self/environ
unset -v inherited_entry inherited_name 2>/dev/null || true
export LANG=C LC_ALL=C

BASH=/gnu/store/bcxav86yvf57pxf4jazqm695r61dzaai-bash-static-5.2.37/bin/bash
BASH_SHA256=7370f72d9fcab3d8885ad1b1f05642294616d8f08f8f3caf8029ca37ff9a3eea
COREUTILS=/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1
ENV=$COREUTILS/bin/env
MKTEMP=$COREUTILS/bin/mktemp
MKDIR=$COREUTILS/bin/mkdir
CP=$COREUTILS/bin/cp
CHMOD=$COREUTILS/bin/chmod
RM=$COREUTILS/bin/rm
SHA256SUM=$COREUTILS/bin/sha256sum
STAT=$COREUTILS/bin/stat
SLEEP=$COREUTILS/bin/sleep
PYTHON=/gnu/store/c9ga6sl21sy1cbxdllvxkj6qlnk4yzbh-python-3.11.14/bin/python3.11
GUILE=/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11/bin/guile
GCRYPT=/gnu/store/yj7cgbs9d4qc93v93h63kpmdq0vm5k2i-guile-gcrypt-0.5.0
GUIX_MODULES=/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules
BOOTSTRAP_PY_SHA256=aa5a0ddd3d06d962824cdea919bbeda0fef132110cc89b50e660dc542f46bd66

fail() {
    echo "TWO_BOOT_LAUNCHER_FAIL: $*" >&2
    exit 1
}

hash_file() {
    local output hash rest
    output=$($SHA256SUM -- "$1") || fail "could not hash $1"
    read -r hash rest <<<"$output"
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || fail "malformed hash result for $1"
    echo "$hash"
}

[[ $(hash_file "$BASH") == "$BASH_SHA256" ]] ||
    fail "pinned Bash bootstrap interpreter differs"
declare -A bootstrap_hashes=(
    ["$ENV"]=ba3874072202b41fd4f2b32b419c2417c557b6144f9f47980f818a543f37b560
    ["$MKTEMP"]=3e5c479899629923fa5f23d54504aea4db0c575681a6d32b6ae1bcf5bfb49e9f
    ["$MKDIR"]=459b42fb208e5baf009bd61305df0e35d089742169beebcfd0360d2dd5aa66c5
    ["$CP"]=69e7402661aecaed4f454eadc8eaa43a44a8216263a7a91790be44b142c57fba
    ["$CHMOD"]=f39bc82d5a3e6021d75851597148251d5861ea7941779a03b6b8f06cdd6e071d
    ["$RM"]=0cd2768b2b2ca78d6c0aa67b5f03c62f9a1cc1193b8e6d66dbc84570907a351e
    ["$SHA256SUM"]=6090d2212e6f8e45451ea5bcf473602d52d3ea896046fd66883fb1d148ea3c12
    ["$STAT"]=0766effaa518b100a9c432a948c0f895a5cbd6c25878d020833ca47eb3410d1e
    ["$SLEEP"]=a18858e23323ac63ffcf0db174e03c63d7936bbc173b10108423d28b0f265a54
    ["$PYTHON"]=6628ece57f92247f650271282e1902e17f754b31296d6d9e13d56643385e536f
    ["$GUILE"]=cef96854423238cab5ef9f4e5ddc1379b43eef40a4b26d73e814583479789888
)
for program in "${!bootstrap_hashes[@]}"; do
    expected=${bootstrap_hashes[$program]}
    [[ $expected =~ ^[0-9a-f]{64}$ ]] ||
        fail "bootstrap dependency pin is not sealed: $program"
    [[ $(hash_file "$program") == "$expected" ]] ||
        fail "pinned bootstrap dependency differs: $program"
done

script=${BASH_SOURCE[0]}
case $script in
    /*) script_path=$script ;;
    *) script_path=$invocation_working_directory/$script ;;
esac
script_directory=${script_path%/*}
script_name=${script_path##*/}
source_root=$(cd -- "$script_directory" && pwd -P)
[[ $script_name == run-two-boot.sh && ! -L $source_root/$script_name ]] ||
    fail "launcher must be the real reviewed run-two-boot.sh"

helper=$source_root/bootstrap.py
[[ -f $helper && ! -L $helper ]] || fail "bootstrap helper is absent or linked"
exec 9<"$helper"
[[ $(hash_file /proc/self/fd/9) == "$BOOTSTRAP_PY_SHA256" ]] ||
    fail "bootstrap helper differs from reviewed trust-base bytes"

bootstrap_root=$($MKTEMP -d /tmp/opencode/book-state-two-boot-bootstrap.XXXXXX)
[[ $bootstrap_root == /tmp/opencode/book-state-two-boot-bootstrap.* ]] ||
    fail "mktemp returned an unexpected bootstrap root"
bootstrap_identity=$($STAT -c '%d:%i' -- "$bootstrap_root")
[[ $bootstrap_identity =~ ^[0-9]+:[0-9]+$ ]] ||
    fail "could not retain bootstrap root identity"
cleanup() {
    if [[ -e $bootstrap_root ]]; then
        # A Guile owner killed after guardian startup returns control here before
        # that guardian's bounded process/root cleanup delay.  Never race it.
        $SLEEP 13 || true
    fi
    if [[ -e $bootstrap_root ]]; then
        current_identity=$($STAT -c '%d:%i' -- "$bootstrap_root" 2>/dev/null || true)
        if [[ $current_identity == "$bootstrap_identity" ]]; then
            $RM -rf -- "$bootstrap_root" 2>/dev/null || true
        else
            echo "TWO_BOOT_LAUNCHER_FAIL: replaced bootstrap root preserved" >&2
        fi
    fi
}
terminate() {
    cleanup
    exit 1
}
trap cleanup EXIT
trap terminate HUP INT TERM

$CP -- /proc/self/fd/9 "$bootstrap_root/bootstrap.py"
$CHMOD 0400 "$bootstrap_root/bootstrap.py"
[[ $(hash_file "$bootstrap_root/bootstrap.py") == "$BOOTSTRAP_PY_SHA256" ]] ||
    fail "retained bootstrap helper differs"
exec 9<&-

$MKDIR -m 0700 \
    "$bootstrap_root/home" "$bootstrap_root/cache" \
    "$bootstrap_root/config" "$bootstrap_root/data" \
    "$bootstrap_root/state" "$bootstrap_root/tmp" \
    "$bootstrap_root/runtime" "$bootstrap_root/empty-path"

set +e
$ENV -i \
    HOME="$bootstrap_root/home" \
    XDG_CACHE_HOME="$bootstrap_root/cache" \
    XDG_CONFIG_HOME="$bootstrap_root/config" \
    XDG_DATA_HOME="$bootstrap_root/data" \
    XDG_STATE_HOME="$bootstrap_root/state" \
    XDG_RUNTIME_DIR="$bootstrap_root/runtime" \
    TMPDIR="$bootstrap_root/tmp" \
    PATH="$bootstrap_root/empty-path" \
    LANG=C LC_ALL=C \
    GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_PATH="$GCRYPT/share/guile/site/3.0:$GUIX_MODULES/share/guile/site/3.0" \
    GUILE_LOAD_COMPILED_PATH="$GCRYPT/lib/guile/3.0/site-ccache:$GUIX_MODULES/lib/guile/3.0/site-ccache" \
    GUILE_EXTENSIONS_PATH= \
    PYTHONDONTWRITEBYTECODE=1 \
    "$PYTHON" -B -I -S "$bootstrap_root/bootstrap.py" \
    --source-root "$source_root" --bootstrap-root "$bootstrap_root" \
    -- "$@"
status=$?
set -e
exit "$status"
