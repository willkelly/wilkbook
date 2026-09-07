#!/bin/sh
# Structural and identity gate for one fixed native-integration source snapshot.
# Expected manifest identities are authenticated by the outer runner, not argv.
set -eu

[ "$#" -eq 1 ] || {
    echo "usage: verify-source-snapshot.sh SNAPSHOT_ROOT" >&2
    exit 2
}
root=$1
case "$root" in /*) ;; *) echo "snapshot root must be absolute" >&2; exit 2 ;; esac
canonical=$(CDPATH= cd -- "$root" && pwd -P)
[ "$canonical" = "$root" ] || {
    echo "snapshot root must be canonical" >&2
    exit 1
}

[ -f "$root/SOURCE-IDENTITIES.sha256" ] \
    && [ -f "$root/MANIFEST.sha256" ] \
    && [ -f "$root/PACKET-ROSTER.txt" ] || {
    echo "snapshot identity files are incomplete" >&2
    exit 1
}

mkdir -p /tmp/opencode
actual_roster=$(mktemp /tmp/opencode/book-state-source-roster.XXXXXX)
trap 'rm -f -- "$actual_roster"' EXIT HUP INT TERM
(cd "$root" && find . -type f -printf '%P\n' \
    | LC_ALL=C sort) >"$actual_roster"
expected_roster=$(sha256sum "$root/PACKET-ROSTER.txt")
expected_roster=${expected_roster%% *}
observed_roster=$(sha256sum "$actual_roster")
observed_roster=${observed_roster%% *}
[ "$expected_roster" = "$observed_roster" ] || {
    echo "snapshot contains an unlisted or missing file" >&2
    exit 1
}

if find "$root" -type l -o \( ! -type d ! -type f \) | grep -q .; then
    echo "snapshot contains a symlink or special file" >&2
    exit 1
fi
if find "$root" -type d -printf '%m\n' | grep -vx 500 >/dev/null; then
    echo "snapshot directory mode differs from 0500" >&2
    exit 1
fi
if find "$root" -type f -printf '%m\n' | grep -vx 400 >/dev/null; then
    echo "snapshot data/source file mode differs from 0400" >&2
    exit 1
fi

(cd "$root" && sha256sum --check --strict SOURCE-IDENTITIES.sha256)
(cd "$root" && sha256sum --check --strict MANIFEST.sha256)

# Independently pin the accepted executable cores named by the NI-1 review.
cat <<'EOF' | (cd "$root" && sha256sum --check --strict -)
7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9  accepted-inputs/backend/book-state.scm
70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb  accepted-inputs/backend/schema-v1.sql
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  accepted-inputs/book-protocol/book-protocol.scm
543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd  accepted-inputs/book-protocol/book-protocol/blocking-io.scm
4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735  accepted-inputs/book-protocol/book_protocol.py
dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee  accepted-inputs/state-protocol/book-state-operation-id.scm
425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257  accepted-inputs/state-protocol/book-state-protocol.scm
349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769  accepted-inputs/state-protocol/book-state-backend-adapter.scm
f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301  accepted-inputs/session/book-session.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  accepted-inputs/session/book-state-session-delegate.scm
EOF

echo "SOURCE-GATE: verified exact executable closure before tests"
