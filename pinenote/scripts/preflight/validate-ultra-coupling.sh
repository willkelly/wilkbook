#!/bin/sh
# Structural gate: the ultra payload is a MATCHED PAIR that must ship whole.
#
# Either half alone is a proven-broken configuration on this device:
#   * override WITHOUT rails (R10/R11, 2026-08-07/08): firmware arms GPIO0
#     wake, parks at sram2wfi, and nothing -- not the RTC, not the power
#     button -- ever wakes it.  Only a forced power-off exits.  With the
#     override STANDING in the DT, an idle device would enter that state
#     unattended on its first quiet five minutes.
#   * rails WITHOUT override (rails-off + mem): never run by anyone; hrdl's
#     DT makes it structurally unreachable and ours must too.
# Together (R12, 2026-08-08): three consecutive resumes -- RTC backstop,
# power button, 40-minute alarm -- at 4.64 mA.
# doc/artifacts/pinenote-ultra-r12-20260808/.
#
# This gate replaced validate-ultra-rails-quarantine.sh on promotion day:
# quarantine asked "can the payload escape to production?"; coupling asks
# "can the halves separate?".  The DTB-level pins (override value, the
# three rails, cap-power-off-card) live in inspect-pinenote-suspend-gates
# and run against every built DTB; THIS gate pins the patch/package layer.
#
# Usage: validate-ultra-coupling.sh
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)

patch=$repo_root/pinenote/patches/linux-pinenote-7.0-ultra-rails.patch
kernel=$repo_root/pinenote/packages/kernel.scm
patches_dir=$repo_root/pinenote/patches

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -r "$patch" ]  || fail "cannot read $patch"
[ -r "$kernel" ] || fail "cannot read $kernel"

# 1. Both halves live in THIS one patch: the standing override...
grep -q '^+.*rockchip,suspend-state-override = <5>;' "$patch" ||
  fail "the rails patch no longer adds the standing override -- the halves
   have been separated; rails-off + mem is a configuration nobody has run"

# ...and exactly the three reviewed rails, plus the card-power flip.
offs=$(grep -c '^+.*regulator-off-in-suspend;' "$patch" || true)
[ "$offs" -eq 3 ] ||
  fail "patch flips ${offs} rails off-in-suspend; the reviewed payload is
   exactly 3 (LDO_REG1, LDO_REG3, LDO_REG6)"
grep -q '^+.*cap-power-off-card;' "$patch" ||
  fail "patch does not move sdmmc1 to cap-power-off-card; vqmmc dies under
   the rail policy and the mmc core must re-init the card"
grep -q '^-.*keep-power-in-suspend;' "$patch" ||
  fail "patch does not remove keep-power-in-suspend from sdmmc1"

# 2. The patch is in the SHARED list (every 7.0 kernel gets the pair), and
#    applied AFTER the bsp-sip patch that creates the node it extends.
list=$(awk '/define %linux-pinenote-patches/{f=1} f{print} f&&/\)\)\)$/{exit}' "$kernel")
printf '%s' "$list" | grep -q "linux-pinenote-7.0-ultra-rails.patch" ||
  fail "the ultra payload is not in %linux-pinenote-patches -- the primary
   kernel would build without it while the gates expect it"
bsp_line=$(printf '%s\n' "$list" | grep -n "bsp-sip-probe" | head -1 | cut -d: -f1)
rails_line=$(printf '%s\n' "$list" | grep -n "ultra-rails" | head -1 | cut -d: -f1)
[ -n "$bsp_line" ] && [ -n "$rails_line" ] && [ "$rails_line" -gt "$bsp_line" ] ||
  fail "ultra-rails must be listed AFTER bsp-sip-probe: it patches the
   /rockchip-suspend node that patch introduces"

# 3. No OTHER patch may carry the override -- the pair stays in one file.
others=$(grep -l "suspend-state-override = <" "$patches_dir"/*.patch 2>/dev/null |
         grep -v "ultra-rails" || true)
[ -z "$others" ] ||
  fail "these patches also set a suspend-state-override (the pair must live
   in exactly one patch):
$(printf '%s\n' "$others" | sed 's|^|     |')"

# 4. The bench artifacts of the quarantine era must stay deleted -- a
#    reintroduced linux-pinenote-ultra would be a second, unreviewed path.
if grep -q "linux-pinenote-ultra" "$kernel"; then
  fail "kernel.scm references linux-pinenote-ultra; the bench kernel was
   retired on promotion and must not return"
fi
[ ! -e "$repo_root/pinenote/systems/pinenote-reader-ultra.scm" ] ||
  fail "the bench flavor still exists; production carries the payload now"

echo "PASS: the ultra pair (standing override + three rails + card-power flip)
      ships whole in one patch, applied after bsp-sip, on the primary kernel"
