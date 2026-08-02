#!/bin/sh
# Structural gate over the fbdev-client resume barrier in rockchip_ebc
# (doc/power-management.md, "Post-resume dead-write window").
#
# The barrier lives inside `#ifdef CONFIG_DRM_FBDEV_EMULATION`, which the
# ebc-logic host harness does NOT define -- it compiles the `#else` no-op
# stub.  So the host suite can go green with the real branch deleted or
# reordered.  `make kernel` is the only compile gate, and this script is
# the only *behavioral* gate.  It must stay cheap enough to run on every
# patch edit.
#
# What it pins, and why each one is load-bearing:
#   1. The helper exists, and so does the #else stub -- otherwise a
#      CONFIG_DRM_FBDEV_EMULATION=n build breaks.
#   2. resume calls it.  Without the call, drm_fbdev_client_resume()'s
#      deferred un-suspend is never awaited, info->state stays
#      FBINFO_STATE_SUSPENDED, and drm_fb_helper_damage_work() silently
#      drops every damage submission.
#   3. It is called AFTER rockchip_ebc_wake_worker(), so damage released
#      by the un-suspend has a live consumer.
#   4. It is called only on the !ret path -- a failed
#      drm_mode_config_helper_resume() must not be followed by an
#      un-suspend that publishes damage into a half-resumed pipeline.
#   5. The barrier is drm_fb_helper_set_suspend_unlocked(..., false) and
#      not a hand-rolled fb_set_suspend()/flush_work(): the helper's own
#      opening flush_work(&fb_helper->resume_work) IS the barrier, and it
#      is what makes the call free in the common case.
#
# Usage: validate-ebc-fbdev-resume-hunk.sh [patch]   (default: repo patch)
set -eu

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
patch=${1:-$repo_root/pinenote/patches/linux-pinenote-7.0-forward-port.patch}

fail() { echo "FAIL: $1" >&2; exit 1; }

section=$(awk '/^diff --git a\/drivers\/gpu\/drm\/rockchip\/rockchip_ebc.c/{f=1}
               f && /^diff --git/ && !/rockchip_ebc.c/{exit} f{print}' "$patch")
[ -n "$section" ] || fail "no rockchip_ebc.c section in $patch"

added=$(printf '%s\n' "$section" | sed -n 's/^+//p')
[ -n "$added" ] || fail "rockchip_ebc.c section adds no lines"

require() {
  printf '%s\n' "$added" | grep -qF "$1" || fail "missing: $1"
}

# 1. Helper and its disabled-config stub.
require "static void rockchip_ebc_fbdev_finish_resume(void)"
printf '%s\n' "$added" |
  grep -qF "static void rockchip_ebc_fbdev_finish_resume(void) { }" ||
  fail "no #else no-op stub: a CONFIG_DRM_FBDEV_EMULATION=n build would not link"

# The helper body must sit inside the fbdev-emulation guard that also
# owns rockchip_ebc_defio_helper.
guarded=$(printf '%s\n' "$added" |
  sed -n '/^#ifdef CONFIG_DRM_FBDEV_EMULATION$/,/^#endif$/p')
printf '%s\n' "$guarded" | grep -qF "rockchip_ebc_defio_helper" ||
  fail "cannot isolate the CONFIG_DRM_FBDEV_EMULATION block"
printf '%s\n' "$guarded" |
  grep -qF "static void rockchip_ebc_fbdev_finish_resume(void)" ||
  fail "the helper is outside the CONFIG_DRM_FBDEV_EMULATION guard"

# 2/5. The barrier is the vanilla helper, un-suspending.
helper_body=$(printf '%s\n' "$added" |
  sed -n '/static void rockchip_ebc_fbdev_finish_resume(void)$/,/^}/p')
[ -n "$helper_body" ] || fail "cannot isolate the helper body"
printf '%s\n' "$helper_body" | grep -qF "drm_fb_helper_set_suspend_unlocked" ||
  fail "helper does not call drm_fb_helper_set_suspend_unlocked (its opening flush_work IS the barrier)"
printf '%s\n' "$helper_body" | grep -qE '(^|[^_[:alnum:]])false' ||
  fail "helper does not pass suspend=false"
printf '%s\n' "$helper_body" | grep -qF "rockchip_ebc_defio_helper" ||
  fail "helper does not guard on a live fb helper pointer"

# 3/4. Call site: inside resume, on the success path, after the wake.
resume_body=$(printf '%s\n' "$added" |
  sed -n '/static int __maybe_unused rockchip_ebc_resume(struct device \*dev)/,/^}/p')
[ -n "$resume_body" ] || fail "cannot isolate rockchip_ebc_resume"

call_line=$(printf '%s\n' "$resume_body" |
  grep -n "rockchip_ebc_fbdev_finish_resume()" | cut -d: -f1 | head -1)
[ -n "$call_line" ] || fail "rockchip_ebc_resume does not call rockchip_ebc_fbdev_finish_resume()"

wake_line=$(printf '%s\n' "$resume_body" |
  grep -n "rockchip_ebc_wake_worker(" | cut -d: -f1 | head -1)
[ -n "$wake_line" ] || fail "rockchip_ebc_resume does not wake the worker"
[ "$wake_line" -lt "$call_line" ] ||
  fail "the fbdev un-suspend precedes rockchip_ebc_wake_worker(): released damage would have no consumer"

# The call must be *inside* the success block, not merely after it: a
# call placed past the closing brace still satisfies a line-order test
# while running on the failure path too.  The block is delimited by
# `if (!ret) {` and the closing brace at the same one-tab indentation.
success_block=$(printf '%s\n' "$resume_body" |
  awk '/^\tif \(!ret\) \{$/{f=1;next} f && /^\t\}$/{exit} f{print}')
[ -n "$success_block" ] ||
  fail "rockchip_ebc_resume has no braced 'if (!ret) {' success block"
printf '%s\n' "$success_block" | grep -qF "rockchip_ebc_fbdev_finish_resume()" ||
  fail "the fbdev un-suspend is outside the !ret success block (it would also run after a failed helper resume)"
printf '%s\n' "$success_block" | grep -qF "rockchip_ebc_wake_worker(" ||
  fail "rockchip_ebc_wake_worker() is outside the !ret success block"

# The un-suspend must not be reachable from the suspend-rollback path,
# which resumes the helper only to undo a failed pm_runtime_force_suspend.
suspend_body=$(printf '%s\n' "$added" |
  sed -n '/static int __maybe_unused rockchip_ebc_suspend(struct device \*dev)/,/^}/p')
printf '%s\n' "$suspend_body" | grep -qF "rockchip_ebc_fbdev_finish_resume" &&
  fail "the suspend rollback path calls the fbdev un-suspend barrier" || true

echo "PASS: rockchip_ebc fbdev resume-barrier structural gate"
