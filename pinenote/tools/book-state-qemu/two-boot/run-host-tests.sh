#!/gnu/store/bcxav86yvf57pxf4jazqm695r61dzaai-bash-static-5.2.37/bin/bash -p
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH GLOBIGNORE

if [[ $# != 4 || $1 != --v9-bundle || $3 != --image-author-packet ]]; then
    echo "usage: $0 --v9-bundle PRIVATE_IMMUTABLE_BUNDLE --image-author-packet PRIVATE_IMMUTABLE_AUTHOR_PACKET" >&2
    exit 2
fi
V9_BUNDLE=$2
IMAGE_AUTHOR_PACKET=$4

ROOT=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
COREUTILS=/gnu/store/lzf20vxz8rq5d1akv907c1g3a0mq2z01-coreutils-9.1
GUILE_ROOT=/gnu/store/8vwbdsni9znrlxvcwqi4n02f23ysc1fa-guile-3.0.11
GCRYPT=/gnu/store/yj7cgbs9d4qc93v93h63kpmdq0vm5k2i-guile-gcrypt-0.5.0
GUIX_MODULES=/gnu/store/78lgwmqmgzyzz1khzpnqjwglhkmja1w4-guix-f250e74dd-modules
PYTHON=/gnu/store/c9ga6sl21sy1cbxdllvxkj6qlnk4yzbh-python-3.11.14/bin/python3.11
ENV=$COREUTILS/bin/env
TIMEOUT=$COREUTILS/bin/timeout
MKTEMP=$COREUTILS/bin/mktemp
MKDIR=$COREUTILS/bin/mkdir
CHMOD=$COREUTILS/bin/chmod
RM=$COREUTILS/bin/rm
GUILE=$GUILE_ROOT/bin/guile
GUILD=$GUILE_ROOT/bin/guild
WORK=$($MKTEMP -d /tmp/opencode/two-boot-host-tests.XXXXXX)

cleanup() {
    $CHMOD -R u+rwX "$WORK" 2>/dev/null || true
    $RM -rf -- "$WORK"
}
trap cleanup EXIT HUP INT TERM

$MKDIR -m 0700 "$WORK/home" "$WORK/cache" "$WORK/config" "$WORK/data" \
    "$WORK/state" "$WORK/tmp" "$WORK/runtime" "$WORK/compiled" \
    "$WORK/pycache"

run_isolated() {
    $ENV -i \
        HOME="$WORK/home" \
        XDG_CACHE_HOME="$WORK/cache" \
        XDG_CONFIG_HOME="$WORK/config" \
        XDG_DATA_HOME="$WORK/data" \
        XDG_STATE_HOME="$WORK/state" \
        XDG_RUNTIME_DIR="$WORK/runtime" \
        TMPDIR="$WORK/tmp" \
        PATH="$GUILE_ROOT/bin:$COREUTILS/bin" \
        LANG=C LC_ALL=C \
        GUILE_AUTO_COMPILE=0 \
        GUILE_LOAD_PATH="$ROOT/modules:$ROOT/tests/modules:$GCRYPT/share/guile/site/3.0:$GUIX_MODULES/share/guile/site/3.0" \
        GUILE_LOAD_COMPILED_PATH="$WORK/compiled:$GCRYPT/lib/guile/3.0/site-ccache:$GUIX_MODULES/lib/guile/3.0/site-ccache" \
        GUILE_EXTENSIONS_PATH= \
        PYTHONDONTWRITEBYTECODE=1 \
        PYTHONPYCACHEPREFIX="$WORK/pycache" \
        "$@"
}

cd "$ROOT"

echo "HOST_TEST: complete source-manifest identities"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$COREUTILS/bin/sha256sum" --check --strict SOURCE-MANIFEST.sha256

compile_index=0
for source in \
    modules/book-state-qemu/qemu-graph.scm \
    modules/book-state-qemu/state-volume.scm \
    modules/disposable-qemu.scm \
    modules/guest-console-assertions.scm \
    modules/reader-qemu-graph.scm \
    modules/two-boot/bundle.scm \
    modules/two-boot/fd-handoff.scm \
    modules/two-boot/graph.scm \
    modules/two-boot/image-binding.scm \
    modules/two-boot/sequential.scm \
    modules/two-boot/source-gate.scm \
    modules/two-boot/timeout-contract.scm \
    modules/two-boot/ui-proxy.scm \
    tests/modules/two-boot/bundle-test-fixture.scm \
    accepted/qemu-coordinator.scm \
    candidate/qemu-state-coordinator.scm \
    bootstrap-main.scm \
    one-boot.scm \
    run-two-boot.scm \
    tests/never-halts.scm \
    tests/test-boot-bundle-append.scm \
    tests/test-graph.scm \
    tests/test-sequential.scm \
    tests/test-source-bundle-binding.scm \
    tests/test-timeout-boundary.scm \
    tests/test-typed-hooks.scm \
    tests/test-ui-proxy.scm
do
    compile_index=$((compile_index + 1))
    run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
        "$GUILD" compile -Wunbound-variable -Warity-mismatch \
        -L modules -L tests/modules \
        -o "$WORK/compiled/$compile_index.go" "$source"
done

run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$PYTHON" -B -I -S -c \
    'import ast, pathlib, sys; [ast.parse(pathlib.Path(name).read_bytes(), filename=name) for name in sys.argv[1:]]' \
    bootstrap.py check-evidence.py tests/make-synthetic-evidence.py \
    tests/test-bootstrap-map.py tests/test-bootstrap.py \
    tests/test-check-evidence.py tests/test-parent-patches.py \
    tests/test-reviewed-payload.py tests/test-root-handoff.py

echo "HOST_TEST: actual production boot bundle reaches the downstream APPEND parser"
run_isolated TWO_BOOT_V9_BUNDLE="$V9_BUNDLE" \
    "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-boot-bundle-append.scm

echo "HOST_TEST: immutable payload to QEMU argv to checker root handoff"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$PYTHON" -B -I -S tests/test-root-handoff.py "$V9_BUNDLE"

echo "HOST_TEST: pinned bootstrap dependency and runtime closure map"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$PYTHON" -B -I -S tests/test-bootstrap-map.py

echo "HOST_TEST: authenticated retained bootstrap and poisoned startup paths"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 90 \
    "$PYTHON" -B -I -S tests/test-bootstrap.py

echo "HOST_TEST: accepted source identities and exact parent patches"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$PYTHON" -B -I -S tests/test-parent-patches.py

echo "HOST_TEST: author successor image/payload, parent-review scope, and historical status-role regression"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 300 \
    "$PYTHON" -B -I -S tests/test-reviewed-payload.py \
    "$V9_BUNDLE" "$IMAGE_AUTHOR_PACKET"

echo "HOST_TEST: exact production authority is source-fixed"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules -c \
    '(use-modules (two-boot image-binding))
     (unless (and (eq? (production-image-binding-status) (quote available))
                  (string=?
                   (assoc-ref production-image-binding
                              (quote bundle-manifest-sha256))
                    "bd7151f0c4e729d40c4ed6ef65fe381ad07c30e4e3912089a83bfe0d1849245b")
                  (string=?
                   (assoc-ref production-image-binding
                               (quote binding-evidence-sha256))
                     "9c6b55822571c5c69f6b06ed48a58f7987cbda53e072b741122995ac7e65cfe8"))
       (error "production authority is not the exact author successor binding"))
     (format #t "PASS: production authority pins exact external evidence and bundle~%")'

echo "HOST_TEST: exact graph and forbidden mutations"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-graph.scm

echo "HOST_TEST: two-lifetime fail-stop sequencing"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-sequential.scm

echo "HOST_TEST: byte-transparent bounded UI proxy"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-ui-proxy.scm

echo "HOST_TEST: accepted hard guardian and owner SIGKILL"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-timeout-boundary.scm

echo "HOST_TEST: closed typed private-outer hooks"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$GUILE" --no-auto-compile -L modules tests/test-typed-hooks.scm

echo "HOST_TEST: source, exact successor binding candidate, bundle, and timeout gates"
run_isolated TWO_BOOT_V9_BUNDLE="$V9_BUNDLE" \
    "$TIMEOUT" --signal=TERM --kill-after=5 300 \
    "$GUILE" --no-auto-compile -L modules -L tests/modules \
    tests/test-source-bundle-binding.scm

echo "HOST_TEST: strict synthetic evidence and failure-record rejection"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 90 \
    "$PYTHON" -B -I -S tests/test-check-evidence.py

echo "HOST_TEST: fully sealed predecessor missing-both counterexample"
run_isolated "$TIMEOUT" --signal=TERM --kill-after=5 30 \
    "$PYTHON" -B -I -S tests/test-check-evidence.py \
    --sealed-missing-both-only

echo "PASS: finite successor binding and author-tested launcher host gate"
