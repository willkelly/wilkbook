#!/bin/sh
# Structural and identity gate for the private joined-reader source closure.
# The expected hashes are literals, never arguments or environment selectors.
set -eu

[ "$#" -eq 1 ] || {
    echo "usage: verify-source-closure.sh PRIVATE_CLOSURE" >&2
    exit 2
}
root=$1
case "$root" in /*) ;; *) echo "closure root must be absolute" >&2; exit 2 ;; esac
[ "$(CDPATH= cd -- "$root" && pwd -P)" = "$root" ] || {
    echo "closure root must be canonical" >&2
    exit 1
}

join="$root/join"
native="$root/native-v2"
observer="$root/observer-v1"
ui="$root/ui"
scratch_base=${TMPDIR:-/tmp/opencode}
mkdir -p "$scratch_base"
scratch=$(mktemp -d "$scratch_base/book-state-reader-join-source-gate.XXXXXX")
chmod 700 "$scratch"
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
for directory in "$join" "$native" "$observer" "$ui"; do
    [ -d "$directory" ] || {
        echo "source closure directory is absent: $directory" >&2
        exit 1
    }
done

# Filled only after all downstream source is final.  This file is separately
# pinned by the outer runner and excluded from SOURCE-IDENTITIES to avoid a
# self-referential digest.
join_source_identities=a40b9bee10fd78055a27e68e2f4acf091e5d4250d1ce697a967001d0cdbc9282

check_identity_file () {
    expected=$1
    path=$2
    actual=$(sha256sum "$path")
    actual=${actual%% *}
    [ "$actual" = "$expected" ] || {
        echo "identity file changed: $path ($actual)" >&2
        exit 1
    }
}

check_roster () {
    directory=$1
    expected=$2
    actual="$scratch/roster.$$.txt"
    (cd "$directory" && find . -type f -printf '%P\n' | LC_ALL=C sort) \
        >"$actual"
    if ! cmp "$expected" "$actual"; then
        rm -f -- "$actual"
        echo "source closure has an unlisted or missing file: $directory" >&2
        exit 1
    fi
    rm -f -- "$actual"
}

if find "$root" -type l -o \( ! -type d ! -type f \) | grep -q .; then
    echo "source closure contains a symlink or special file" >&2
    exit 1
fi
if find "$root" -type d -printf '%m\n' | grep -vx 500 >/dev/null; then
    echo "source closure directory mode differs from 0500" >&2
    exit 1
fi
if find "$root" -type f -printf '%m\n' | grep -vx 400 >/dev/null; then
    echo "source closure file mode differs from 0400" >&2
    exit 1
fi

check_identity_file "$join_source_identities" \
    "$join/SOURCE-IDENTITIES.sha256"
check_roster "$join" "$join/PACKET-ROSTER.txt"
(cd "$join" && sha256sum --check --strict SOURCE-IDENTITIES.sha256)
(cd "$join" && sha256sum --check --strict MANIFEST.sha256)

check_identity_file \
    261b5f018af7c00afe8b3b8db81c42e14bd4efde85ac85a465a459f2ce89013f \
    "$native/MANIFEST.sha256"
check_identity_file \
    45f37e2fa154fb8593c7d0fc178c5d1b4a443dd7b2316dcddae1680ed86759f2 \
    "$native/SOURCE-IDENTITIES.sha256"
check_identity_file \
    7594bb800f5dba727ecfdd6a555cd779520bc0ca53efed0db42596de6c98bc66 \
    "$native/PACKET-ROSTER.txt"
check_roster "$native" "$native/PACKET-ROSTER.txt"
(cd "$native" && sha256sum --check --strict SOURCE-IDENTITIES.sha256)
(cd "$native" && sha256sum --check --strict MANIFEST.sha256)

check_identity_file \
    e45002e153ce6ae94cd2ddfff2c1a3a9551ce0a0b9046c6cee9c7a08bea50d36 \
    "$observer/SHA256SUMS"
{
    sed -n 's/^[0-9a-f][0-9a-f]*  //p' "$observer/SHA256SUMS"
    echo SHA256SUMS
} | LC_ALL=C sort >"$scratch/observer-roster.txt"
check_roster "$observer" "$scratch/observer-roster.txt"
(cd "$observer" && sha256sum --check --strict SHA256SUMS)

# The accepted observer is immutable.  This join executes only the separately
# named, exactly patched state-text successor carried in its own source packet.
check_identity_file \
    a6d904a0bc30237de4dc1ccc0e61e955e4def8e10037478505a33a5d15a934e7 \
    "$join/empty-action-successor/book-session.scm"
check_identity_file \
    cbfe3b42d077b7fcfa2d44bb2f64fed5801131249375f062af160adcc9e43d57 \
    "$join/empty-action-successor/observer-0342-empty-state-text.patch"

check_identity_file \
    a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab \
    "$ui/SHA256SUMS"
{
    sed -n 's/^[0-9a-f][0-9a-f]*  //p' "$ui/SHA256SUMS"
    echo SHA256SUMS
} | LC_ALL=C sort >"$scratch/ui-roster.txt"
check_roster "$ui" "$scratch/ui-roster.txt"
(cd "$ui" && sha256sum --check --strict SHA256SUMS)

cat <<'EOF' | (cd "$join/accepted-provenance" && sha256sum --check --strict -)
928885be26b58469c9012848260035428ac2eb1494f47bc9a90f940df4777c51  native-v2-adversarial.md
264bbfab85e4393322a6bba2051fe29f54be5958be3e50eb0c15e46888997224  native-v2-review-packet.txt
56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301  ui-adversarial.md
e4f1ae002ba07268c825ddc24b02477ba259a16226ca5a1e42344a6fdd0286a5  observer-v1-adversarial.md
f5303c0ea430c8dfb23ad769ddf7084cf494367d9da55d4080b29ff7e2cb8a51  observer-v1-review-packet.txt
cf31edc06b2c057f3c2c6bfd280940559255301eb76934bf0f603abb06a39d6e  reader-join-v1-adversarial.md
EOF
[ "$(find "$join/accepted-provenance" -type f | wc -l)" -eq 6 ] || {
    echo "review provenance closure has an unlisted or missing file" >&2
    exit 1
}
# The accepted observer review names this evidence-manifest identity, but that
# separately named artifact is not present in the checkout.  Bind the exact
# attestation rather than manufacturing a replacement file with the same name.
grep -Fx \
    '90362b51099718e710c2a4c42bf6d07f173b4136d980d5d6db536f18e5e68bb1  EVIDENCE.sha256' \
    "$join/accepted-provenance/observer-v1-adversarial.md" >/dev/null || {
        echo "accepted observer evidence-manifest attestation is absent" >&2
        exit 1
    }

cat <<'EOF' | (cd "$root" && sha256sum --check --strict -)
661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1  native-v2/accepted-inputs/channels.scm
0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f  observer-v1/candidate/book-session.scm
eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6  observer-v1/book-state-session-delegate.scm
7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9  native-v2/accepted-inputs/backend/book-state.scm
70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb  native-v2/accepted-inputs/backend/schema-v1.sql
91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44  native-v2/accepted-inputs/book-protocol/book-protocol.scm
543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd  native-v2/accepted-inputs/book-protocol/book-protocol/blocking-io.scm
4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735  native-v2/accepted-inputs/book-protocol/book_protocol.py
dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee  native-v2/accepted-inputs/state-protocol/book-state-operation-id.scm
425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257  native-v2/accepted-inputs/state-protocol/book-state-protocol.scm
349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769  native-v2/accepted-inputs/state-protocol/book-state-backend-adapter.scm
EOF

cat <<'EOF' | (cd "$join" && sha256sum --check --strict -)
97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354  accepted-helper/process-identity.sh
dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec  accepted-regressions/test-book-session-227.scm
4008d9e4491e814b8a33d9a015038eb8684f2c9a0378966839cfd21309055562  accepted-regressions/test-book-session-state-integration-61.scm
EOF

echo "JOIN-SOURCE-GATE: exact v2 join/successor/native-v2/observer-v1/UI closure authenticated"
