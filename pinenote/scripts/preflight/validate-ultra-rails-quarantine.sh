#!/bin/sh
# Structural gate: the ultra rail payload must be reachable from exactly one
# flavor, and that flavor must not be a release target.
#
# Why this needs a gate.  The payload marks vcc_3v3_pmu off-in-suspend, and
# that rail powers the GPIO0 pad bank carrying every external wake interrupt
# on the board.  A production image that picked it up would suspend and
# require a ten-second power-button hold to come back -- on a device whose
# owner is not sitting in front of a UART.  That is the one failure class
# this project treats as unacceptable rather than annoying
# (doc/alpha-signoff.md: "covid, not a cold").
#
# The old gate forbade the payload outright, which is why it was never
# tested.  This one quarantines instead: the experiment is allowed to exist,
# and is prevented from escaping.
#
# Usage: validate-ultra-rails-quarantine.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)

patch=$repo_root/pinenote/patches/linux-pinenote-7.0-ultra-rails.patch
kernel=$repo_root/pinenote/packages/kernel.scm
flavor=$repo_root/pinenote/systems/pinenote-reader-ultra.scm
systems=$repo_root/pinenote/systems

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -r "$patch" ]  || fail "cannot read $patch"
[ -r "$kernel" ] || fail "cannot read $kernel"
[ -r "$flavor" ] || fail "cannot read $flavor"

# 1. Exactly one kernel package may carry the payload, and it must be the
#    bench kernel.
carriers=$(grep -c "linux-pinenote-7.0-ultra-rails.patch" "$kernel" || true)
[ "$carriers" -eq 1 ] ||
  fail "the ultra rails patch is referenced ${carriers}x in kernel.scm;
   exactly one carrier (linux-pinenote-ultra) is allowed"
grep -q "linux-pinenote-ultra" "$kernel" ||
  fail "kernel.scm has no linux-pinenote-ultra package"

# 2. The payload must NOT be in the shared patch list every kernel gets.
#    The range ends at the list's closing paren, not the first blank line --
#    a blank line inside the list would silently truncate the scan.
if awk '/define %linux-pinenote-patches/{f=1} f{print} f&&/\)\)\)$/{exit}' "$kernel" | grep -q "ultra-rails"; then
  fail "the ultra rails patch is in %linux-pinenote-patches -- that list is
   applied to the PRIMARY kernel and would ship the rail kill to every flavor"
fi

# 3. Exactly one flavor may use the bench kernel, and it must be the bench
#    flavor.  Any other system file naming it is an escape.
users=$(grep -l "linux-pinenote-ultra" "$systems"/*.scm 2>/dev/null || true)
case $(printf '%s\n' "$users" | grep -c .) in
  1) ;;
  *) fail "linux-pinenote-ultra is referenced by these system files:
$(printf '%s\n' "$users" | sed 's|^|     |')
   exactly one (pinenote-reader-ultra.scm) is allowed" ;;
esac
[ "$users" = "$flavor" ] ||
  fail "linux-pinenote-ultra is used by $users, not the bench flavor"

# 3b. Nor may any other flavor reach the payload by INHERITING the bench
#     OS instead of naming the kernel -- demonstrated bypass of check 3.
inheritors=$(grep -l "pinenote-reader-ultra" "$systems"/*.scm 2>/dev/null | grep -v "pinenote-reader-ultra.scm" || true)
[ -z "$inheritors" ] ||
  fail "these system files reference pinenote-reader-ultra (inherit-based
   escape from check 3):
$(printf '%s\n' "$inheritors" | sed 's|^|     |')"

# 4. The production reader must not name the bench kernel or the payload.
prod=$systems/pinenote-reader.scm
for token in linux-pinenote-ultra ultra-rails; do
  if grep -q "$token" "$prod"; then
    fail "the production reader flavor references '$token' -- production must
   be structurally unable to carry the rail kill"
  fi
done

# 5. The bench flavor must NOT INSTALL the auto-suspend service at all.
#    Rails-off + mem is as unsupported as the rails-on + ultra already
#    proven unwakeable, so an image that idles into suspend unattended
#    reproduces the failure by accident.  "Configured off" is not enough:
#    the daemon reads its config from p7, which survives reflashes and may
#    carry enabled=1 from the reader -- the first cut of this flavor shipped
#    an /etc file the daemon never opens, and this gate passed on it.
#    Absence is checkable; intent is not.
grep -q "remove" "$flavor" && grep -q "pinenote-autosuspend-service-type" "$flavor" ||
  fail "the bench flavor does not REMOVE pinenote-autosuspend-service-type;
   configured-off is not sufficient (the daemon's config lives on p7 and
   survives reflashes), the service must be absent"
if grep -q "enabled=0" "$flavor"; then
  fail "the bench flavor carries an enabled=0 config file; that was the
   decorative first cut -- nothing reads it, and its presence suggests the
   service is installed-but-off when it must be absent"
fi

# 6. The payload must still be what we think it is: three PMU rails flipped
#    to off-in-suspend, and sdmmc1 moved off keep-power. A payload that
#    quietly grew is no longer the reviewed one.
offs=$(grep -c '^+.*regulator-off-in-suspend;' "$patch" || true)
[ "$offs" -eq 3 ] ||
  fail "patch marks ${offs} rails off-in-suspend; the reviewed payload is
   exactly 3 (LDO_REG1, LDO_REG3, LDO_REG6)"
grep -q '^+.*cap-power-off-card;' "$patch" ||
  fail "patch does not move sdmmc1 to cap-power-off-card, which the Wi-Fi
   SDIO rail going away requires"
for rail in vcca_1v8_pmu vdda_0v9_pmu vcc_3v3_pmu; do
  grep -q "$rail" "$patch" || fail "patch header no longer documents $rail"
done

echo "PASS: the ultra rail payload is carried by one bench kernel, used by one
      bench flavor that ships auto-suspend off, and is unreachable from
      production"
