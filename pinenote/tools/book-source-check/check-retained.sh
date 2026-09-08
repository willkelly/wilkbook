#!/bin/sh
# Authenticate the historical native-v1 packet at an explicit external root.
set -eu

[ "$#" -eq 1 ] || {
    echo "usage: check-retained.sh AUTHENTICATED_ARTIFACT_ROOT" >&2
    exit 2
}
root=$1
case "$root" in /*) ;; *) echo "artifact root must be absolute" >&2; exit 2 ;; esac
[ "$(CDPATH= cd -- "$root" && pwd -P)" = "$root" ] || {
    echo "artifact root must be canonical" >&2
    exit 1
}
[ -d "$root" ] || { echo "artifact root is absent" >&2; exit 1; }
packet="$root/book-state-native-integration-sources-20260906-v1"
nested=accepted-inputs/aarch64-guile-sqlite3-0.1.3-20260906-v1
for name in \
    book-state-native-integration-review-packet-v1.txt \
    book-state-native-integration-host-check-v1.log \
    book-state-native-integration-adversarial-v1.md; do
    [ -f "$root/$name" ] && [ ! -L "$root/$name" ] || {
        echo "retained evidence is absent or not a regular file: $name" >&2
        exit 1
    }
done

cat <<'EOF' | (cd "$root" && sha256sum --check --strict -)
02bd736c7dd6954837ab1053b2d91692d60a723a4ede5fb80499ce2d06bac777  book-state-native-integration-review-packet-v1.txt
23392544b6a1339b3548a19247ad1d74eec63fb7fb8c975cc1e0f96b97a2724d  book-state-native-integration-host-check-v1.log
16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877  book-state-native-integration-adversarial-v1.md
42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe  book-state-native-integration-sources-20260906-v1/MANIFEST.sha256
EOF
[ -d "$packet" ] || { echo "historical v1 source packet is absent" >&2; exit 1; }
if find "$packet" -type l -o \( ! -type d ! -type f \) | grep -q .; then
    echo "historical packet contains a symlink or special file" >&2
    exit 1
fi
(cd "$packet" && sha256sum --check --strict MANIFEST.sha256)
cat <<'EOF' | (cd "$packet" && sha256sum --check --strict -)
20ec87ad8ae621e9af671667fba868bfb293a23f3863f01ba26643b852565a8e  accepted-inputs/aarch64-guile-sqlite3-0.1.3-20260906-v1/MANIFEST.sha256
EOF
(cd "$packet/$nested" && sha256sum --check --strict MANIFEST.sha256)
mkdir -p /tmp/opencode
scratch=$(mktemp -d /tmp/opencode/book-retained-check.XXXXXX)
chmod 700 "$scratch"
expected="$scratch/expected-roster"
actual="$scratch/actual-roster"
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
{
    sed 's/^[^ ]*  \.\///' "$packet/MANIFEST.sha256"
    echo "$nested/MANIFEST.sha256"
    echo MANIFEST.sha256
} | LC_ALL=C sort >"$expected"
(cd "$packet" && find . -type f -printf '%P\n' | LC_ALL=C sort) >"$actual"
cmp "$expected" "$actual" || {
    echo "historical packet has an unlisted or missing file" >&2
    exit 1
}
echo "PASS: explicit external native-v1 packet, host log, and blocked review authenticated"
echo "INFO: this gate does not regenerate, reinterpret, or replace historical evidence"
